//! In-memory fake of the Incluir print-portal service API, for tests and
//! local development. Same contract as the real adapter (checked by the
//! shared conformance suite): ETag/If-Match CAS, Idempotency-Key replay and
//! conflict, the order state machine, supplier scoping (another supplier's
//! orders are 404) and the monthly close. Financeiro's human decisions are
//! test hooks here; through the real API they need a human session.
use async_trait::async_trait;
use bytes::Bytes;
use chrono::{DateTime, Utc};
use frame_observability::in_span;
use frame_portal_domain::{
    Close, CloseItem, CloseState, Competence, Currency, FileRef, Instant, Order, OrderList,
    OrderStatus, PrintJob, Quote, QuoteDecision, is_uuid, sanitize_download_name,
};
use frame_portal_port::{
    ApiError, ApiResult, Command, DOCUMENT_MAX_BYTES, Download, ListQuery, Preconditions, PrintApi,
    Tagged, Upload, codes,
};
use futures_util::StreamExt;
use opentelemetry::{KeyValue, global};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    future::Future,
    sync::{Arc, Mutex, MutexGuard},
};

pub const SYSTEM: &str = "memory";

pub type Clock = Arc<dyn Fn() -> DateTime<Utc> + Send + Sync>;

/// One file card of a seeded order.
#[derive(Clone, Debug)]
pub struct SeedJob {
    pub title: String,
    pub copies: u32,
    pub instructions: String,
    pub filename: String,
    pub bytes: Vec<u8>,
}

struct Stored {
    meta: FileRef,
    bytes: Bytes,
}

struct OrderRecord {
    order: Order,
    mine: bool,
    files: HashMap<String, Stored>,
    quote_document: Option<Stored>,
    quote_count: u64,
}

struct CloseRecord {
    close: Close,
    document: Option<Stored>,
}

enum Replay {
    Order(Command<Order>),
    Close(Command<Close>),
}

#[derive(Default)]
struct State {
    orders: Vec<OrderRecord>,
    closes: HashMap<Competence, CloseRecord>,
    idempotency: HashMap<String, (String, Replay)>,
    references: u32,
    unavailable: bool,
}

pub struct PrintApiMemory {
    state: Mutex<State>,
    clock: Clock,
}

impl Default for PrintApiMemory {
    fn default() -> Self {
        Self::new(Arc::new(|| std::time::SystemTime::now().into()))
    }
}

fn reject(status: u16, code: &str, message: &str) -> ApiError {
    ApiError::rejected(status, code, message)
}
fn not_found() -> ApiError {
    reject(404, codes::NOT_FOUND, "Recurso não encontrado.")
}
fn version_mismatch() -> ApiError {
    reject(
        412,
        codes::VERSION_MISMATCH,
        "O pedido foi atualizado. Consulte novamente antes de repetir.",
    )
}
fn invalid_state() -> ApiError {
    reject(
        409,
        codes::INVALID_STATE,
        "O pedido não está em um estado que permita esta operação.",
    )
}
fn invalid_request(message: &str) -> ApiError {
    reject(400, codes::INVALID_REQUEST, message)
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// Magic-byte detection; the declared name/extension is never trusted.
fn detect_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"%PDF-") {
        Some("application/pdf")
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        Some("image/jpeg")
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

fn prepare_document(file: &Upload) -> ApiResult<Stored> {
    if file.bytes.is_empty() {
        return Err(invalid_request("Requisição inválida."));
    }
    if file.bytes.len() > DOCUMENT_MAX_BYTES {
        return Err(reject(413, codes::FILE_TOO_LARGE, "Arquivo acima de 5 MB."));
    }
    let mime = detect_mime(&file.bytes).ok_or_else(|| {
        reject(
            415,
            codes::UNSUPPORTED_MEDIA_TYPE,
            "Envie um PDF, JPEG, PNG ou WebP.",
        )
    })?;
    Ok(Stored {
        meta: FileRef {
            id: uuid::Uuid::new_v4().to_string(),
            name: sanitize_download_name(&file.filename),
            mime: mime.into(),
            bytes: file.bytes.len() as u64,
            sha256: sha256_hex(&file.bytes),
        },
        bytes: file.bytes.clone(),
    })
}

fn etag(id: &str, version: u64) -> String {
    format!("\"{id}:{version}\"")
}

fn hex(raw: &str) -> String {
    raw.bytes().map(|b| format!("{b:02x}")).collect()
}
fn unhex(raw: &str) -> Option<String> {
    if !raw.len().is_multiple_of(2) {
        return None;
    }
    let bytes: Option<Vec<u8>> = (0..raw.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(raw.get(i..i + 2)?, 16).ok())
        .collect();
    String::from_utf8(bytes?).ok()
}

fn download(stored: &Stored) -> Download {
    let bytes = stored.bytes.clone();
    Download {
        mime: stored.meta.mime.clone(),
        length: Some(bytes.len() as u64),
        filename: stored.meta.name.clone(),
        body: futures_util::stream::once(async move { Ok(bytes) }).boxed(),
    }
}

async fn span<T>(
    operation: &'static str,
    method: &'static str,
    future: impl Future<Output = ApiResult<T>>,
) -> ApiResult<T> {
    in_span(
        &global::tracer("frame"),
        operation,
        vec![
            KeyValue::new("print_api.system", SYSTEM),
            KeyValue::new("print_api.operation", operation),
            KeyValue::new("http.request.method", method),
        ],
        future,
    )
    .await
}

/// Validated `If-Match` + `Idempotency-Key` (lowercased key).
fn required(pre: &Preconditions) -> ApiResult<(&str, String)> {
    let (Some(if_match), Some(key)) = (pre.if_match.as_deref(), pre.idempotency_key.as_deref())
    else {
        return Err(reject(
            428,
            codes::PRECONDITION_REQUIRED,
            "Cabeçalhos If-Match e Idempotency-Key são obrigatórios.",
        ));
    };
    if !is_uuid(key) {
        return Err(invalid_request("Idempotency-Key deve ser um UUID."));
    }
    Ok((if_match.trim(), key.to_ascii_lowercase()))
}

impl PrintApiMemory {
    pub fn new(clock: Clock) -> Self {
        Self {
            state: Mutex::default(),
            clock,
        }
    }
    fn lock(&self) -> ApiResult<MutexGuard<'_, State>> {
        let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.unavailable {
            return Err(ApiError::Unavailable {
                reason: "upstream_error",
            });
        }
        Ok(state)
    }
    fn now(&self) -> DateTime<Utc> {
        (self.clock)()
    }

    /// Simulates an outage (every call answers `Unavailable`).
    pub fn set_unavailable(&self, unavailable: bool) {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .unavailable = unavailable;
    }

    fn seed(&self, title: &str, jobs: Vec<SeedJob>, mine: bool) -> String {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.references += 1;
        let id = uuid::Uuid::new_v4().to_string();
        let mut files = HashMap::new();
        let jobs = jobs
            .into_iter()
            .map(|job| {
                let meta = FileRef {
                    id: uuid::Uuid::new_v4().to_string(),
                    name: sanitize_download_name(&job.filename),
                    mime: detect_mime(&job.bytes)
                        .unwrap_or("application/octet-stream")
                        .into(),
                    bytes: job.bytes.len() as u64,
                    sha256: sha256_hex(&job.bytes),
                };
                files.insert(
                    meta.id.clone(),
                    Stored {
                        meta: meta.clone(),
                        bytes: job.bytes.into(),
                    },
                );
                PrintJob {
                    id: uuid::Uuid::new_v4().to_string(),
                    title: job.title,
                    copies: job.copies,
                    instructions: job.instructions,
                    file: meta,
                }
            })
            .collect();
        let order = Order {
            id: id.clone(),
            reference: format!("IMP-{:04}", state.references),
            title: title.into(),
            revision: 1,
            version: 1,
            status: OrderStatus::Ready,
            created_at: self.now().into(),
            collected_at: None,
            printed_at: None,
            approved_amount_cents: None,
            jobs,
            general_instructions: None,
            current_quote: None,
            cancellation_reason: None,
        };
        state.orders.push(OrderRecord {
            order,
            mine,
            files,
            quote_document: None,
            quote_count: 0,
        });
        id
    }

    /// A `ready` order of this supplier (approved request, all files linked).
    pub fn seed_order(&self, title: &str, jobs: Vec<SeedJob>) -> String {
        self.seed(title, jobs, true)
    }
    /// An order of another supplier: must stay invisible (404).
    pub fn seed_foreign_order(&self, title: &str, jobs: Vec<SeedJob>) -> String {
        self.seed(title, jobs, false)
    }

    fn staff_update(
        &self,
        order_id: &str,
        apply: impl FnOnce(&mut Order, DateTime<Utc>) -> Result<(), &'static str>,
    ) -> Result<(), &'static str> {
        let now = self.now();
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let record = state
            .orders
            .iter_mut()
            .find(|r| r.order.id == order_id)
            .ok_or("unknown order")?;
        apply(&mut record.order, now)?;
        record.order.version += 1;
        Ok(())
    }

    /// Financeiro decision on the current quote (human route upstream).
    pub fn decide_quote(
        &self,
        order_id: &str,
        approve: bool,
        reason: Option<&str>,
    ) -> Result<(), &'static str> {
        self.staff_update(order_id, |order, now| {
            let quote = order.current_quote.as_mut().ok_or("no quote")?;
            if order.status != OrderStatus::QuotePending || quote.decision != QuoteDecision::Pending
            {
                return Err("not pending");
            }
            quote.decided_at = Some(now.into());
            if approve {
                quote.decision = QuoteDecision::Approved;
                order.approved_amount_cents = Some(quote.amount_cents);
                order.status = OrderStatus::QuoteApproved;
            } else {
                quote.decision = QuoteDecision::Rejected;
                quote.rejection_reason = Some(reason.ok_or("reason required")?.into());
                order.status = OrderStatus::QuoteRejected;
            }
            Ok(())
        })
    }

    /// Financeiro cancellation (human route upstream).
    pub fn cancel(&self, order_id: &str, reason: &str) -> Result<(), &'static str> {
        self.staff_update(order_id, |order, _| {
            if matches!(order.status, OrderStatus::Printed | OrderStatus::Cancelled) {
                return Err("not cancellable");
            }
            order.status = OrderStatus::Cancelled;
            order.cancellation_reason = Some(reason.into());
            Ok(())
        })
    }

    /// Financeiro decision on the submitted NF of a competence.
    pub fn decide_invoice(
        &self,
        competence: Competence,
        accept: bool,
        reason: Option<&str>,
    ) -> Result<(), &'static str> {
        let now = self.now();
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let record = state.closes.get_mut(&competence).ok_or("no close")?;
        let close = &mut record.close;
        if close.state != CloseState::Submitted {
            return Err("not submitted");
        }
        if accept {
            if close.declared_total_cents != Some(close.expected_total_cents) {
                return Err("TOTAL_MISMATCH");
            }
            close.state = CloseState::Accepted;
            close.accepted_at = Some(now.into());
        } else {
            close.state = CloseState::Rejected;
            close.rejection_reason = Some(reason.ok_or("reason required")?.into());
        }
        close.version += 1;
        Ok(())
    }

    fn virtual_close(competence: Competence, now: DateTime<Utc>) -> Close {
        Close {
            id: None,
            competence: competence.to_string(),
            version: 0,
            state: CloseState::Open,
            period_closed: competence.is_closed(now),
            items: vec![],
            expected_total_cents: 0,
            declared_total_cents: None,
            document: None,
            rejection_reason: None,
            submitted_at: None,
            accepted_at: None,
        }
    }

    /// Supplier command pipeline: visibility (404) → headers (428/400) →
    /// idempotency (replay/409) → If-Match (412) → state machine (409/412).
    fn order_command(
        &self,
        order_id: &str,
        route: &str,
        intent_fields: String,
        pre: &Preconditions,
        status: u16,
        apply: impl FnOnce(&mut OrderRecord, DateTime<Utc>) -> ApiResult<()>,
    ) -> ApiResult<Command<Order>> {
        let now = self.now();
        let mut state = self.lock()?;
        let state = &mut *state;
        let index = visible_index(state, order_id)?;
        let (if_match, key) = required(pre)?;
        let intent = format!("POST {route}/{order_id} {if_match} {intent_fields}");
        match state.idempotency.get(&key) {
            Some((stored, Replay::Order(command))) if *stored == intent => {
                return Ok(Command {
                    replayed: true,
                    ..command.clone()
                });
            }
            Some(_) => {
                return Err(reject(
                    409,
                    codes::IDEMPOTENCY_CONFLICT,
                    "A chave de idempotência já foi usada para outra operação.",
                ));
            }
            None => {}
        }
        let record = &mut state.orders[index];
        if if_match != etag(order_id, record.order.version) {
            return Err(version_mismatch());
        }
        apply(record, now)?;
        record.order.version += 1;
        let command = Command {
            status,
            body: record.order.clone(),
            etag: etag(order_id, record.order.version),
            replayed: false,
        };
        if record.order.status == OrderStatus::Printed {
            bill(state, index, now);
        }
        let record = &state.orders[index];
        let command = Command {
            body: record.order.clone(),
            ..command
        };
        state
            .idempotency
            .insert(key, (intent, Replay::Order(command.clone())));
        Ok(command)
    }
}

fn visible_index(state: &State, order_id: &str) -> ApiResult<usize> {
    if !is_uuid(order_id) {
        return Err(not_found());
    }
    state
        .orders
        .iter()
        .position(|r| r.mine && r.order.id == order_id)
        .ok_or_else(not_found)
}

/// `printed` bills the order into the São Paulo month of its print.
fn bill(state: &mut State, index: usize, now: DateTime<Utc>) {
    let order = &state.orders[index].order;
    let competence = Competence::containing(now);
    let item = CloseItem {
        order_id: order.id.clone(),
        reference: order.reference.clone(),
        quote_id: order
            .current_quote
            .as_ref()
            .map(|q| q.id.clone())
            .unwrap_or_default(),
        amount_cents: order.approved_amount_cents.unwrap_or_default(),
        printed_at: now.into(),
    };
    let record = state
        .closes
        .entry(competence)
        .or_insert_with(|| CloseRecord {
            close: Close {
                id: Some(uuid::Uuid::new_v4().to_string()),
                ..PrintApiMemory::virtual_close(competence, now)
            },
            document: None,
        });
    record.close.expected_total_cents += item.amount_cents;
    record.close.items.push(item);
    record.close.version += 1;
}

fn close_etag(competence: Competence, close: &Close) -> String {
    match &close.id {
        Some(id) => etag(id, close.version),
        None => format!("\"month:{competence}:0\""),
    }
}

#[async_trait]
impl PrintApi for PrintApiMemory {
    async fn list_orders(&self, query: &ListQuery) -> ApiResult<OrderList> {
        span("print_api.listOrders", "GET", async {
            let state = self.lock()?;
            let limit = query.limit.unwrap_or(20);
            if !(1..=100).contains(&limit) {
                return Err(invalid_request("Requisição inválida."));
            }
            let status = query.status.map(OrderStatus::as_str).unwrap_or("");
            let after = match &query.cursor {
                None => None,
                Some(cursor) => {
                    let decoded = unhex(cursor).ok_or_else(invalid_cursor)?;
                    let mut parts = decoded.splitn(3, '|');
                    let (Some(at), Some(id), Some(s)) = (parts.next(), parts.next(), parts.next())
                    else {
                        return Err(invalid_cursor());
                    };
                    if s != status || !is_uuid(id) || Instant::parse(at).is_none() {
                        return Err(invalid_cursor());
                    }
                    Some((at.to_owned(), id.to_owned()))
                }
            };
            let mut rows: Vec<&Order> = state
                .orders
                .iter()
                .filter(|r| r.mine && query.status.is_none_or(|s| r.order.status == s))
                .map(|r| &r.order)
                .collect();
            rows.sort_by(|a, b| {
                (a.created_at.to_utc(), &a.id).cmp(&(b.created_at.to_utc(), &b.id))
            });
            let rows: Vec<&Order> = rows
                .into_iter()
                .filter(|o| match &after {
                    None => true,
                    Some((at, id)) => {
                        let key = (Instant::parse(at).expect("checked").to_utc(), id);
                        (o.created_at.to_utc(), &o.id) > (key.0, key.1)
                    }
                })
                .collect();
            let page: Vec<_> = rows
                .iter()
                .take(limit as usize)
                .map(|o| o.summary())
                .collect();
            let next_cursor = (rows.len() > limit as usize).then(|| {
                let last = page.last().expect("non-empty page");
                hex(&format!(
                    "{}|{}|{status}",
                    last.created_at.as_str(),
                    last.id
                ))
            });
            Ok(OrderList {
                items: page,
                next_cursor,
            })
        })
        .await
    }

    async fn get_order(&self, order_id: &str) -> ApiResult<Tagged<Order>> {
        span("print_api.getOrder", "GET", async {
            let state = self.lock()?;
            let order = &state.orders[visible_index(&state, order_id)?].order;
            Ok(Tagged {
                body: order.clone(),
                etag: etag(order_id, order.version),
            })
        })
        .await
    }

    async fn order_file(&self, order_id: &str, file_id: &str) -> ApiResult<Download> {
        span("print_api.orderFile", "GET", async {
            let state = self.lock()?;
            let record = &state.orders[visible_index(&state, order_id)?];
            if record.order.status == OrderStatus::Cancelled {
                return Err(not_found());
            }
            record
                .files
                .get(file_id)
                .map(download)
                .ok_or_else(not_found)
        })
        .await
    }

    async fn collect(
        &self,
        order_id: &str,
        revision: u64,
        pre: &Preconditions,
    ) -> ApiResult<Command<Order>> {
        span("print_api.collect", "POST", async {
            self.order_command(
                order_id,
                "collected",
                format!("revision={revision}"),
                pre,
                200,
                |record, now| {
                    let order = &mut record.order;
                    if order.status != OrderStatus::Ready {
                        return Err(invalid_state());
                    }
                    if revision != order.revision {
                        return Err(version_mismatch());
                    }
                    order.status = OrderStatus::FilesCollected;
                    order.collected_at = Some(now.into());
                    Ok(())
                },
            )
        })
        .await
    }

    async fn submit_quote(
        &self,
        order_id: &str,
        amount_cents: i64,
        order_revision: u64,
        file: Upload,
        pre: &Preconditions,
    ) -> ApiResult<Command<Order>> {
        span("print_api.submitQuote", "POST", async {
            let prepared = prepare_document(&file);
            let stored = match prepared {
                Ok(stored) => stored,
                Err(error) => {
                    // Authorization precedes validation: a foreign id is 404.
                    visible_index(&*self.lock()?, order_id)?;
                    return Err(error);
                }
            };
            let fields = format!(
                "amountCents={amount_cents} orderRevision={order_revision} sha256={}",
                stored.meta.sha256
            );
            self.order_command(order_id, "quotes", fields, pre, 201, |record, now| {
                let order = &mut record.order;
                if !matches!(
                    order.status,
                    OrderStatus::FilesCollected | OrderStatus::QuoteRejected
                ) {
                    return Err(invalid_state());
                }
                if order_revision != order.revision {
                    return Err(version_mismatch());
                }
                record.quote_count += 1;
                let id = uuid::Uuid::new_v4().to_string();
                let document = FileRef {
                    id: id.clone(),
                    ..stored.meta.clone()
                };
                order.current_quote = Some(Quote {
                    id,
                    revision: record.quote_count,
                    order_revision,
                    amount_cents,
                    currency: Currency::Brl,
                    document: document.clone(),
                    decision: QuoteDecision::Pending,
                    rejection_reason: None,
                    submitted_at: now.into(),
                    decided_at: None,
                });
                order.status = OrderStatus::QuotePending;
                record.quote_document = Some(Stored {
                    meta: document,
                    bytes: stored.bytes,
                });
                Ok(())
            })
        })
        .await
    }

    async fn quote_file(&self, order_id: &str, quote_id: &str) -> ApiResult<Download> {
        span("print_api.quoteFile", "GET", async {
            let state = self.lock()?;
            let record = &state.orders[visible_index(&state, order_id)?];
            match (&record.order.current_quote, &record.quote_document) {
                (Some(quote), Some(stored)) if quote.id == quote_id => Ok(download(stored)),
                _ => Err(not_found()),
            }
        })
        .await
    }

    async fn mark_printed(
        &self,
        order_id: &str,
        revision: u64,
        quote_id: &str,
        pre: &Preconditions,
    ) -> ApiResult<Command<Order>> {
        span("print_api.markPrinted", "POST", async {
            let fields = format!("revision={revision} quoteId={quote_id}");
            self.order_command(order_id, "printed", fields, pre, 200, |record, now| {
                let order = &mut record.order;
                let approved = order
                    .current_quote
                    .as_ref()
                    .filter(|q| q.decision == QuoteDecision::Approved);
                let Some(quote) = approved.filter(|_| order.status == OrderStatus::QuoteApproved)
                else {
                    return Err(invalid_state());
                };
                if revision != order.revision || quote_id != quote.id {
                    return Err(version_mismatch());
                }
                order.status = OrderStatus::Printed;
                order.printed_at = Some(now.into());
                Ok(())
            })
        })
        .await
    }

    async fn get_close(&self, competence: Competence) -> ApiResult<Tagged<Close>> {
        span("print_api.getClose", "GET", async {
            let now = self.now();
            let state = self.lock()?;
            let mut close = state
                .closes
                .get(&competence)
                .map(|r| r.close.clone())
                .unwrap_or_else(|| Self::virtual_close(competence, now));
            close.period_closed = competence.is_closed(now);
            Ok(Tagged {
                etag: close_etag(competence, &close),
                body: close,
            })
        })
        .await
    }

    async fn submit_invoice(
        &self,
        competence: Competence,
        declared_total_cents: i64,
        file: Upload,
        pre: &Preconditions,
    ) -> ApiResult<Command<Close>> {
        span("print_api.submitInvoice", "POST", async {
            let now = self.now();
            let mut state = self.lock()?;
            let state = &mut *state;
            let (if_match, key) = required(pre)?;
            let stored = prepare_document(&file)?;
            let intent = format!(
                "POST invoice/{competence} {if_match} declaredTotalCents={declared_total_cents} sha256={}",
                stored.meta.sha256
            );
            match state.idempotency.get(&key) {
                Some((s, Replay::Close(command))) if *s == intent => {
                    return Ok(Command {
                        replayed: true,
                        ..command.clone()
                    });
                }
                Some(_) => {
                    return Err(reject(
                        409,
                        codes::IDEMPOTENCY_CONFLICT,
                        "A chave de idempotência já foi usada para outra operação.",
                    ));
                }
                None => {}
            }
            let Some(record) = state.closes.get_mut(&competence) else {
                return Err(if if_match == format!("\"month:{competence}:0\"") {
                    reject(409, codes::EMPTY_CLOSE, "Não há pedidos impressos nesta competência.")
                } else {
                    version_mismatch()
                });
            };
            if if_match != close_etag(competence, &record.close) {
                return Err(version_mismatch());
            }
            let close = &mut record.close;
            if !matches!(close.state, CloseState::Open | CloseState::Rejected) {
                return Err(reject(
                    409,
                    codes::INVALID_STATE,
                    "O fechamento não está em um estado que permita esta operação.",
                ));
            }
            if !competence.is_closed(now) {
                return Err(reject(
                    409,
                    codes::PERIOD_OPEN,
                    "A competência ainda não terminou. A NF só pode ser enviada depois do fim do mês.",
                ));
            }
            if close.items.is_empty() {
                return Err(reject(409, codes::EMPTY_CLOSE, "Não há pedidos impressos nesta competência."));
            }
            close.state = CloseState::Submitted;
            close.period_closed = true;
            close.declared_total_cents = Some(declared_total_cents);
            close.document = Some(stored.meta.clone());
            close.rejection_reason = None;
            close.submitted_at = Some(now.into());
            close.version += 1;
            record.document = Some(stored);
            let command = Command {
                status: 201,
                body: record.close.clone(),
                etag: close_etag(competence, &record.close),
                replayed: false,
            };
            state
                .idempotency
                .insert(key, (intent, Replay::Close(command.clone())));
            Ok(command)
        })
        .await
    }

    async fn invoice_file(&self, competence: Competence) -> ApiResult<Download> {
        span("print_api.invoiceFile", "GET", async {
            let state = self.lock()?;
            state
                .closes
                .get(&competence)
                .and_then(|r| r.document.as_ref())
                .map(download)
                .ok_or_else(not_found)
        })
        .await
    }
}

fn invalid_cursor() -> ApiError {
    reject(400, codes::INVALID_CURSOR, "Cursor inválido.")
}

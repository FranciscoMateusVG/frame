//! In-memory fake of the Incluir print-portal service API, for tests and
//! local development. Same contract as the real adapter (checked by the
//! shared conformance suite): ETag/If-Match CAS, Idempotency-Key replay and
//! conflict, the batch state machine, supplier scoping (another supplier's
//! batches are 404) and the monthly close. Financeiro's human decisions
//! (quote decision, receipt, cancellation) are test hooks here; through the
//! real API they need a human session.
use async_trait::async_trait;
use bytes::Bytes;
use chrono::{DateTime, Utc};
use frame_observability::in_span;
use frame_portal_domain::{
    Batch, BatchList, BatchQuote, BatchStatus, Close, CloseItem, CloseState, Competence, Currency,
    FileRef, Instant, QuoteDecision, is_uuid, sanitize_download_name,
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

struct Stored {
    meta: FileRef,
    bytes: Bytes,
}

struct BatchRecord {
    batch: Batch,
    mine: bool,
    /// Member file bytes by `orderId/fileId`.
    files: HashMap<String, Stored>,
    quote_document: Option<Stored>,
    quote_count: u64,
}

struct CloseRecord {
    close: Close,
    document: Option<Stored>,
}

enum Replay {
    Batch(Command<Batch>),
    Close(Command<Close>),
}

#[derive(Default)]
struct State {
    batches: Vec<BatchRecord>,
    closes: HashMap<Competence, CloseRecord>,
    idempotency: HashMap<String, (String, Replay)>,
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
        "O lote foi atualizado. Consulte novamente antes de repetir.",
    )
}
fn invalid_state() -> ApiError {
    reject(
        409,
        codes::INVALID_STATE,
        "O lote não está em um estado que permita esta operação.",
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

    fn seed(&self, batch: Batch, files: &[(&str, &[u8])], mine: bool) -> String {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let mut stored = HashMap::new();
        for item in &batch.items {
            for meta in item.files() {
                let bytes = files
                    .iter()
                    .find(|(id, _)| *id == meta.id)
                    .map(|(_, b)| Bytes::copy_from_slice(b))
                    .expect("seed bytes for every file");
                stored.insert(
                    format!("{}/{}", item.order_id, meta.id),
                    Stored {
                        meta: meta.clone(),
                        bytes,
                    },
                );
            }
        }
        let quote_count = batch.current_quote.as_ref().map_or(0, |q| q.revision);
        let quote_document = batch.current_quote.as_ref().and_then(|q| {
            let (_, bytes) = files.iter().find(|(id, _)| *id == q.document.id)?;
            Some(Stored {
                meta: q.document.clone(),
                bytes: Bytes::copy_from_slice(bytes),
            })
        });
        let id = batch.id.clone();
        state.batches.push(BatchRecord {
            batch,
            mine,
            files: stored,
            quote_document,
            quote_count,
        });
        id
    }

    /// A batch of this supplier, verbatim (e.g. a frozen fixture snapshot),
    /// with the bytes of every member file (and current quote) by file id.
    pub fn seed_batch(&self, batch: Batch, files: &[(&str, &[u8])]) -> String {
        self.seed(batch, files, true)
    }
    /// A batch of another supplier: must stay invisible (404).
    pub fn seed_foreign_batch(&self, batch: Batch, files: &[(&str, &[u8])]) -> String {
        self.seed(batch, files, false)
    }

    fn staff_update(
        &self,
        batch_id: &str,
        apply: impl FnOnce(&mut Batch, DateTime<Utc>) -> Result<(), &'static str>,
    ) -> Result<(), &'static str> {
        let now = self.now();
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let record = state
            .batches
            .iter_mut()
            .find(|r| r.batch.id == batch_id)
            .ok_or("unknown batch")?;
        apply(&mut record.batch, now)?;
        record.batch.version += 1;
        Ok(())
    }

    /// Financeiro decision on the current quote (human route upstream).
    pub fn decide_quote(
        &self,
        batch_id: &str,
        approve: bool,
        reason: Option<&str>,
    ) -> Result<(), &'static str> {
        self.staff_update(batch_id, |batch, now| {
            let quote = batch.current_quote.as_mut().ok_or("no quote")?;
            if batch.status != BatchStatus::QuotePending || quote.decision != QuoteDecision::Pending
            {
                return Err("not pending");
            }
            quote.decided_at = Some(now.into());
            if approve {
                quote.decision = QuoteDecision::Approved;
                batch.approved_amount_cents = Some(quote.amount_cents);
                batch.status = BatchStatus::QuoteApproved;
            } else {
                quote.decision = QuoteDecision::Rejected;
                quote.rejection_reason = Some(reason.ok_or("reason required")?.into());
                batch.status = BatchStatus::QuoteRejected;
            }
            Ok(())
        })
    }

    /// Financeiro confirms the whole receipt (human route upstream).
    pub fn receive(&self, batch_id: &str) -> Result<(), &'static str> {
        self.staff_update(batch_id, |batch, now| {
            if batch.status != BatchStatus::Printed {
                return Err("not printed");
            }
            batch.status = BatchStatus::Received;
            batch.received_at = Some(now.into());
            Ok(())
        })
    }

    /// Whole-batch cancellation, only before printed (human route upstream).
    pub fn cancel(&self, batch_id: &str, reason: &str) -> Result<(), &'static str> {
        self.staff_update(batch_id, |batch, _| {
            if !batch.status.is_current() || batch.status == BatchStatus::Printed {
                return Err("not cancellable");
            }
            batch.status = BatchStatus::Cancelled;
            batch.cancellation_reason = Some(reason.into());
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
    /// idempotency (replay/409) → If-Match (412) → state machine (409).
    fn batch_command(
        &self,
        batch_id: &str,
        route: &str,
        intent_fields: String,
        pre: &Preconditions,
        status: u16,
        apply: impl FnOnce(&mut BatchRecord, DateTime<Utc>) -> ApiResult<()>,
    ) -> ApiResult<Command<Batch>> {
        let now = self.now();
        let mut state = self.lock()?;
        let state = &mut *state;
        let index = visible_index(state, batch_id)?;
        let (if_match, key) = required(pre)?;
        let intent = format!("POST {route}/{batch_id} {if_match} {intent_fields}");
        match state.idempotency.get(&key) {
            Some((stored, Replay::Batch(command))) if *stored == intent => {
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
        let record = &mut state.batches[index];
        if if_match != etag(batch_id, record.batch.version) {
            return Err(version_mismatch());
        }
        apply(record, now)?;
        record.batch.version += 1;
        if record.batch.status == BatchStatus::Printed {
            bill(state, index, now);
        }
        let record = &state.batches[index];
        let command = Command {
            status,
            body: record.batch.clone(),
            etag: etag(batch_id, record.batch.version),
            replayed: false,
        };
        state
            .idempotency
            .insert(key, (intent, Replay::Batch(command.clone())));
        Ok(command)
    }
}

fn visible_index(state: &State, batch_id: &str) -> ApiResult<usize> {
    if !is_uuid(batch_id) {
        return Err(not_found());
    }
    state
        .batches
        .iter()
        .position(|r| r.mine && r.batch.id == batch_id)
        .ok_or_else(not_found)
}

/// `printed` bills the whole batch quote once into the São Paulo month.
fn bill(state: &mut State, index: usize, now: DateTime<Utc>) {
    let batch = &state.batches[index].batch;
    let competence = Competence::containing(now);
    let item = CloseItem::Batch {
        batch_id: batch.id.clone(),
        reference: batch.reference.clone(),
        quote_id: batch
            .current_quote
            .as_ref()
            .map(|q| q.id.clone())
            .unwrap_or_default(),
        amount_cents: batch.approved_amount_cents.unwrap_or_default(),
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
    record.close.expected_total_cents += item.amount_cents();
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
    async fn list_batches(&self, query: &ListQuery) -> ApiResult<BatchList> {
        span("print_api.listBatches", "GET", async {
            let state = self.lock()?;
            let limit = query.limit.unwrap_or(20);
            if !(1..=100).contains(&limit) {
                return Err(invalid_request("Requisição inválida."));
            }
            let status = query.status.map(BatchStatus::as_str).unwrap_or("");
            let after = match &query.cursor {
                None => None,
                Some(cursor) => {
                    let decoded = unhex(cursor).ok_or_else(invalid_cursor)?;
                    let mut parts = decoded.splitn(3, '|');
                    let (Some(at), Some(id), Some(s)) = (parts.next(), parts.next(), parts.next())
                    else {
                        return Err(invalid_cursor());
                    };
                    if s != status || !is_uuid(id) {
                        return Err(invalid_cursor());
                    }
                    let at = Instant::parse(at).ok_or_else(invalid_cursor)?.to_utc();
                    Some((at, id.to_owned()))
                }
            };
            let mut rows: Vec<&Batch> = state
                .batches
                .iter()
                .filter(|r| r.mine && query.status.is_none_or(|s| r.batch.status == s))
                .map(|r| &r.batch)
                .collect();
            rows.sort_by(|a, b| {
                (a.created_at.to_utc(), &a.id).cmp(&(b.created_at.to_utc(), &b.id))
            });
            let rows: Vec<&Batch> = rows
                .into_iter()
                .filter(|b| {
                    after
                        .as_ref()
                        .is_none_or(|(at, id)| (b.created_at.to_utc(), &b.id) > (*at, id))
                })
                .collect();
            let page: Vec<_> = rows
                .iter()
                .take(limit as usize)
                .map(|b| b.summary())
                .collect();
            let next_cursor = (rows.len() > limit as usize).then(|| {
                let last = page.last().expect("non-empty page");
                hex(&format!(
                    "{}|{}|{status}",
                    last.created_at.as_str(),
                    last.id
                ))
            });
            Ok(BatchList {
                items: page,
                next_cursor,
            })
        })
        .await
    }

    async fn open_batch(&self) -> ApiResult<Option<Tagged<Batch>>> {
        span("print_api.openBatch", "GET", async {
            let state = self.lock()?;
            let mine = || state.batches.iter().filter(|r| r.mine).map(|r| &r.batch);
            if mine().any(|b| b.status.is_current() && b.status != BatchStatus::Open) {
                return Ok(None);
            }
            Ok(mine()
                .find(|b| b.status == BatchStatus::Open)
                .map(|b| Tagged {
                    body: b.clone(),
                    etag: etag(&b.id, b.version),
                }))
        })
        .await
    }

    async fn get_batch(&self, batch_id: &str) -> ApiResult<Tagged<Batch>> {
        span("print_api.getBatch", "GET", async {
            let state = self.lock()?;
            let batch = &state.batches[visible_index(&state, batch_id)?].batch;
            Ok(Tagged {
                body: batch.clone(),
                etag: etag(batch_id, batch.version),
            })
        })
        .await
    }

    async fn batch_file(
        &self,
        batch_id: &str,
        order_id: &str,
        file_id: &str,
    ) -> ApiResult<Download> {
        span("print_api.batchFile", "GET", async {
            let state = self.lock()?;
            let record = &state.batches[visible_index(&state, batch_id)?];
            record
                .files
                .get(&format!("{order_id}/{file_id}"))
                .map(download)
                .ok_or_else(not_found)
        })
        .await
    }

    async fn collect(&self, batch_id: &str, pre: &Preconditions) -> ApiResult<Command<Batch>> {
        span("print_api.collect", "POST", async {
            self.batch_command(
                batch_id,
                "collected",
                String::new(),
                pre,
                200,
                |record, now| {
                    let batch = &mut record.batch;
                    if batch.status != BatchStatus::Open {
                        return Err(invalid_state());
                    }
                    if batch.items.is_empty() {
                        return Err(reject(409, codes::EMPTY_BATCH, "O lote está vazio."));
                    }
                    batch.status = BatchStatus::FilesCollected;
                    batch.collected_at = Some(now.into());
                    Ok(())
                },
            )
        })
        .await
    }

    async fn submit_quote(
        &self,
        batch_id: &str,
        amount_cents: i64,
        file: Upload,
        pre: &Preconditions,
    ) -> ApiResult<Command<Batch>> {
        span("print_api.submitQuote", "POST", async {
            let prepared = prepare_document(&file);
            let stored = match prepared {
                Ok(stored) => stored,
                Err(error) => {
                    // Authorization precedes validation: a foreign id is 404.
                    visible_index(&*self.lock()?, batch_id)?;
                    return Err(error);
                }
            };
            let fields = format!("amountCents={amount_cents} sha256={}", stored.meta.sha256);
            self.batch_command(batch_id, "quotes", fields, pre, 201, |record, now| {
                let batch = &mut record.batch;
                if !matches!(
                    batch.status,
                    BatchStatus::FilesCollected | BatchStatus::QuoteRejected
                ) {
                    return Err(invalid_state());
                }
                record.quote_count += 1;
                let id = uuid::Uuid::new_v4().to_string();
                let document = FileRef {
                    id: id.clone(),
                    ..stored.meta.clone()
                };
                batch.current_quote = Some(BatchQuote {
                    id,
                    revision: record.quote_count,
                    amount_cents,
                    currency: Currency::Brl,
                    document: document.clone(),
                    decision: QuoteDecision::Pending,
                    rejection_reason: None,
                    submitted_at: now.into(),
                    decided_at: None,
                });
                batch.status = BatchStatus::QuotePending;
                record.quote_document = Some(Stored {
                    meta: document,
                    bytes: stored.bytes,
                });
                Ok(())
            })
        })
        .await
    }

    async fn quote_file(&self, batch_id: &str, quote_id: &str) -> ApiResult<Download> {
        span("print_api.quoteFile", "GET", async {
            let state = self.lock()?;
            let record = &state.batches[visible_index(&state, batch_id)?];
            match (&record.batch.current_quote, &record.quote_document) {
                (Some(quote), Some(stored)) if quote.id == quote_id => Ok(download(stored)),
                _ => Err(not_found()),
            }
        })
        .await
    }

    async fn mark_printed(
        &self,
        batch_id: &str,
        quote_id: &str,
        pre: &Preconditions,
    ) -> ApiResult<Command<Batch>> {
        span("print_api.markPrinted", "POST", async {
            let fields = format!("quoteId={quote_id}");
            self.batch_command(batch_id, "printed", fields, pre, 200, |record, now| {
                let batch = &mut record.batch;
                let approved = batch
                    .current_quote
                    .as_ref()
                    .filter(|q| q.decision == QuoteDecision::Approved);
                let Some(quote) = approved.filter(|_| batch.status == BatchStatus::QuoteApproved)
                else {
                    return Err(invalid_state());
                };
                if quote_id != quote.id {
                    return Err(version_mismatch());
                }
                batch.status = BatchStatus::Printed;
                batch.printed_at = Some(now.into());
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

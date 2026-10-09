//! A fake Incluir Hono on a real socket: the upstream HTTP shapes of
//! `/api/print-portal/v2` (bearer check, ETag, Idempotency-Replayed,
//! Retry-After, error envelope, download headers) served from the
//! in-memory fake. Lets the real HTTP adapter run the shared conformance
//! suite through an actual network boundary. Fault hooks simulate delay,
//! redirects and contract-breaking bodies.
#![allow(dead_code)]
use axum::{
    Json, Router,
    body::Body,
    extract::{Multipart, Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use frame_portal_domain::{BatchStatus, Competence, content_disposition};
use frame_portal_memory::PrintApiMemory;
use frame_portal_port::{ApiError, Command, Download, ListQuery, Preconditions, PrintApi, Upload};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicU8, AtomicU64, Ordering},
    },
};

pub const TOKEN: &str = "fake-hono-service-token-0123456789abcdef0123456789";

/// 0 = normal, 1 = redirect every call, 2 = break the contract, 3 = 401.
#[derive(Default)]
pub struct Faults {
    pub delay_ms: AtomicU64,
    pub mode: AtomicU8,
}

struct Upstream {
    api: Arc<PrintApiMemory>,
    faults: Arc<Faults>,
}
type S = State<Arc<Upstream>>;

fn error_body(status: u16, code: &str, message: &str) -> Response {
    let status = StatusCode::from_u16(status).unwrap();
    (
        status,
        Json(json!({"error": {"code": code, "message": message, "requestId": "fake"}})),
    )
        .into_response()
}

fn api_error(e: ApiError) -> Response {
    match e {
        ApiError::Rejected {
            status,
            code,
            message,
            retry_after,
        } => {
            let mut r = error_body(status, &code, &message);
            if let Some(s) = retry_after {
                r.headers_mut()
                    .insert(header::RETRY_AFTER, HeaderValue::from(s));
            }
            r
        }
        ApiError::Unavailable { .. } => error_body(503, "UPSTREAM_UNAVAILABLE", "indisponível"),
    }
}

/// Bearer + fault injection; `None` means "go ahead".
async fn gate(up: &Upstream, headers: &HeaderMap) -> Option<Response> {
    let delay = up.faults.delay_ms.load(Ordering::SeqCst);
    if delay > 0 {
        tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
    }
    let bearer = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok());
    if bearer != Some(&format!("Bearer {TOKEN}")) || up.faults.mode.load(Ordering::SeqCst) == 3 {
        return Some(error_body(401, "UNAUTHORIZED", "Credencial inválida."));
    }
    match up.faults.mode.load(Ordering::SeqCst) {
        1 => Some(
            (
                StatusCode::FOUND,
                [(header::LOCATION, "http://127.0.0.1:9/steal")],
            )
                .into_response(),
        ),
        2 => Some(
            (
                StatusCode::OK,
                [(header::ETAG, "\"x:1\"")],
                Json(json!({"batch": {"id": "not-a-uuid"}, "items": [], "nextCursor": null, "close": 1})),
            )
                .into_response(),
        ),
        _ => None,
    }
}

fn pre(headers: &HeaderMap) -> Preconditions {
    let get = |n: &str| {
        headers
            .get(n)
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned)
    };
    Preconditions {
        if_match: get("if-match"),
        idempotency_key: get("idempotency-key"),
    }
}

fn tagged<T: Serialize>(key: &str, body: T, etag: &str) -> Response {
    let mut r = Json(json!({ key: body })).into_response();
    r.headers_mut()
        .insert(header::ETAG, HeaderValue::from_str(etag).unwrap());
    r
}

fn command<T: Serialize>(key: &str, c: Command<T>) -> Response {
    let mut r = tagged(key, c.body, &c.etag);
    *r.status_mut() = StatusCode::from_u16(c.status).unwrap();
    if c.replayed {
        r.headers_mut()
            .insert("idempotency-replayed", HeaderValue::from_static("true"));
    }
    r
}

fn download(d: Download) -> Response {
    let mut r = Response::new(Body::from_stream(d.body));
    let h = r.headers_mut();
    h.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(&d.mime).unwrap(),
    );
    if let Some(n) = d.length {
        h.insert(header::CONTENT_LENGTH, HeaderValue::from(n));
    }
    h.insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_str(&content_disposition(&d.filename)).unwrap(),
    );
    r
}

macro_rules! guard {
    ($up:expr, $headers:expr) => {
        if let Some(r) = gate(&$up, &$headers).await {
            return r;
        }
    };
}

async fn list(
    State(up): S,
    headers: HeaderMap,
    Query(q): Query<HashMap<String, String>>,
) -> Response {
    guard!(up, headers);
    let status = match q.get("status") {
        Some(s) => match BatchStatus::parse(s) {
            Some(s) => Some(s),
            None => return error_body(400, "INVALID_REQUEST", "Requisição inválida."),
        },
        None => None,
    };
    let limit = match q.get("limit").map(|l| l.parse::<u32>()) {
        Some(Ok(l)) => Some(l),
        Some(Err(_)) => return error_body(400, "INVALID_REQUEST", "Requisição inválida."),
        None => None,
    };
    let query = ListQuery {
        status,
        limit,
        cursor: q.get("cursor").cloned(),
    };
    match up.api.list_batches(&query).await {
        Ok(l) => Json(l).into_response(),
        Err(e) => api_error(e),
    }
}

async fn open(State(up): S, headers: HeaderMap) -> Response {
    guard!(up, headers);
    match up.api.open_batch().await {
        Ok(Some(t)) => tagged("batch", t.body, &t.etag),
        Ok(None) => Json(json!({ "batch": null })).into_response(),
        Err(e) => api_error(e),
    }
}

async fn batch(State(up): S, headers: HeaderMap, Path(id): Path<String>) -> Response {
    guard!(up, headers);
    match up.api.get_batch(&id).await {
        Ok(t) => tagged("batch", t.body, &t.etag),
        Err(e) => api_error(e),
    }
}

async fn batch_file(
    State(up): S,
    headers: HeaderMap,
    Path((id, o, f)): Path<(String, String, String)>,
) -> Response {
    guard!(up, headers);
    match up.api.batch_file(&id, &o, &f).await {
        Ok(d) => download(d),
        Err(e) => api_error(e),
    }
}

async fn quote_file(
    State(up): S,
    headers: HeaderMap,
    Path((id, q)): Path<(String, String)>,
) -> Response {
    guard!(up, headers);
    match up.api.quote_file(&id, &q).await {
        Ok(d) => download(d),
        Err(e) => api_error(e),
    }
}

async fn collected(
    State(up): S,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> Response {
    guard!(up, headers);
    if body != json!({}) {
        return error_body(400, "INVALID_REQUEST", "Requisição inválida.");
    }
    match up.api.collect(&id, &pre(&headers)).await {
        Ok(c) => command("batch", c),
        Err(e) => api_error(e),
    }
}

async fn printed(
    State(up): S,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> Response {
    guard!(up, headers);
    let Some(quote) = body["quoteId"].as_str() else {
        return error_body(400, "INVALID_REQUEST", "Requisição inválida.");
    };
    match up.api.mark_printed(&id, quote, &pre(&headers)).await {
        Ok(c) => command("batch", c),
        Err(e) => api_error(e),
    }
}

async fn form(mut m: Multipart) -> Option<(Upload, HashMap<String, String>)> {
    let mut file = None;
    let mut fields = HashMap::new();
    while let Some(f) = m.next_field().await.ok()? {
        let name = f.name()?.to_owned();
        if name == "file" {
            let filename = f.file_name().unwrap_or("x").to_owned();
            file = Some(Upload {
                filename,
                bytes: f.bytes().await.ok()?,
            });
        } else {
            fields.insert(name, f.text().await.ok()?);
        }
    }
    Some((file?, fields))
}

async fn quotes(
    State(up): S,
    headers: HeaderMap,
    Path(id): Path<String>,
    m: Multipart,
) -> Response {
    guard!(up, headers);
    let Some((file, fields)) = form(m).await else {
        return error_body(400, "INVALID_REQUEST", "Requisição inválida.");
    };
    let Some(amount) = fields.get("amountCents").and_then(|v| v.parse().ok()) else {
        return error_body(400, "INVALID_REQUEST", "Requisição inválida.");
    };
    if fields.len() != 1 {
        return error_body(400, "INVALID_REQUEST", "Requisição inválida.");
    }
    match up.api.submit_quote(&id, amount, file, &pre(&headers)).await {
        Ok(c) => command("batch", c),
        Err(e) => api_error(e),
    }
}

fn competence(raw: &str) -> Result<Competence, Box<Response>> {
    Competence::parse(raw).ok_or_else(|| {
        Box::new(error_body(
            400,
            "INVALID_COMPETENCE",
            "Competência inválida.",
        ))
    })
}

async fn close(State(up): S, headers: HeaderMap, Path(c): Path<String>) -> Response {
    guard!(up, headers);
    let c = match competence(&c) {
        Ok(c) => c,
        Err(r) => return *r,
    };
    match up.api.get_close(c).await {
        Ok(t) => tagged("close", t.body, &t.etag),
        Err(e) => api_error(e),
    }
}

async fn invoice(
    State(up): S,
    headers: HeaderMap,
    Path(c): Path<String>,
    m: Multipart,
) -> Response {
    guard!(up, headers);
    let c = match competence(&c) {
        Ok(c) => c,
        Err(r) => return *r,
    };
    let Some((file, fields)) = form(m).await else {
        return error_body(400, "INVALID_REQUEST", "Requisição inválida.");
    };
    let Some(declared) = fields
        .get("declaredTotalCents")
        .and_then(|v| v.parse().ok())
    else {
        return error_body(400, "INVALID_REQUEST", "Requisição inválida.");
    };
    match up
        .api
        .submit_invoice(c, declared, file, &pre(&headers))
        .await
    {
        Ok(cmd) => command("close", cmd),
        Err(e) => api_error(e),
    }
}

async fn invoice_file(State(up): S, headers: HeaderMap, Path(c): Path<String>) -> Response {
    guard!(up, headers);
    let c = match competence(&c) {
        Ok(c) => c,
        Err(r) => return *r,
    };
    match up.api.invoice_file(c).await {
        Ok(d) => download(d),
        Err(e) => api_error(e),
    }
}

pub struct FakeHono {
    pub origin: String,
    pub api: Arc<PrintApiMemory>,
    pub faults: Arc<Faults>,
    task: tokio::task::JoinHandle<()>,
}

impl FakeHono {
    pub async fn start(api: Arc<PrintApiMemory>) -> Self {
        let faults = Arc::new(Faults::default());
        let state = Arc::new(Upstream {
            api: api.clone(),
            faults: faults.clone(),
        });
        let routes = Router::new()
            .route("/batches", get(list))
            .route("/batches/open", get(open))
            .route("/batches/{id}", get(batch))
            .route("/batches/{id}/orders/{order}/files/{file}", get(batch_file))
            .route("/batches/{id}/collected", post(collected))
            .route("/batches/{id}/quotes", post(quotes))
            .route("/batches/{id}/quotes/{quote}/file", get(quote_file))
            .route("/batches/{id}/printed", post(printed))
            .route("/monthly-closes/{c}", get(close))
            .route(
                "/monthly-closes/{c}/invoice",
                get(invoice_file).post(invoice),
            )
            .layer(axum::extract::DefaultBodyLimit::max(8 * 1024 * 1024));
        let app = Router::new()
            .nest("/api/print-portal/v2", routes)
            .with_state(state);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        Self {
            origin,
            api,
            faults,
            task,
        }
    }
    pub fn set_mode(&self, mode: u8) {
        self.faults.mode.store(mode, Ordering::SeqCst);
    }
    pub fn set_delay_ms(&self, ms: u64) {
        self.faults.delay_ms.store(ms, Ordering::SeqCst);
    }
}

impl Drop for FakeHono {
    fn drop(&mut self) {
        self.task.abort();
    }
}

//! JSON surface of the BFF (spec §4.5): `/api/session` and the
//! `/api/print/v2` batch routes. Session cookie instead of bearer; every POST
//! needs exact Origin + `X-CSRF-Token`. Bodies are validated here, then the
//! upstream decides (If-Match, Idempotency-Key, state). Upstream contract
//! errors are relayed with their status/code; anything else is 503
//! `UPSTREAM_UNAVAILABLE` — never "type the password again".
use crate::{
    AppState, RequestId,
    security::{
        CSRF_HEADER, PRESESSION_COOKIE, SESSION_COOKIE, clear_cookie, client_ip, cookie, csrf_ok,
        origin_ok, set_cookie,
    },
};
use axum::{
    Json, Router,
    body::{Body, to_bytes},
    extract::{ConnectInfo, DefaultBodyLimit, FromRequest, Multipart, Path, Query, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use frame_portal_domain::{BatchStatus, Competence, content_disposition, is_uuid, parse_cents};
use frame_portal_port::{
    ApiError, Command, DOCUMENT_MAX_BYTES, Download, ListQuery, Preconditions, Upload,
};
use frame_portal_use_cases::{
    AuthDeps, LoginError, LoginInput, LogoutDeps, PrintDeps, SessionView, collect_files,
    download_batch_file, download_invoice, download_quote_file, get_batch, get_monthly_close,
    list_batches, login, logout, mark_printed, submit_invoice, submit_quote,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::HashMap, net::SocketAddr, sync::Arc};

/// Multipart envelope allowance on top of the 5 MiB document (spec §4.3).
pub const UPLOAD_BODY_LIMIT: usize = DOCUMENT_MAX_BYTES + 512 * 1024;
const JSON_BODY_LIMIT: usize = 16 * 1024;

type AppStateRef = State<Arc<AppState>>;

pub fn error(status: StatusCode, code: &str, message: &str, request_id: &RequestId) -> Response {
    let mut response = (
        status,
        Json(json!({"error": {"code": code, "message": message, "requestId": request_id.0}})),
    )
        .into_response();
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

fn unauthenticated(rid: &RequestId) -> Response {
    error(
        StatusCode::UNAUTHORIZED,
        "UNAUTHENTICATED",
        "Sessão ausente ou expirada. Entre novamente.",
        rid,
    )
}
fn csrf_failed(rid: &RequestId) -> Response {
    error(
        StatusCode::FORBIDDEN,
        "CSRF_FAILED",
        "Requisição recusada. Recarregue a página e tente novamente.",
        rid,
    )
}
fn invalid(rid: &RequestId) -> Response {
    error(
        StatusCode::BAD_REQUEST,
        "INVALID_REQUEST",
        "Requisição inválida.",
        rid,
    )
}
fn not_found(rid: &RequestId) -> Response {
    error(
        StatusCode::NOT_FOUND,
        "NOT_FOUND",
        "Recurso não encontrado.",
        rid,
    )
}
fn too_large(rid: &RequestId) -> Response {
    error(
        StatusCode::PAYLOAD_TOO_LARGE,
        "FILE_TOO_LARGE",
        "Arquivo acima de 5 MB.",
        rid,
    )
}

pub fn upstream_error(e: &ApiError, rid: &RequestId) -> Response {
    match e {
        ApiError::Rejected {
            status,
            code,
            message,
            retry_after,
        } => {
            let status = StatusCode::from_u16(*status).unwrap_or(StatusCode::BAD_GATEWAY);
            let mut response = error(status, code, message, rid);
            if let Some(seconds) = retry_after {
                response
                    .headers_mut()
                    .insert(header::RETRY_AFTER, HeaderValue::from(*seconds));
            }
            response
        }
        ApiError::Unavailable { .. } => error(
            StatusCode::SERVICE_UNAVAILABLE,
            "UPSTREAM_UNAVAILABLE",
            "Serviço da gráfica temporariamente indisponível. Consulte novamente em instantes.",
            rid,
        ),
    }
}

fn no_store(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

fn with_etag(mut response: Response, etag: &str) -> Response {
    if let Ok(value) = HeaderValue::from_str(etag) {
        response.headers_mut().insert(header::ETAG, value);
    }
    no_store(response)
}

fn command_response<T: Serialize>(key: &str, command: Command<T>) -> Response {
    let status = StatusCode::from_u16(command.status).unwrap_or(StatusCode::OK);
    let mut response = with_etag(
        (status, Json(json!({ key: command.body }))).into_response(),
        &command.etag,
    );
    if command.replayed {
        response
            .headers_mut()
            .insert("idempotency-replayed", HeaderValue::from_static("true"));
    }
    response
}

pub fn download_response(download: Download) -> Response {
    let mut response = Response::new(Body::from_stream(download.body));
    let headers = response.headers_mut();
    let mime = HeaderValue::from_str(&download.mime)
        .unwrap_or(HeaderValue::from_static("application/octet-stream"));
    headers.insert(header::CONTENT_TYPE, mime);
    if let Some(length) = download.length {
        headers.insert(header::CONTENT_LENGTH, HeaderValue::from(length));
    }
    if let Ok(value) = HeaderValue::from_str(&content_disposition(&download.filename)) {
        headers.insert(header::CONTENT_DISPOSITION, value);
    }
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(crate::security::DOWNLOAD_CSP),
    );
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    response
}

impl AppState {
    pub(crate) fn session(&self, headers: &HeaderMap) -> Option<SessionView> {
        let id = cookie(headers, SESSION_COOKIE)?;
        self.sessions.session(&id, (self.clock)())
    }
    pub(crate) fn print(&self) -> PrintDeps<'_> {
        PrintDeps {
            api: self.api.as_ref(),
            observability: &self.observability,
        }
    }
    /// The (possibly new) pre-session and the cookie to set if it is new.
    pub(crate) fn presession(&self, headers: &HeaderMap) -> (SessionView, Option<HeaderValue>) {
        let current = cookie(headers, PRESESSION_COOKIE);
        let (view, created) =
            self.sessions
                .presession(current.as_deref(), (self.clock)(), self.ids.as_ref());
        let max_age = self.sessions.policy().presession_ttl.num_seconds();
        let set = created.then(|| set_cookie(PRESESSION_COOKIE, &view.id, max_age));
        (view, set)
    }
}

fn session_body(authenticated: bool, csrf: &str, expires_at: Option<String>) -> Response {
    no_store(
        Json(json!({"authenticated": authenticated, "csrfToken": csrf, "expiresAt": expires_at}))
            .into_response(),
    )
}

fn instant(at: chrono::DateTime<chrono::Utc>) -> String {
    at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

async fn get_session(State(state): AppStateRef, headers: HeaderMap) -> Response {
    if let Some(session) = state.session(&headers) {
        return session_body(true, &session.csrf, Some(instant(session.expires_at)));
    }
    let (presession, set) = state.presession(&headers);
    let mut response = session_body(false, &presession.csrf, None);
    if let Some(set) = set {
        response.headers_mut().append(header::SET_COOKIE, set);
    }
    response
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LoginBody {
    password: String,
}

fn is_json(headers: &HeaderMap) -> bool {
    headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| {
            let essence = v.split(';').next().unwrap_or("").trim();
            essence.eq_ignore_ascii_case("application/json")
        })
}

/// A JSON object of exactly the expected shape, or `None` (→ 400).
async fn json_body<T: for<'de> Deserialize<'de>>(request: Request) -> Option<T> {
    if !is_json(request.headers()) {
        return None;
    }
    let bytes = to_bytes(request.into_body(), JSON_BODY_LIMIT).await.ok()?;
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    if !value.is_object() {
        return None;
    }
    serde_json::from_value(value).ok()
}

async fn post_session(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    request: Request,
) -> Response {
    let headers = request.headers().clone();
    if !origin_ok(&headers, &state.origin) {
        return csrf_failed(&rid);
    }
    let Some(body) = json_body::<LoginBody>(request).await else {
        return invalid(&rid);
    };
    if body.password.is_empty() || body.password.len() > 1024 {
        return invalid(&rid);
    }
    let presession = cookie(&headers, PRESESSION_COOKIE);
    let previous = cookie(&headers, SESSION_COOKIE);
    let csrf = headers.get(CSRF_HEADER).and_then(|v| v.to_str().ok());
    let result = login(
        AuthDeps {
            sessions: &state.sessions,
            limiter: &state.limiter,
            password: &state.password,
            clock: state.clock.as_ref(),
            new_id: state.ids.as_ref(),
            observability: &state.observability,
        },
        LoginInput {
            password: &body.password,
            client: client_ip(&headers, peer, &state.trusted_proxies),
            presession_id: presession.as_deref(),
            csrf_token: csrf,
            previous_session: previous.as_deref(),
        },
    )
    .await;
    match result {
        Ok(session) => {
            let max_age = state.sessions.policy().absolute.num_seconds();
            let mut response = session_body(true, &session.csrf, Some(instant(session.expires_at)));
            let headers = response.headers_mut();
            headers.append(
                header::SET_COOKIE,
                set_cookie(SESSION_COOKIE, &session.id, max_age),
            );
            headers.append(header::SET_COOKIE, clear_cookie(PRESESSION_COOKIE));
            response
        }
        Err(LoginError::CsrfFailed) => csrf_failed(&rid),
        Err(LoginError::InvalidCredentials) => error(
            StatusCode::UNAUTHORIZED,
            "INVALID_CREDENTIALS",
            "Senha incorreta.",
            &rid,
        ),
        Err(LoginError::RateLimited { retry_after }) => {
            let mut response = error(
                StatusCode::TOO_MANY_REQUESTS,
                "RATE_LIMITED",
                "Muitas tentativas. Aguarde antes de tentar novamente.",
                &rid,
            );
            response
                .headers_mut()
                .insert(header::RETRY_AFTER, HeaderValue::from(retry_after));
            response
        }
    }
}

async fn delete_session(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    headers: HeaderMap,
) -> Response {
    if !origin_ok(&headers, &state.origin) {
        return csrf_failed(&rid);
    }
    let session = state.session(&headers);
    if let Some(session) = &session
        && !csrf_ok(&headers, &state.origin, &session.csrf)
    {
        return csrf_failed(&rid);
    }
    let _ = logout(
        LogoutDeps {
            sessions: &state.sessions,
            observability: &state.observability,
        },
        session.as_ref().map(|s| s.id.as_str()),
    )
    .await;
    let mut response = StatusCode::NO_CONTENT.into_response();
    response
        .headers_mut()
        .append(header::SET_COOKIE, clear_cookie(SESSION_COOKIE));
    no_store(response)
}

/// Authenticated session, or the response to return instead.
fn authed(
    state: &AppState,
    headers: &HeaderMap,
    rid: &RequestId,
) -> Result<SessionView, Box<Response>> {
    state
        .session(headers)
        .ok_or_else(|| Box::new(unauthenticated(rid)))
}

/// Authenticated + exact Origin + CSRF token of that session.
fn commanded(
    state: &AppState,
    headers: &HeaderMap,
    rid: &RequestId,
) -> Result<SessionView, Box<Response>> {
    let session = authed(state, headers, rid)?;
    if !csrf_ok(headers, &state.origin, &session.csrf) {
        return Err(Box::new(csrf_failed(rid)));
    }
    Ok(session)
}

fn preconditions(headers: &HeaderMap) -> Preconditions {
    let value = |name: header::HeaderName| {
        headers
            .get(name)
            .and_then(|v| v.to_str().ok())
            .filter(|v| v.len() <= 200)
            .map(str::to_owned)
    };
    Preconditions {
        if_match: value(header::IF_MATCH),
        idempotency_key: value(header::HeaderName::from_static("idempotency-key")),
    }
}

async fn batches(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    if let Err(response) = authed(&state, &headers, &rid) {
        return *response;
    }
    let Some(query) = list_query(&query) else {
        return invalid(&rid);
    };
    match list_batches(state.print(), query).await {
        Ok(list) => no_store(Json(list).into_response()),
        Err(e) => upstream_error(&e, &rid),
    }
}

/// Same rules as the upstream: optional status enum, limit 1–100, cursor ≤ 512.
pub fn list_query(raw: &HashMap<String, String>) -> Option<ListQuery> {
    let status = match raw.get("status") {
        None => None,
        Some(s) => Some(BatchStatus::parse(s)?),
    };
    let limit = match raw.get("limit") {
        None => None,
        Some(l) => {
            let valid = !l.is_empty()
                && l.len() <= 3
                && !l.starts_with('0')
                && l.bytes().all(|b| b.is_ascii_digit());
            Some(l.parse::<u32>().ok().filter(|n| valid && *n <= 100)?)
        }
    };
    let cursor = match raw.get("cursor") {
        None => None,
        Some(c) if (1..=512).contains(&c.len()) => Some(c.clone()),
        Some(_) => return None,
    };
    Some(ListQuery {
        status,
        limit,
        cursor,
    })
}

async fn batch(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Response {
    if let Err(response) = authed(&state, &headers, &rid) {
        return *response;
    }
    if !is_uuid(&id) {
        return not_found(&rid);
    }
    match get_batch(state.print(), &id).await {
        Ok(tagged) => with_etag(
            Json(json!({"batch": tagged.body})).into_response(),
            &tagged.etag,
        ),
        Err(e) => upstream_error(&e, &rid),
    }
}

async fn batch_file(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    headers: HeaderMap,
    Path((id, order_id, file_id)): Path<(String, String, String)>,
) -> Response {
    if let Err(response) = authed(&state, &headers, &rid) {
        return *response;
    }
    if !is_uuid(&id) || !is_uuid(&order_id) || !is_uuid(&file_id) {
        return not_found(&rid);
    }
    match download_batch_file(state.print(), &id, &order_id, &file_id).await {
        Ok(download) => download_response(download),
        Err(e) => upstream_error(&e, &rid),
    }
}

async fn quote_file(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    headers: HeaderMap,
    Path((id, quote_id)): Path<(String, String)>,
) -> Response {
    if let Err(response) = authed(&state, &headers, &rid) {
        return *response;
    }
    if !is_uuid(&id) || !is_uuid(&quote_id) {
        return not_found(&rid);
    }
    match download_quote_file(state.print(), &id, &quote_id).await {
        Ok(download) => download_response(download),
        Err(e) => upstream_error(&e, &rid),
    }
}

/// `POST …/collected` takes exactly `{}`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CollectBody {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct PrintedBody {
    quote_id: String,
}

async fn collected(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    Path(id): Path<String>,
    request: Request,
) -> Response {
    let headers = request.headers().clone();
    if let Err(response) = commanded(&state, &headers, &rid) {
        return *response;
    }
    if json_body::<CollectBody>(request).await.is_none() {
        return invalid(&rid);
    }
    if !is_uuid(&id) {
        return not_found(&rid);
    }
    let pre = preconditions(&headers);
    match collect_files(state.print(), &id, &pre).await {
        Ok(command) => command_response("batch", command),
        Err(e) => upstream_error(&e, &rid),
    }
}

async fn printed(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    Path(id): Path<String>,
    request: Request,
) -> Response {
    let headers = request.headers().clone();
    if let Err(response) = commanded(&state, &headers, &rid) {
        return *response;
    }
    let Some(body) = json_body::<PrintedBody>(request).await else {
        return invalid(&rid);
    };
    if !is_uuid(&body.quote_id) {
        return invalid(&rid);
    }
    if !is_uuid(&id) {
        return not_found(&rid);
    }
    let pre = preconditions(&headers);
    match mark_printed(state.print(), &id, &body.quote_id, &pre).await {
        Ok(command) => command_response("batch", command),
        Err(e) => upstream_error(&e, &rid),
    }
}

/// Exactly the named fields, each once; `file` is the only file part.
struct Form {
    file: Upload,
    fields: HashMap<String, String>,
}

enum FormError {
    Invalid,
    TooLarge,
}

async fn read_form(
    state: &Arc<AppState>,
    request: Request,
    names: &[&str],
) -> Result<Form, FormError> {
    let multipart = request
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| {
            v.split(';')
                .next()
                .unwrap_or("")
                .trim()
                .eq_ignore_ascii_case("multipart/form-data")
        });
    if !multipart {
        return Err(FormError::Invalid);
    }
    let mut form = Multipart::from_request(request, state)
        .await
        .map_err(|_| FormError::Invalid)?;
    let size_error = |e: axum::extract::multipart::MultipartError| {
        if e.status() == StatusCode::PAYLOAD_TOO_LARGE {
            FormError::TooLarge
        } else {
            FormError::Invalid
        }
    };
    let mut file: Option<Upload> = None;
    let mut fields = HashMap::new();
    while let Some(mut field) = form.next_field().await.map_err(size_error)? {
        let name = field.name().unwrap_or("").to_owned();
        if !names.contains(&name.as_str())
            || fields.contains_key(&name)
            || (name == "file" && file.is_some())
        {
            return Err(FormError::Invalid);
        }
        if name == "file" {
            let filename = field.file_name().unwrap_or("documento").to_owned();
            let mut bytes = Vec::new();
            while let Some(chunk) = field.chunk().await.map_err(size_error)? {
                if bytes.len() + chunk.len() > DOCUMENT_MAX_BYTES {
                    return Err(FormError::TooLarge);
                }
                bytes.extend_from_slice(&chunk);
            }
            if bytes.is_empty() {
                return Err(FormError::Invalid);
            }
            file = Some(Upload {
                filename,
                bytes: bytes.into(),
            });
        } else {
            if field.file_name().is_some() {
                return Err(FormError::Invalid);
            }
            let mut value = Vec::new();
            while let Some(chunk) = field.chunk().await.map_err(size_error)? {
                value.extend_from_slice(&chunk);
                if value.len() > 32 {
                    return Err(FormError::Invalid);
                }
            }
            let value = String::from_utf8(value).map_err(|_| FormError::Invalid)?;
            fields.insert(name, value);
        }
    }
    let file = file.ok_or(FormError::Invalid)?;
    if fields.len() + 1 != names.len() {
        return Err(FormError::Invalid);
    }
    Ok(Form { file, fields })
}

async fn quotes(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    Path(id): Path<String>,
    request: Request,
) -> Response {
    let headers = request.headers().clone();
    if let Err(response) = commanded(&state, &headers, &rid) {
        return *response;
    }
    let form = match read_form(&state, request, &["file", "amountCents"]).await {
        Ok(form) => form,
        Err(FormError::TooLarge) => return too_large(&rid),
        Err(FormError::Invalid) => return invalid(&rid),
    };
    let Some(cents) = parse_cents(&form.fields["amountCents"]) else {
        return invalid(&rid);
    };
    if !is_uuid(&id) {
        return not_found(&rid);
    }
    let pre = preconditions(&headers);
    match submit_quote(state.print(), &id, cents, form.file, &pre).await {
        Ok(command) => command_response("batch", command),
        Err(e) => upstream_error(&e, &rid),
    }
}

fn competence(raw: &str, rid: &RequestId) -> Result<Competence, Box<Response>> {
    Competence::parse(raw).ok_or_else(|| {
        Box::new(error(
            StatusCode::BAD_REQUEST,
            "INVALID_COMPETENCE",
            "Competência inválida (use AAAA-MM).",
            rid,
        ))
    })
}

async fn monthly_close(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    headers: HeaderMap,
    Path(raw): Path<String>,
) -> Response {
    if let Err(response) = authed(&state, &headers, &rid) {
        return *response;
    }
    let competence = match competence(&raw, &rid) {
        Ok(c) => c,
        Err(response) => return *response,
    };
    match get_monthly_close(state.print(), competence).await {
        Ok(tagged) => with_etag(
            Json(json!({"close": tagged.body})).into_response(),
            &tagged.etag,
        ),
        Err(e) => upstream_error(&e, &rid),
    }
}

async fn invoice(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    Path(raw): Path<String>,
    request: Request,
) -> Response {
    let headers = request.headers().clone();
    if let Err(response) = commanded(&state, &headers, &rid) {
        return *response;
    }
    let competence = match competence(&raw, &rid) {
        Ok(c) => c,
        Err(response) => return *response,
    };
    let form = match read_form(&state, request, &["file", "declaredTotalCents"]).await {
        Ok(form) => form,
        Err(FormError::TooLarge) => return too_large(&rid),
        Err(FormError::Invalid) => return invalid(&rid),
    };
    let Some(declared) = parse_cents(&form.fields["declaredTotalCents"]) else {
        return invalid(&rid);
    };
    let pre = preconditions(&headers);
    match submit_invoice(state.print(), competence, declared, form.file, &pre).await {
        Ok(command) => command_response("close", command),
        Err(e) => upstream_error(&e, &rid),
    }
}

async fn invoice_file(
    State(state): AppStateRef,
    axum::Extension(rid): axum::Extension<RequestId>,
    headers: HeaderMap,
    Path(raw): Path<String>,
) -> Response {
    if let Err(response) = authed(&state, &headers, &rid) {
        return *response;
    }
    let competence = match competence(&raw, &rid) {
        Ok(c) => c,
        Err(response) => return *response,
    };
    match download_invoice(state.print(), competence).await {
        Ok(download) => download_response(download),
        Err(e) => upstream_error(&e, &rid),
    }
}

async fn method_not_allowed(axum::Extension(rid): axum::Extension<RequestId>) -> Response {
    error(
        StatusCode::METHOD_NOT_ALLOWED,
        "METHOD_NOT_ALLOWED",
        "Método não permitido.",
        &rid,
    )
}

async fn unknown(axum::Extension(rid): axum::Extension<RequestId>) -> Response {
    not_found(&rid)
}

/// The browser never authenticates with `Authorization` here (spec §4.5):
/// the BFF refuses it instead of ignoring it, before session or CSRF, so it
/// can neither be relayed upstream nor mistaken for a credential.
async fn refuse_authorization(request: Request, next: axum::middleware::Next) -> Response {
    if request.headers().contains_key(header::AUTHORIZATION) {
        let rid = request
            .extensions()
            .get::<RequestId>()
            .cloned()
            .unwrap_or_else(|| RequestId(String::new()));
        return error(
            StatusCode::BAD_REQUEST,
            "INVALID_REQUEST",
            "O portal não aceita o cabeçalho Authorization.",
            &rid,
        );
    }
    next.run(request).await
}

/// Request body lent to the handler; whatever it leaves unread stays here.
struct LentBody(Arc<std::sync::Mutex<Option<Body>>>);

impl axum::body::HttpBody for LentBody {
    type Data = bytes::Bytes;
    type Error = axum::Error;
    fn poll_frame(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Result<http_body::Frame<Self::Data>, Self::Error>>> {
        let mut slot = self.0.lock().unwrap_or_else(|e| e.into_inner());
        match slot.as_mut() {
            Some(body) => std::pin::Pin::new(body).poll_frame(cx),
            None => std::task::Poll::Ready(None),
        }
    }
}

/// An early rejection (no session, CSRF, Authorization, bad form…) must be
/// readable by a client that is still writing its body: after the handler
/// answers, the unread rest is drained (bounded by the upload cap) so the
/// connection is not torn down mid-write (EPIPE/ECONNRESET instead of 403).
async fn drain_unread_body(request: Request, next: axum::middleware::Next) -> Response {
    let (parts, body) = request.into_parts();
    let slot = Arc::new(std::sync::Mutex::new(Some(body)));
    let lent = Body::new(LentBody(slot.clone()));
    let response = next.run(Request::from_parts(parts, lent)).await;
    let rest = slot.lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(rest) = rest {
        let _ = to_bytes(rest, UPLOAD_BODY_LIMIT).await;
    }
    response
}

pub fn routes() -> Router<Arc<AppState>> {
    let upload = DefaultBodyLimit::max(UPLOAD_BODY_LIMIT);
    let print = Router::new()
        .route("/batches", get(batches))
        .route("/batches/{id}", get(batch))
        .route(
            "/batches/{id}/orders/{order_id}/files/{file_id}",
            get(batch_file),
        )
        .route("/batches/{id}/collected", axum::routing::post(collected))
        .route(
            "/batches/{id}/quotes",
            axum::routing::post(quotes).layer(upload),
        )
        .route("/batches/{id}/quotes/{quote_id}/file", get(quote_file))
        .route("/batches/{id}/printed", axum::routing::post(printed))
        .route("/monthly-closes/{competence}", get(monthly_close))
        .route(
            "/monthly-closes/{competence}/invoice",
            get(invoice_file).post(invoice).layer(upload),
        )
        .method_not_allowed_fallback(method_not_allowed)
        .fallback(unknown);
    Router::new()
        .route(
            "/api/session",
            get(get_session).post(post_session).delete(delete_session),
        )
        .nest("/api/print/v2", print)
        .route("/api", get(unknown))
        .route("/api/{*rest}", axum::routing::any(unknown))
        .layer(DefaultBodyLimit::max(JSON_BODY_LIMIT))
        .layer(axum::middleware::from_fn(refuse_authorization))
        .layer(axum::middleware::from_fn(drain_unread_body))
}

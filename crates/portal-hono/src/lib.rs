//! Real adapter: Incluir Hono `/api/print-portal/v1` over HTTP(S).
//!
//! - Fixed origin from configuration; ids/competences are validated before
//!   they become path segments, so no request can choose host or path.
//! - The bearer token lives only in a sensitive header value; redirects are
//!   never followed (a 3xx is "unavailable", the token never leaves).
//! - Every 2xx body is parsed strictly against the frozen schema; anything
//!   else is `Unavailable`, never a guessed success.
//! - One span per method (`print_api.<operation>`); adapters never log.
use async_trait::async_trait;
use bytes::Bytes;
use frame_observability::in_span;
use frame_portal_domain::{
    Close, CloseResponse, Competence, Order, OrderList, OrderResponse, Validate,
    disposition_filename, is_uuid, sanitize_download_name,
};
use frame_portal_port::{
    ApiError, ApiResult, Command, Download, ListQuery, Preconditions, PrintApi, Tagged, Upload,
};
use futures_util::{StreamExt, TryStreamExt};
use opentelemetry::{Context, KeyValue, global, trace::TraceContextExt};
use reqwest::{
    Method, RequestBuilder, Response, StatusCode,
    header::{self, HeaderValue},
    multipart::{Form, Part},
    redirect::Policy,
};
use serde::{Deserialize, de::DeserializeOwned};
use std::{future::Future, time::Duration};

pub const SYSTEM: &str = "incluir-hono";
const PREFIX: &str = "/api/print-portal/v1";
/// JSON bodies larger than this are not a contract response.
const MAX_JSON_BYTES: usize = 4 * 1024 * 1024;
/// Largest file the portal relays (print files are ≤ 20 MiB upstream;
/// quotes/NFs ≤ 5 MiB). Same bound as the other portals.
pub const MAX_DOWNLOAD_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct Timeouts {
    pub connect: Duration,
    pub json: Duration,
    pub upload: Duration,
    pub download: Duration,
}
impl Default for Timeouts {
    fn default() -> Self {
        Self {
            connect: Duration::from_secs(5),
            json: Duration::from_secs(15),
            upload: Duration::from_secs(60),
            download: Duration::from_secs(120),
        }
    }
}

pub struct PrintApiHono {
    client: reqwest::Client,
    base: String,
    authorization: HeaderValue,
    timeouts: Timeouts,
}

/// Configuration errors name the rule, never the value.
#[derive(Debug, PartialEq, Eq)]
pub struct ConfigError(pub &'static str);
impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for ConfigError {}

/// `scheme://host[:port]` only: no path, query, fragment or credentials.
pub fn parse_origin(raw: &str) -> Option<String> {
    let url = reqwest::Url::parse(raw).ok()?;
    let plain = matches!(url.scheme(), "http" | "https")
        && url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none()
        && url.path() == "/"
        && url.query().is_none()
        && url.fragment().is_none()
        && !raw.ends_with('/');
    plain.then(|| url.origin().ascii_serialization())
}

impl PrintApiHono {
    pub fn new(origin: &str, token: &str, timeouts: Timeouts) -> Result<Self, ConfigError> {
        let origin = parse_origin(origin).ok_or(ConfigError(
            "INCLUIR_PRINT_API_ORIGIN must be an http(s) origin without path",
        ))?;
        let valid_token = (32..=512).contains(&token.len())
            && token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._~+/=-".contains(&b));
        if !valid_token {
            return Err(ConfigError(
                "INCLUIR_PRINT_SERVICE_TOKEN must be 32-512 token characters",
            ));
        }
        let mut authorization = HeaderValue::from_str(&format!("Bearer {token}"))
            .map_err(|_| ConfigError("INCLUIR_PRINT_SERVICE_TOKEN is not a header value"))?;
        authorization.set_sensitive(true);
        let client = reqwest::Client::builder()
            .redirect(Policy::none())
            .connect_timeout(timeouts.connect)
            .no_proxy()
            .build()
            .map_err(|_| ConfigError("HTTP client could not be built"))?;
        Ok(Self {
            client,
            base: format!("{origin}{PREFIX}"),
            authorization,
            timeouts,
        })
    }

    fn request(&self, method: Method, path: &str, timeout: Duration) -> RequestBuilder {
        self.client
            .request(method, format!("{}{path}", self.base))
            .header(header::AUTHORIZATION, self.authorization.clone())
            .header(header::ACCEPT, "application/json")
            .timeout(timeout)
    }
}

fn preconditions(mut req: RequestBuilder, pre: &Preconditions) -> RequestBuilder {
    if let Some(v) = pre.if_match.as_deref() {
        req = req.header(header::IF_MATCH, v);
    }
    if let Some(v) = pre.idempotency_key.as_deref() {
        req = req.header("idempotency-key", v);
    }
    req
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ErrorBody {
    error: ErrorDetail,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
#[allow(dead_code)]
struct ErrorDetail {
    code: String,
    message: String,
    #[serde(rename = "requestId")]
    request_id: String,
}

async fn limited_body(response: Response, cap: usize) -> ApiResult<Bytes> {
    if response.content_length().is_some_and(|n| n > cap as u64) {
        return Err(ApiError::Unavailable { reason: "contract" });
    }
    let mut body = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| unavailable_from(&e))?;
        if body.len() + chunk.len() > cap {
            return Err(ApiError::Unavailable { reason: "contract" });
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body.into())
}

fn unavailable_from(error: &reqwest::Error) -> ApiError {
    ApiError::Unavailable {
        reason: if error.is_timeout() {
            "timeout"
        } else {
            "transport"
        },
    }
}

/// Sends and sorts the outcome: 2xx → response; contract 4xx → `Rejected`;
/// everything else (incl. 401/403 credential and 5xx) → `Unavailable`.
async fn send(req: RequestBuilder) -> ApiResult<Response> {
    let response = req.send().await.map_err(|e| unavailable_from(&e))?;
    let status = response.status();
    Context::current().span().set_attribute(KeyValue::new(
        "http.response.status_code",
        i64::from(status.as_u16()),
    ));
    if status.is_success() {
        return Ok(response);
    }
    if status.is_redirection() {
        return Err(ApiError::Unavailable { reason: "redirect" });
    }
    if matches!(status, StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) {
        return Err(ApiError::Unavailable {
            reason: "credential",
        });
    }
    if !status.is_client_error() {
        return Err(ApiError::Unavailable {
            reason: "upstream_error",
        });
    }
    let retry_after = response
        .headers()
        .get(header::RETRY_AFTER)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<u64>().ok());
    let body = limited_body(response, 64 * 1024).await?;
    let parsed: ErrorBody =
        serde_json::from_slice(&body).map_err(|_| ApiError::Unavailable { reason: "contract" })?;
    Err(ApiError::Rejected {
        status: status.as_u16(),
        code: parsed.error.code,
        message: parsed.error.message,
        retry_after,
    })
}

async fn json<T: DeserializeOwned + Validate>(
    response: Response,
) -> ApiResult<(T, Option<String>)> {
    let etag = response
        .headers()
        .get(header::ETAG)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    let body = limited_body(response, MAX_JSON_BYTES).await?;
    let parsed: T =
        serde_json::from_slice(&body).map_err(|_| ApiError::Unavailable { reason: "contract" })?;
    parsed
        .validate()
        .map_err(|_| ApiError::Unavailable { reason: "contract" })?;
    Ok((parsed, etag))
}

fn require_etag(etag: Option<String>) -> ApiResult<String> {
    etag.filter(|e| e.len() <= 200 && e.starts_with('"') && e.ends_with('"'))
        .ok_or(ApiError::Unavailable { reason: "contract" })
}

async fn command<T: DeserializeOwned + Validate, B>(
    response: Response,
    unwrap: impl FnOnce(T) -> B,
) -> ApiResult<Command<B>> {
    let status = response.status().as_u16();
    let replayed = response
        .headers()
        .get("idempotency-replayed")
        .is_some_and(|v| v.as_bytes() == b"true");
    let (body, etag) = json::<T>(response).await?;
    Ok(Command {
        status,
        body: unwrap(body),
        etag: require_etag(etag)?,
        replayed,
    })
}

fn download(response: Response) -> ApiResult<Download> {
    let headers = response.headers();
    let mime = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .filter(|v| {
            v.len() <= 100
                && v.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"/.+-; =".contains(&b))
        })
        .unwrap_or("application/octet-stream")
        .to_owned();
    let filename = headers
        .get(header::CONTENT_DISPOSITION)
        .and_then(|v| v.to_str().ok())
        .and_then(disposition_filename)
        .map(|n| sanitize_download_name(&n))
        .unwrap_or_else(|| "arquivo".into());
    // A relayed file must declare its size, within the cap, and the stream
    // must deliver exactly that: a short or overlong body is an error, never
    // a download that merely looks complete.
    let declared = response
        .content_length()
        .filter(|n| (1..=MAX_DOWNLOAD_BYTES).contains(n))
        .ok_or(ApiError::Unavailable { reason: "contract" })?;
    let stream = response.bytes_stream().map_err(std::io::Error::other);
    let body = futures_util::stream::unfold(
        (stream, 0u64, false),
        move |(mut stream, seen, done)| async move {
            if done {
                return None;
            }
            match stream.next().await {
                Some(Ok(chunk)) => {
                    let seen = seen + chunk.len() as u64;
                    if seen > declared {
                        let error = std::io::Error::other("body longer than Content-Length");
                        Some((Err(error), (stream, seen, true)))
                    } else {
                        Some((Ok(chunk), (stream, seen, false)))
                    }
                }
                Some(Err(error)) => Some((Err(error), (stream, seen, true))),
                None if seen == declared => None,
                None => {
                    let error = std::io::Error::other("body shorter than Content-Length");
                    Some((Err(error), (stream, seen, true)))
                }
            }
        },
    )
    .boxed();
    Ok(Download {
        mime,
        length: Some(declared),
        filename,
        body,
    })
}

fn not_found() -> ApiError {
    ApiError::rejected(404, "NOT_FOUND", "Recurso não encontrado.")
}

fn document(file: Upload) -> Part {
    Part::stream(file.bytes)
        .file_name(file.filename)
        .mime_str("application/octet-stream")
        .expect("static mime")
}

#[async_trait]
impl PrintApi for PrintApiHono {
    async fn list_orders(&self, query: &ListQuery) -> ApiResult<OrderList> {
        span("print_api.listOrders", "GET", async {
            let mut params: Vec<(&str, String)> = vec![];
            if let Some(status) = query.status {
                params.push(("status", status.as_str().into()));
            }
            if let Some(limit) = query.limit {
                params.push(("limit", limit.to_string()));
            }
            if let Some(cursor) = &query.cursor {
                params.push(("cursor", cursor.clone()));
            }
            let req = self
                .request(Method::GET, "/orders", self.timeouts.json)
                .query(&params);
            Ok(json::<OrderList>(send(req).await?).await?.0)
        })
        .await
    }

    async fn get_order(&self, order_id: &str) -> ApiResult<Tagged<Order>> {
        span("print_api.getOrder", "GET", async {
            if !is_uuid(order_id) {
                return Err(not_found());
            }
            let req = self.request(
                Method::GET,
                &format!("/orders/{order_id}"),
                self.timeouts.json,
            );
            let (body, etag) = json::<OrderResponse>(send(req).await?).await?;
            Ok(Tagged {
                body: body.order,
                etag: require_etag(etag)?,
            })
        })
        .await
    }

    async fn order_file(&self, order_id: &str, file_id: &str) -> ApiResult<Download> {
        span("print_api.orderFile", "GET", async {
            if !is_uuid(order_id) || !is_uuid(file_id) {
                return Err(not_found());
            }
            let path = format!("/orders/{order_id}/files/{file_id}");
            download(send(self.request(Method::GET, &path, self.timeouts.download)).await?)
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
            if !is_uuid(order_id) {
                return Err(not_found());
            }
            let path = format!("/orders/{order_id}/collected");
            let req = self
                .request(Method::POST, &path, self.timeouts.json)
                .json(&serde_json::json!({ "revision": revision }));
            command(send(preconditions(req, pre)).await?, |r: OrderResponse| {
                r.order
            })
            .await
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
            if !is_uuid(order_id) {
                return Err(not_found());
            }
            let form = Form::new()
                .part("file", document(file))
                .text("amountCents", amount_cents.to_string())
                .text("orderRevision", order_revision.to_string());
            let path = format!("/orders/{order_id}/quotes");
            let req = self
                .request(Method::POST, &path, self.timeouts.upload)
                .multipart(form);
            command(send(preconditions(req, pre)).await?, |r: OrderResponse| {
                r.order
            })
            .await
        })
        .await
    }

    async fn quote_file(&self, order_id: &str, quote_id: &str) -> ApiResult<Download> {
        span("print_api.quoteFile", "GET", async {
            if !is_uuid(order_id) || !is_uuid(quote_id) {
                return Err(not_found());
            }
            let path = format!("/orders/{order_id}/quotes/{quote_id}/file");
            download(send(self.request(Method::GET, &path, self.timeouts.download)).await?)
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
            if !is_uuid(order_id) {
                return Err(not_found());
            }
            let path = format!("/orders/{order_id}/printed");
            let req = self
                .request(Method::POST, &path, self.timeouts.json)
                .json(&serde_json::json!({ "revision": revision, "quoteId": quote_id }));
            command(send(preconditions(req, pre)).await?, |r: OrderResponse| {
                r.order
            })
            .await
        })
        .await
    }

    async fn get_close(&self, competence: Competence) -> ApiResult<Tagged<Close>> {
        span("print_api.getClose", "GET", async {
            let path = format!("/monthly-closes/{competence}");
            let req = self.request(Method::GET, &path, self.timeouts.json);
            let (body, etag) = json::<CloseResponse>(send(req).await?).await?;
            Ok(Tagged {
                body: body.close,
                etag: require_etag(etag)?,
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
            let form = Form::new()
                .part("file", document(file))
                .text("declaredTotalCents", declared_total_cents.to_string());
            let path = format!("/monthly-closes/{competence}/invoice");
            let req = self
                .request(Method::POST, &path, self.timeouts.upload)
                .multipart(form);
            command(send(preconditions(req, pre)).await?, |r: CloseResponse| {
                r.close
            })
            .await
        })
        .await
    }

    async fn invoice_file(&self, competence: Competence) -> ApiResult<Download> {
        span("print_api.invoiceFile", "GET", async {
            let path = format!("/monthly-closes/{competence}/invoice");
            download(send(self.request(Method::GET, &path, self.timeouts.download)).await?)
        })
        .await
    }
}

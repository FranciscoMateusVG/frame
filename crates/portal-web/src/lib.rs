//! Print-shop portal (BFF + server-rendered HTML) over the Incluir
//! print-portal service API. No database, no object storage: the only
//! dependency is the `PrintApi` port, in-memory sessions per spec §5.
//!
//! `compose` is the production composition root (real Hono adapter);
//! `app` takes any `PrintApi`, which is how tests run the same router over
//! the in-memory fake and over a real socket.
mod api;
mod assets;
mod config;
mod pages;
mod security;

pub use api::{UPLOAD_BODY_LIMIT, list_query};
pub use config::{Config, ConfigError};
pub use security::{CSRF_HEADER, PRESESSION_COOKIE, SESSION_COOKIE, client_ip, cookie, random_id};

use axum::{
    Router,
    extract::{Request, State},
    http::{HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
};
use chrono::{DateTime, Utc};
use frame_observability::Observability;
use frame_portal_hono::{PrintApiHono, Timeouts};
use frame_portal_port::{ListQuery, PrintApi};
use frame_portal_use_cases::{
    IdGenerator, LimiterPolicy, LoginLimiter, PasswordVerifier, SessionPolicy, SessionRegistry,
};
use serde_json::json;
use std::{net::IpAddr, net::SocketAddr, sync::Arc};

pub type Clock = dyn Fn() -> DateTime<Utc> + Send + Sync;

/// Everything `app` needs besides the upstream port.
pub struct Settings {
    pub password: String,
    /// Exact `scheme://host[:port]` the browser uses (Origin check).
    pub origin: String,
    pub trusted_proxies: Vec<IpAddr>,
    pub session: SessionPolicy,
    pub limiter: LimiterPolicy,
}

pub struct AppState {
    pub(crate) api: Arc<dyn PrintApi>,
    pub(crate) sessions: SessionRegistry,
    pub(crate) limiter: LoginLimiter,
    pub(crate) password: PasswordVerifier,
    pub(crate) origin: String,
    pub(crate) trusted_proxies: Vec<IpAddr>,
    pub(crate) observability: Observability,
    pub(crate) clock: Arc<Clock>,
    pub(crate) ids: Arc<IdGenerator>,
}

/// Per-request id, echoed in error bodies and `X-Request-Id`.
#[derive(Clone, Debug)]
pub struct RequestId(pub String);

async fn context(mut request: Request, next: Next) -> Response {
    let id = uuid::Uuid::new_v4().to_string();
    request.extensions_mut().insert(RequestId(id.clone()));
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    if let Ok(value) = HeaderValue::from_str(&id) {
        headers.insert("x-request-id", value);
    }
    security::harden(headers);
    response
}

async fn healthz() -> Response {
    axum::Json(json!({"status": "ok"})).into_response()
}

/// Proves configuration + upstream reachability with the service token,
/// without exposing either (status word only).
async fn readyz(State(state): State<Arc<AppState>>) -> Response {
    let probe = ListQuery {
        limit: Some(1),
        ..ListQuery::default()
    };
    match state.api.list_orders(&probe).await {
        Ok(_) => axum::Json(json!({"status": "ready"})).into_response(),
        Err(_) => (
            StatusCode::SERVICE_UNAVAILABLE,
            axum::Json(json!({"status": "unavailable"})),
        )
            .into_response(),
    }
}

pub fn app(
    api: Arc<dyn PrintApi>,
    settings: Settings,
    observability: Observability,
    clock: Arc<Clock>,
) -> Router {
    let state = Arc::new(AppState {
        api,
        sessions: SessionRegistry::new(settings.session),
        limiter: LoginLimiter::new(settings.limiter),
        password: PasswordVerifier::new(&settings.password),
        origin: settings.origin,
        trusted_proxies: settings.trusted_proxies,
        observability,
        clock,
        ids: Arc::new(random_id),
    });
    Router::new()
        .route("/", get(pages::root))
        .route("/login", get(pages::login_page))
        .route("/orders", get(pages::orders_page))
        .route("/orders/{id}", get(pages::order_page))
        .route("/invoices", get(pages::invoices_page))
        .route("/assets/portal.js", get(assets::script))
        .route("/assets/portal.css", get(assets::style))
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .merge(api::routes())
        .fallback(pages::fallback)
        .layer(middleware::from_fn(context))
        .with_state(state)
}

pub fn system_clock() -> Arc<Clock> {
    Arc::new(|| std::time::SystemTime::now().into())
}

/// Production composition root: the real Hono adapter, nothing optional.
pub fn compose(config: &Config, observability: Observability) -> Result<Router, ConfigError> {
    let api = PrintApiHono::new(
        &config.upstream_origin,
        &config.service_token,
        Timeouts::default(),
    )
    .map_err(|e| ConfigError(e.to_string()))?;
    Ok(app(
        Arc::new(api),
        Settings {
            password: config.password.clone(),
            origin: config.portal_origin.clone(),
            trusted_proxies: config.trusted_proxies.clone(),
            session: config.session.clone(),
            limiter: LimiterPolicy::default(),
        },
        observability,
        system_clock(),
    ))
}

/// A running portal on a real socket (also used by the integration tests).
pub struct Server {
    pub base_url: String,
    pub addr: SocketAddr,
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<std::io::Result<()>>>,
}

impl Server {
    pub async fn start(listener: tokio::net::TcpListener, router: Router) -> std::io::Result<Self> {
        let addr = listener.local_addr()?;
        let (tx, rx) = tokio::sync::oneshot::channel();
        let service = router.into_make_service_with_connect_info::<SocketAddr>();
        let task = tokio::spawn(async move {
            axum::serve(listener, service)
                .with_graceful_shutdown(async {
                    let _ = rx.await;
                })
                .await
        });
        Ok(Self {
            base_url: format!("http://{addr}"),
            addr,
            shutdown: Some(tx),
            task: Some(task),
        })
    }

    pub async fn shutdown(mut self) {
        if let Some(tx) = self.shutdown.take() {
            let _ = tx.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
    }

    /// Resolves when the server stops (signal handling is the caller's).
    pub async fn wait(mut self) -> std::io::Result<()> {
        match self.task.take() {
            Some(task) => task.await.unwrap_or(Ok(())),
            None => Ok(()),
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

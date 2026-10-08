//! A minimal browser over real HTTP: keeps cookies (honouring Max-Age=0),
//! sends the exact Origin and the CSRF token like the portal's script, and
//! never follows redirects so tests can assert them.
#![allow(dead_code)]
use frame_portal_memory::PrintApiMemory;
use frame_portal_web::{Server, Settings, app};
use reqwest::{Method, RequestBuilder, Response, header};
use serde_json::Value;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

pub const PASSWORD: &str = "senha-da-grafica-2026!";

pub struct Browser {
    pub client: reqwest::Client,
    pub base: String,
    pub cookies: Mutex<HashMap<String, String>>,
    pub csrf: Mutex<String>,
}

impl Browser {
    pub fn new(base: &str) -> Self {
        Self {
            client: reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap(),
            base: base.into(),
            cookies: Mutex::default(),
            csrf: Mutex::default(),
        }
    }
    pub fn cookie(&self, name: &str) -> Option<String> {
        self.cookies.lock().unwrap().get(name).cloned()
    }
    pub fn csrf(&self) -> String {
        self.csrf.lock().unwrap().clone()
    }
    /// Raw request with the browser's cookies (no Origin/CSRF).
    pub fn request(&self, method: Method, path: &str) -> RequestBuilder {
        let jar = self
            .cookies
            .lock()
            .unwrap()
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ");
        let mut req = self.client.request(method, format!("{}{path}", self.base));
        if !jar.is_empty() {
            req = req.header(header::COOKIE, jar);
        }
        req
    }
    /// Same-origin command headers, as `portal.js` sends them.
    pub fn command(&self, method: Method, path: &str) -> RequestBuilder {
        self.request(method, path)
            .header(header::ORIGIN, &self.base)
            .header("x-csrf-token", self.csrf())
    }
    pub fn absorb(&self, response: &Response) {
        let mut jar = self.cookies.lock().unwrap();
        for value in response.headers().get_all(header::SET_COOKIE) {
            let raw = value.to_str().unwrap();
            let (pair, attrs) = raw.split_once(';').unwrap_or((raw, ""));
            let (name, value) = pair.split_once('=').unwrap();
            if attrs.contains("Max-Age=0") {
                jar.remove(name);
            } else {
                jar.insert(name.into(), value.into());
            }
        }
    }
    pub async fn send(&self, req: RequestBuilder) -> Response {
        let response = req.send().await.unwrap();
        self.absorb(&response);
        response
    }
    pub async fn json(&self, req: RequestBuilder) -> (u16, Value) {
        let response = self.send(req).await;
        let status = response.status().as_u16();
        let body = response.json().await.unwrap_or(Value::Null);
        (status, body)
    }
    /// GET /api/session, remembering the CSRF token it hands out.
    pub async fn session(&self) -> Value {
        let (status, body) = self.json(self.request(Method::GET, "/api/session")).await;
        assert_eq!(status, 200);
        *self.csrf.lock().unwrap() = body["csrfToken"].as_str().unwrap().into();
        body
    }
    pub async fn login(&self, password: &str) -> (u16, Value) {
        self.session().await;
        let (status, body) = self
            .json(
                self.command(Method::POST, "/api/session")
                    .json(&serde_json::json!({ "password": password })),
            )
            .await;
        if status == 200 {
            *self.csrf.lock().unwrap() = body["csrfToken"].as_str().unwrap().into();
        }
        (status, body)
    }
}

/// A portal on a real socket whose Origin is its own base URL.
pub async fn start_portal(
    api: Arc<dyn frame_portal_port::PrintApi>,
    clock: Arc<dyn Fn() -> chrono::DateTime<chrono::Utc> + Send + Sync>,
    observability: frame_observability::Observability,
    tune: impl FnOnce(&mut Settings),
) -> Server {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let mut settings = Settings {
        password: PASSWORD.into(),
        origin,
        trusted_proxies: vec![],
        session: Default::default(),
        limiter: Default::default(),
    };
    tune(&mut settings);
    Server::start(listener, app(api, settings, observability, clock))
        .await
        .unwrap()
}

pub fn memory(clock: &crate::portal_api_conformance::TestClock) -> Arc<PrintApiMemory> {
    Arc::new(PrintApiMemory::new(clock.as_fn()))
}

/// Captures every log record for confidentiality assertions.
#[derive(Default)]
pub struct CapturingLogger(pub Mutex<Vec<String>>);
impl frame_observability::Logger for CapturingLogger {
    fn log(
        &self,
        level: frame_observability::LogLevel,
        message: &str,
        attrs: Option<&frame_observability::LogAttributes>,
    ) {
        self.0.lock().unwrap().push(format!(
            "{} {message} {}",
            level.label(),
            attrs
                .map(|a| serde_json::to_string(a).unwrap())
                .unwrap_or_default()
        ));
    }
}

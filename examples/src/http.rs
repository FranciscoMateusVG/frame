use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use frame::{CatRepository, CreateCatDeps, CreateCatInput, Error, Observability, create_cat};
use frame_postgres::{CatRepositoryPostgres, Database};
use serde_json::{Value, json};
use std::sync::Arc;

struct AppState {
    repo: CatRepositoryPostgres,
    observability: Observability,
}

/// Actual example composition root: required real Postgres adapter, no optional
/// dependency or test-only replacement. HTTP remains outside the SDK.
pub fn app(db: Database, observability: Observability) -> Router {
    let state = Arc::new(AppState {
        repo: CatRepositoryPostgres::new(db),
        observability,
    });
    Router::new()
        .route("/cats", post(create))
        .route("/cats/{id}", get(find))
        .with_state(state)
}
async fn create(State(state): State<Arc<AppState>>, Json(body): Json<Value>) -> Response {
    let input = CreateCatInput {
        id: uuid::Uuid::new_v4().to_string(),
        name: body
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
    };
    match create_cat(
        CreateCatDeps {
            cat_repository: &state.repo,
            clock: &crate::clock,
            observability: &state.observability,
        },
        input,
    )
    .await
    {
        Ok(cat) => (StatusCode::CREATED, Json(cat)).into_response(),
        Err(error) => error_response(error),
    }
}
async fn find(State(state): State<Arc<AppState>>, Path(id): Path<String>) -> Response {
    match state.repo.find_by_id(&id).await {
        Ok(Some(cat)) => Json(cat).into_response(),
        Ok(None) => (StatusCode::NOT_FOUND, Json(json!({"error":"NOT_FOUND"}))).into_response(),
        Err(error) => error_response(error),
    }
}
fn error_response(error: Error) -> Response {
    let status = match &error {
        Error::CatAlreadyExists(_) => StatusCode::CONFLICT,
        Error::InvalidCatName(_) => StatusCode::BAD_REQUEST,
        // Axum handlers are infallible response producers: the explicit 500 is
        // its equivalent of Hono's default exception handler, not a domain error.
        Error::Infrastructure(_) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, "Internal Server Error").into_response();
        }
    };
    (
        status,
        Json(json!({"error":error.code(), "message":error.to_string()})),
    )
        .into_response()
}

pub struct Server {
    pub base_url: String,
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<std::io::Result<()>>>,
}
impl Server {
    pub async fn start(db: Database, observability: Observability) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base_url = format!("http://{}", listener.local_addr().unwrap());
        let (tx, rx) = tokio::sync::oneshot::channel();
        let app = app(db, observability);
        let task = tokio::spawn(async move {
            axum::serve(listener, app)
                .with_graceful_shutdown(async {
                    let _ = rx.await;
                })
                .await
        });
        Self {
            base_url,
            shutdown: Some(tx),
            task: Some(task),
        }
    }
    pub async fn shutdown(mut self) {
        let _ = self.shutdown.take().unwrap().send(());
        self.task.take().unwrap().await.unwrap().unwrap();
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

pub async fn demonstrate(base_url: &str) {
    let client = reqwest::Client::new();
    let created = client
        .post(format!("{base_url}/cats"))
        .json(&json!({"name":"Whiskers"}))
        .send()
        .await
        .unwrap();
    assert_eq!(created.status(), 201);
    let cat: Value = created.json().await.unwrap();
    println!("POST /cats → 201 {cat}");
    let fetched = client
        .get(format!("{base_url}/cats/{}", cat["id"].as_str().unwrap()))
        .send()
        .await
        .unwrap();
    assert_eq!(fetched.status(), 200);
    assert_eq!(fetched.json::<Value>().await.unwrap(), cat);
    println!("GET /cats/:id → 200");
    for (name, status, code) in [
        ("Whiskers", 409, "CAT_ALREADY_EXISTS"),
        ("", 400, "INVALID_CAT_NAME"),
    ] {
        let response = client
            .post(format!("{base_url}/cats"))
            .json(&json!({"name":name}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), status);
        let error: Value = response.json().await.unwrap();
        assert_eq!(error["error"], code);
        assert!(error["message"].as_str().is_some_and(|s| !s.is_empty()));
        println!("POST /cats → {status} {error}");
    }
}

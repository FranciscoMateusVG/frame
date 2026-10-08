//! Black-box journey against a RUNNING `print-portal` wired to a real Incluir
//! Hono (Postgres/MinIO/Redis). Not part of `cargo xtask check` — it needs
//! that live stack. Inputs (env, never printed):
//!   PORTAL_BASE_URL         e.g. http://127.0.0.1:4000 (also the Origin)
//!   PRINT_PORTAL_PASSWORD   the portal's shared password
//!   E2E_ORDER_ID            a `ready` order of this supplier
//!   E2E_FOREIGN_ORDER_ID    an order of another supplier (must be invisible)
//!   APPROVE_QUOTE_CMD       command run with the order id as its argument;
//!                           performs Financeiro's human approval upstream
use reqwest::{Method, RequestBuilder, Response, header, multipart};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{collections::HashMap, process::Command, sync::Mutex};

struct Browser {
    client: reqwest::Client,
    base: String,
    jar: Mutex<HashMap<String, String>>,
    csrf: Mutex<String>,
}

impl Browser {
    fn request(&self, method: Method, path: &str) -> RequestBuilder {
        let jar: Vec<String> = self
            .jar
            .lock()
            .unwrap()
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect();
        let req = self.client.request(method, format!("{}{path}", self.base));
        if jar.is_empty() {
            req
        } else {
            req.header(header::COOKIE, jar.join("; "))
        }
    }
    fn command(&self, method: Method, path: &str) -> RequestBuilder {
        self.request(method, path)
            .header(header::ORIGIN, &self.base)
            .header("x-csrf-token", self.csrf.lock().unwrap().clone())
    }
    async fn send(&self, req: RequestBuilder) -> Response {
        let response = req.send().await.expect("portal reachable");
        let mut jar = self.jar.lock().unwrap();
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
        response
    }
    async fn json(&self, req: RequestBuilder) -> (u16, Value, header::HeaderMap) {
        let response = self.send(req).await;
        let status = response.status().as_u16();
        let headers = response.headers().clone();
        (
            status,
            response.json().await.unwrap_or(Value::Null),
            headers,
        )
    }
}

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is required"))
}
fn ok(step: &str) {
    println!("✓ {step}");
}
fn code(body: &Value) -> &str {
    body["error"]["code"].as_str().unwrap_or("")
}
fn key() -> String {
    uuid::Uuid::new_v4().to_string()
}

#[tokio::main]
async fn main() {
    let base = env("PORTAL_BASE_URL");
    let password = env("PRINT_PORTAL_PASSWORD");
    let order_id = env("E2E_ORDER_ID");
    let foreign = env("E2E_FOREIGN_ORDER_ID");
    let approve = env("APPROVE_QUOTE_CMD");
    let b = Browser {
        client: reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap(),
        base,
        jar: Mutex::default(),
        csrf: Mutex::default(),
    };

    assert_eq!(
        b.send(b.request(Method::GET, "/healthz")).await.status(),
        200
    );
    assert_eq!(
        b.send(b.request(Method::GET, "/readyz")).await.status(),
        200
    );
    ok("healthz/readyz 200 (service token accepted by the real Hono)");

    let r = b.send(b.request(Method::GET, "/orders")).await;
    assert_eq!(r.status(), 303);
    assert_eq!(r.headers()[header::LOCATION], "/login?next=%2Forders");
    let (status, body, _) = b.json(b.request(Method::GET, "/api/print/v1/orders")).await;
    assert_eq!((status, code(&body)), (401, "UNAUTHENTICATED"));
    ok("no session: HTML 303 → /login, JSON 401 UNAUTHENTICATED");

    let (_, session, _) = b.json(b.request(Method::GET, "/api/session")).await;
    *b.csrf.lock().unwrap() = session["csrfToken"].as_str().unwrap().into();
    let (status, body, _) = b
        .json(
            b.command(Method::POST, "/api/session")
                .json(&json!({"password": "definitivamente-errada"})),
        )
        .await;
    assert_eq!((status, code(&body)), (401, "INVALID_CREDENTIALS"));
    let (status, body, _) = b
        .json(
            b.command(Method::POST, "/api/session")
                .json(&json!({ "password": password })),
        )
        .await;
    assert_eq!(status, 200, "login");
    *b.csrf.lock().unwrap() = body["csrfToken"].as_str().unwrap().into();
    ok("login: wrong password 401, right password 200 with rotated session");

    let (status, list, _) = b
        .json(b.request(Method::GET, "/api/print/v1/orders?limit=100"))
        .await;
    assert_eq!(status, 200);
    let ids: Vec<&str> = list["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["id"].as_str().unwrap())
        .collect();
    assert!(ids.contains(&order_id.as_str()), "ready order listed");
    assert!(!ids.contains(&foreign.as_str()), "foreign order hidden");
    let (status, body, _) = b
        .json(b.request(Method::GET, &format!("/api/print/v1/orders/{foreign}")))
        .await;
    assert_eq!((status, code(&body)), (404, "NOT_FOUND"));
    ok(&format!(
        "list: {} visible orders, foreign order 404",
        ids.len()
    ));

    let path = format!("/api/print/v1/orders/{order_id}");
    let (status, order, headers) = b.json(b.request(Method::GET, &path)).await;
    assert_eq!(status, 200);
    assert_eq!(order["order"]["status"], "ready");
    let etag = headers[header::ETAG].to_str().unwrap().to_owned();
    for job in order["order"]["jobs"].as_array().unwrap() {
        let file = &job["file"];
        let r = b
            .send(b.request(
                Method::GET,
                &format!("{path}/files/{}", file["id"].as_str().unwrap()),
            ))
            .await;
        assert_eq!(r.status(), 200);
        assert!(
            r.headers()[header::CONTENT_DISPOSITION]
                .to_str()
                .unwrap()
                .starts_with("attachment;")
        );
        assert_eq!(r.headers()[header::X_CONTENT_TYPE_OPTIONS], "nosniff");
        let bytes = r.bytes().await.unwrap();
        let digest: String = Sha256::digest(&bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        assert_eq!(digest, file["sha256"].as_str().unwrap());
    }
    let html = b
        .send(b.request(Method::GET, &format!("/orders/{order_id}")))
        .await
        .text()
        .await
        .unwrap();
    assert!(html.contains("Arquivos retirados") && html.contains("Baixar arquivo"));
    ok(&format!(
        "order {}: {} files streamed, sha256 verified, page renders",
        order["order"]["reference"].as_str().unwrap(),
        order["order"]["jobs"].as_array().unwrap().len()
    ));

    let collect = |etag: &str, key: &str| {
        b.command(Method::POST, &format!("{path}/collected"))
            .header(header::IF_MATCH, etag)
            .header("idempotency-key", key)
            .json(&json!({"revision": order["order"]["revision"]}))
    };
    let (status, body, _) = b
        .json(
            b.command(Method::POST, &format!("{path}/collected"))
                .json(&json!({"revision": 1})),
        )
        .await;
    assert_eq!((status, code(&body)), (428, "PRECONDITION_REQUIRED"));
    let k = key();
    let (status, first, headers) = b.json(collect(&etag, &k)).await;
    assert_eq!(
        (status, first["order"]["status"].as_str()),
        (200, Some("files_collected"))
    );
    let etag = headers[header::ETAG].to_str().unwrap().to_owned();
    let (status, replay, headers) = b
        .json(collect(
            &format!("\"{order_id}:{}\"", order["order"]["version"]),
            &k,
        ))
        .await;
    assert_eq!(status, 200);
    assert_eq!(headers["idempotency-replayed"], "true");
    assert_eq!(replay, first);
    let (status, body, _) = b
        .json(collect(
            &format!("\"{order_id}:{}\"", order["order"]["version"]),
            &key(),
        ))
        .await;
    assert_eq!((status, code(&body)), (412, "VERSION_MISMATCH"));
    ok("collected: 428 without preconditions, 200, same key replays, stale ETag 412");

    let quote = b
        .command(Method::POST, &format!("{path}/quotes"))
        .header(header::IF_MATCH, &etag)
        .header("idempotency-key", key())
        .multipart(
            multipart::Form::new()
                .part(
                    "file",
                    multipart::Part::bytes(b"%PDF-1.4\n% orcamento e2e rust\n%%EOF\n".to_vec())
                        .file_name("orçamento.pdf"),
                )
                .text("amountCents", "45900")
                .text("orderRevision", order["order"]["revision"].to_string()),
        );
    let (status, quoted, headers) = b.json(quote).await;
    assert_eq!(
        (status, quoted["order"]["status"].as_str()),
        (201, Some("quote_pending")),
        "{quoted}"
    );
    let etag = headers[header::ETAG].to_str().unwrap().to_owned();
    let quote_id = quoted["order"]["currentQuote"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let printed = |etag: &str| {
        b.command(Method::POST, &format!("{path}/printed"))
            .header(header::IF_MATCH, etag)
            .header("idempotency-key", key())
            .json(&json!({"revision": order["order"]["revision"], "quoteId": quote_id}))
    };
    let (status, body, _) = b.json(printed(&etag)).await;
    assert_eq!((status, code(&body)), (409, "INVALID_STATE"));
    ok("quote: 201 quote_pending; printing before approval 409 INVALID_STATE");

    let out = Command::new(&approve)
        .arg(&order_id)
        .output()
        .expect("approval command runs");
    assert!(out.status.success(), "approval command failed");
    let (_, order_now, headers) = b.json(b.request(Method::GET, &path)).await;
    assert_eq!(order_now["order"]["status"], "quote_approved");
    let etag = headers[header::ETAG].to_str().unwrap().to_owned();
    let (status, body, _) = b.json(printed(&etag)).await;
    assert_eq!(
        (status, body["order"]["status"].as_str()),
        (200, Some("printed"))
    );
    assert_eq!(body["order"]["approvedAmountCents"], 45_900);
    ok("Financeiro approval (real staff route) → printed 200, approvedAmountCents 45900");

    let (status, close, _) = b
        .json(b.request(Method::GET, "/api/print/v1/monthly-closes/2026-09"))
        .await;
    let invoices = b
        .send(b.request(Method::GET, "/invoices?competence=2026-09"))
        .await
        .text()
        .await
        .unwrap();
    if status == 404 {
        assert!(invoices.contains("Notas fiscais ainda indisponíveis"));
        ok("monthly close: upstream 404 → \"Notas fiscais ainda indisponíveis\"");
    } else {
        assert_eq!(status, 200, "{close}");
        assert!(invoices.contains("Total calculado"));
        ok(&format!(
            "monthly close 2026-09: state {}, total {}",
            close["close"]["state"], close["close"]["expectedTotalCents"]
        ));
    }

    assert_eq!(
        b.send(b.command(Method::DELETE, "/api/session"))
            .await
            .status(),
        204
    );
    let (status, _, _) = b.json(b.request(Method::GET, "/api/print/v1/orders")).await;
    assert_eq!(status, 401);
    ok("logout 204; session revoked (401)");
    println!("E2E PASSED");
}

//! The portal over real sockets: browser → BFF → (fake Hono over HTTP | the
//! in-memory fake). Spec §4.5/§5/§7 and the §8 cases that do not need the
//! real Incluir (those run in the tester's shared suite and examples).
use crate::portal_api_conformance::{
    INVOICE_PDF, QUOTE_PDF, TestClock, asset, later, renumbered, seed, sha, snapshot,
};
use crate::portal_browser::{Browser, CapturingLogger, PASSWORD, memory, start_portal};
use crate::portal_fake_hono::{FakeHono, TOKEN};
use frame_observability::Observability;
use frame_portal_domain::{Batch, Competence};
use frame_portal_hono::{PrintApiHono, Timeouts};
use frame_portal_memory::PrintApiMemory;
use frame_portal_port::PrintApi;
use reqwest::{Method, header, multipart};
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};

fn cookie_line(response: &reqwest::Response, name: &str) -> String {
    response
        .headers()
        .get_all(header::SET_COOKIE)
        .iter()
        .map(|v| v.to_str().unwrap().to_owned())
        .find(|v| v.starts_with(&format!("{name}=")))
        .unwrap_or_else(|| panic!("no Set-Cookie for {name}"))
}

fn assert_host_cookie(line: &str) {
    for attr in ["Path=/", "Secure", "HttpOnly", "SameSite=Lax"] {
        assert!(line.contains(attr), "{line} lacks {attr}");
    }
    assert!(
        !line.to_ascii_lowercase().contains("domain="),
        "{line} must be host-only"
    );
}

async fn plain_portal(fake: Arc<PrintApiMemory>, clock: &TestClock) -> frame_portal_web::Server {
    start_portal(fake, clock.as_fn(), Observability::default(), |_| {}).await
}

#[tokio::test]
async fn login_requires_origin_and_csrf_and_rate_limits_the_sixth_invalid_attempt() {
    let clock = TestClock::at(2026, 10, 8);
    let server = plain_portal(memory(&clock), &clock).await;
    let b = Browser::new(&server.base_url);

    let response = b.send(b.request(Method::GET, "/api/session")).await;
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    assert_host_cookie(&cookie_line(&response, frame_portal_web::PRESESSION_COOKIE));
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["authenticated"], false);
    assert_eq!(body["expiresAt"], Value::Null);
    *b.csrf.lock().unwrap() = body["csrfToken"].as_str().unwrap().into();
    let login = |req: reqwest::RequestBuilder| req.json(&json!({ "password": PASSWORD }));

    // Missing / wrong Origin, missing / wrong CSRF: 403 CSRF_FAILED.
    let no_origin = b
        .request(Method::POST, "/api/session")
        .header("x-csrf-token", b.csrf());
    let wrong_origin = b
        .request(Method::POST, "/api/session")
        .header(header::ORIGIN, "http://evil.example")
        .header("x-csrf-token", b.csrf());
    let no_csrf = b
        .request(Method::POST, "/api/session")
        .header(header::ORIGIN, &b.base);
    let wrong_csrf = b
        .request(Method::POST, "/api/session")
        .header(header::ORIGIN, &b.base)
        .header("x-csrf-token", "f".repeat(64));
    for req in [no_origin, wrong_origin, no_csrf, wrong_csrf] {
        let (status, body) = b.json(login(req)).await;
        assert_eq!(
            (status, body["error"]["code"].as_str()),
            (403, Some("CSRF_FAILED"))
        );
    }
    // Malformed bodies: 400, nothing echoed.
    for raw in [
        "\"senha\"",
        "{\"password\":",
        "[1]",
        "{\"password\":\"x\",\"user\":\"a\"}",
        "{\"password\":7}",
    ] {
        let (status, body) = b
            .json(
                b.command(Method::POST, "/api/session")
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(raw),
            )
            .await;
        assert_eq!(
            (status, body["error"]["code"].as_str()),
            (400, Some("INVALID_REQUEST")),
            "{raw}"
        );
        assert!(!body.to_string().contains("senha"));
    }

    for attempt in 1..=5 {
        let (status, body) = b
            .json(
                b.command(Method::POST, "/api/session")
                    .json(&json!({"password": format!("errada-{attempt}")})),
            )
            .await;
        assert_eq!(
            (status, body["error"]["code"].as_str()),
            (401, Some("INVALID_CREDENTIALS"))
        );
        assert!(!body.to_string().contains("errada"));
    }
    // Sixth attempt is limited even with the right password or a forged XFF.
    for req in [
        login(b.command(Method::POST, "/api/session")),
        login(
            b.command(Method::POST, "/api/session")
                .header("x-forwarded-for", "198.51.100.77"),
        ),
    ] {
        let response = b.send(req).await;
        assert_eq!(response.status(), 429);
        let retry: u64 = response.headers()[header::RETRY_AFTER]
            .to_str()
            .unwrap()
            .parse()
            .unwrap();
        assert!((1..=900).contains(&retry));
        let body: Value = response.json().await.unwrap();
        assert_eq!(body["error"]["code"], "RATE_LIMITED");
    }
    clock.advance(chrono::TimeDelta::minutes(16));
    assert_eq!(b.login(PASSWORD).await.0, 200, "window slides");
    server.shutdown().await;
}

#[tokio::test]
async fn trusted_proxy_forwarded_address_is_the_rate_limit_key() {
    let clock = TestClock::at(2026, 10, 8);
    let server = start_portal(
        memory(&clock),
        clock.as_fn(),
        Observability::default(),
        |s| {
            s.trusted_proxies = vec!["127.0.0.1".parse().unwrap()];
        },
    )
    .await;
    let b = Browser::new(&server.base_url);
    b.session().await;
    let attempt = |ip: &str| {
        b.command(Method::POST, "/api/session")
            .header("x-forwarded-for", format!("10.9.9.9, {ip}"))
            .json(&json!({"password": "errada-mas-longa"}))
    };
    for _ in 0..5 {
        assert_eq!(b.json(attempt("203.0.113.1")).await.0, 401);
    }
    assert_eq!(b.json(attempt("203.0.113.1")).await.0, 429);
    assert_eq!(
        b.json(attempt("203.0.113.2")).await.0,
        401,
        "another client behind the proxy"
    );
    server.shutdown().await;
}

#[tokio::test]
async fn login_rotates_the_session_and_logout_revokes_it_immediately() {
    let clock = TestClock::at(2026, 10, 8);
    let server = plain_portal(memory(&clock), &clock).await;
    let b = Browser::new(&server.base_url);
    b.session().await;
    let pre_csrf = b.csrf();
    let pre_id = b.cookie(frame_portal_web::PRESESSION_COOKIE).unwrap();

    let response = b
        .send(
            b.command(Method::POST, "/api/session")
                .json(&json!({ "password": PASSWORD })),
        )
        .await;
    assert_eq!(response.status(), 200);
    assert_host_cookie(&cookie_line(&response, frame_portal_web::SESSION_COOKIE));
    assert!(cookie_line(&response, frame_portal_web::PRESESSION_COOKIE).contains("Max-Age=0"));
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["authenticated"], true);
    assert!(!body.to_string().contains(PASSWORD));
    let session_id = b.cookie(frame_portal_web::SESSION_COOKIE).unwrap();
    assert_ne!(session_id, pre_id);
    assert_eq!(session_id.len(), 64, "256-bit opaque id");
    assert_ne!(body["csrfToken"].as_str().unwrap(), pre_csrf);
    *b.csrf.lock().unwrap() = body["csrfToken"].as_str().unwrap().into();

    // The consumed pre-session cannot log in again.
    let replay = Browser::new(&server.base_url);
    replay
        .cookies
        .lock()
        .unwrap()
        .insert(frame_portal_web::PRESESSION_COOKIE.into(), pre_id);
    *replay.csrf.lock().unwrap() = pre_csrf;
    let (status, _) = replay
        .json(
            replay
                .command(Method::POST, "/api/session")
                .json(&json!({ "password": PASSWORD })),
        )
        .await;
    assert_eq!(status, 403);

    let state = b.session().await;
    assert_eq!(state["authenticated"], true);
    assert!(state["expiresAt"].as_str().unwrap().ends_with('Z'));
    let page = b.send(b.request(Method::GET, "/")).await;
    assert_eq!(page.status(), 200);
    let html = page.text().await.unwrap();
    assert!(html.contains("Lote atual") && html.contains("Notas fiscais") && html.contains("Sair"));

    let (status, body) = b
        .json(
            b.request(Method::DELETE, "/api/session")
                .header(header::ORIGIN, &b.base),
        )
        .await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (403, Some("CSRF_FAILED"))
    );
    let stolen = session_id.clone();
    let response = b.send(b.command(Method::DELETE, "/api/session")).await;
    assert_eq!(response.status(), 204);
    assert!(cookie_line(&response, frame_portal_web::SESSION_COOKIE).contains("Max-Age=0"));
    let thief = Browser::new(&server.base_url);
    thief
        .cookies
        .lock()
        .unwrap()
        .insert(frame_portal_web::SESSION_COOKIE.into(), stolen);
    let (status, body) = thief
        .json(thief.request(Method::GET, "/api/print/v2/batches"))
        .await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (401, Some("UNAUTHENTICATED"))
    );
    assert_eq!(
        b.send(b.command(Method::DELETE, "/api/session"))
            .await
            .status(),
        204
    );
    server.shutdown().await;
}

#[tokio::test]
async fn idle_and_absolute_expiry_and_restart_end_sessions() {
    let clock = TestClock::at(2026, 10, 8);
    let fake = memory(&clock);
    let tune = |s: &mut frame_portal_web::Settings| {
        s.session.idle = chrono::TimeDelta::seconds(60);
        s.session.absolute = chrono::TimeDelta::seconds(150);
    };
    let server = start_portal(fake.clone(), clock.as_fn(), Observability::default(), tune).await;
    let b = Browser::new(&server.base_url);
    assert_eq!(b.login(PASSWORD).await.0, 200);
    let get = || b.request(Method::GET, "/api/print/v2/batches");
    for _ in 0..2 {
        clock.advance(chrono::TimeDelta::seconds(59));
        assert_eq!(b.json(get()).await.0, 200);
    }
    clock.advance(chrono::TimeDelta::seconds(59)); // 177 s > absolute 150 s
    assert_eq!(b.json(get()).await.0, 401);
    assert_eq!(b.login(PASSWORD).await.0, 200);
    clock.advance(chrono::TimeDelta::seconds(61));
    assert_eq!(b.json(get()).await.0, 401, "idle");

    // Restart: a new process has an empty registry; upstream data persists.
    assert_eq!(b.login(PASSWORD).await.0, 200);
    let id = seed(&fake, &snapshot("open"));
    server.shutdown().await;
    let restarted = start_portal(fake.clone(), clock.as_fn(), Observability::default(), tune).await;
    let again = Browser::new(&restarted.base_url);
    *again.cookies.lock().unwrap() = b.cookies.lock().unwrap().clone();
    assert_eq!(
        again
            .json(again.request(Method::GET, "/api/print/v2/batches"))
            .await
            .0,
        401
    );
    assert_eq!(again.login(PASSWORD).await.0, 200);
    let (status, body) = again
        .json(again.request(Method::GET, &format!("/api/print/v2/batches/{id}")))
        .await;
    assert_eq!(
        (status, body["batch"]["id"].as_str()),
        (200, Some(id.as_str()))
    );
    restarted.shutdown().await;
}

#[tokio::test]
async fn pages_redirect_without_session_and_json_answers_401() {
    let clock = TestClock::at(2026, 10, 8);
    let server = plain_portal(memory(&clock), &clock).await;
    let b = Browser::new(&server.base_url);
    let id = uuid::Uuid::new_v4().to_string();
    for (path, next) in [
        ("/batches", "%2Fbatches"),
        ("/invoices", "%2Finvoices"),
        (&*format!("/batches/{id}"), &*format!("%2Fbatches%2F{id}")),
    ] {
        let response = b.send(b.request(Method::GET, path)).await;
        assert_eq!(response.status(), 303, "{path}");
        assert_eq!(
            response.headers()[header::LOCATION],
            format!("/login?next={next}")
        );
    }
    assert_eq!(
        b.send(b.request(Method::GET, "/")).await.headers()[header::LOCATION],
        "/login"
    );
    for path in [
        "/api/print/v2/batches",
        &format!("/api/print/v2/batches/{id}"),
        "/api/print/v2/monthly-closes/2026-09",
    ] {
        let (status, body) = b.json(b.request(Method::GET, path)).await;
        assert_eq!(
            (status, body["error"]["code"].as_str()),
            (401, Some("UNAUTHENTICATED")),
            "{path}"
        );
        assert!(
            body["error"]["requestId"]
                .as_str()
                .is_some_and(|r| !r.is_empty())
        );
    }
    // External return targets are dropped.
    let login = b
        .send(b.request(Method::GET, "/login?next=https://evil.example/x"))
        .await;
    let headers = login.headers().clone();
    let html = login.text().await.unwrap();
    assert!(html.contains("data-next=\"/\"") && !html.contains("evil"));
    assert!(html.contains(">Entrar<") && html.contains("Senha"));
    let csp = headers[header::CONTENT_SECURITY_POLICY].to_str().unwrap();
    assert!(csp.contains("script-src 'self'") && csp.contains("frame-ancestors 'none'"));
    assert_eq!(headers[header::X_CONTENT_TYPE_OPTIONS], "nosniff");
    assert_eq!(
        b.send(b.request(Method::GET, "/healthz")).await.status(),
        200
    );
    let unknown = b.send(b.request(Method::GET, "/nao-existe")).await;
    assert_eq!(unknown.status(), 404);
    server.shutdown().await;
}

/// Through the full stack: browser → BFF → real HTTP adapter → fake Hono.
struct Stack {
    clock: TestClock,
    fake: Arc<PrintApiMemory>,
    upstream: FakeHono,
    server: frame_portal_web::Server,
    browser: Browser,
}

async fn stack(observability: Observability, timeouts: Timeouts) -> Stack {
    let clock = TestClock::at(2026, 9, 10);
    let fake = memory(&clock);
    let upstream = FakeHono::start(fake.clone()).await;
    let adapter: Arc<dyn PrintApi> =
        Arc::new(PrintApiHono::new(&upstream.origin, TOKEN, timeouts).unwrap());
    let server = start_portal(adapter, clock.as_fn(), observability, |_| {}).await;
    let browser = Browser::new(&server.base_url);
    assert_eq!(browser.login(PASSWORD).await.0, 200);
    Stack {
        clock,
        fake,
        upstream,
        server,
        browser,
    }
}

fn quote_form(amount: &str, bytes: &[u8]) -> multipart::Form {
    multipart::Form::new()
        .part(
            "file",
            multipart::Part::bytes(bytes.to_vec()).file_name("orcamento.pdf"),
        )
        .text("amountCents", amount.to_owned())
}

/// Runs the shared TTP staging smoke (`infra/ttp/staging.py`, the exact
/// checker staging uses: real JSON login, `data-ttp` markers of `/`, real
/// downloads with length/SHA-256/MIME) against `origin`.
async fn shared_smoke(origin: &str, scenario: &str, checkpoint: &str) -> Value {
    let revision: Value = reqwest::get(format!("{origin}/version"))
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let ctx = json!({
        "variant": "rust",
        "source_sha": revision["revision"],
        "smoke_config": {
            "mode": "task1-v2", "trial_id": "rust-portal-web-test", "scenario": scenario,
            "checkpoint": checkpoint, "fake_sha": "74e677c764a0dc11d3ec6ce61e62f10df417a2c2",
            "freeze_sha": "270224676d61431c2d26a8e20ec911c328a1f5f3",
            "bundle_sha256": "550698df3fa1e2e42a710ec6ca5d995ed1c5fe9d3a32c520c1f0c11c6430c85e",
            "boot_id": "00000000-0000-4000-8000-000000000099", "generation": 1,
            "seed_sha256": "b".repeat(64), "admin_manifest_sha256": "c".repeat(64),
        },
    });
    // Staging is HTTPS: let the jar send the `Secure` session cookies over
    // this loopback http socket (the cookie flags are asserted elsewhere).
    let script = "import http.cookiejar, json, sys\n\
        http.cookiejar.DefaultCookiePolicy.return_ok_secure = lambda *_: True\n\
        import staging\n\
        ctx, origin, password = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]\n\
        result = {}\n\
        try:\n    staging.portal_smoke(ctx, origin, password, result)\n\
        finally:\n    print(json.dumps(result))\n";
    let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../infra/ttp");
    let origin = origin.to_owned();
    let output = tokio::task::spawn_blocking(move || {
        std::process::Command::new("python3")
            .args(["-c", script, &ctx.to_string(), &origin, PASSWORD])
            .current_dir(dir)
            .env("PYTHONPATH", dir)
            .output()
            .expect("python3 runs the shared smoke")
    })
    .await
    .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let result: Value = serde_json::from_str(stdout.trim()).unwrap_or(Value::Null);
    assert!(
        output.status.success() && result["status"] == "success",
        "shared smoke {scenario}/{checkpoint} failed: {result} {}",
        String::from_utf8_lossy(&output.stderr)
    );
    result
}

/// Full stack (browser → BFF → HTTP adapter → fake Hono) seeded with
/// `batches`, in order.
async fn seeded_stack(batches: &[Batch]) -> Stack {
    let s = stack(Observability::default(), Timeouts::default()).await;
    for batch in batches {
        seed(&s.fake, batch);
    }
    s
}

#[tokio::test]
async fn home_passes_the_shared_smoke_for_every_frozen_checkpoint() {
    // Flow snapshots: open is served by /batches/open; the active ones only
    // through the history (the upstream hides open meanwhile).
    for (status, checkpoint) in [
        ("open", "open"),
        ("files_collected", "collected"),
        ("quote_pending", "quote-pending"),
        ("quote_rejected", "quote-rejected"),
        ("quote_approved", "quote-approved"),
        ("printed", "printed"),
    ] {
        let s = seeded_stack(&[snapshot(status)]).await;
        let result = shared_smoke(&s.server.base_url, "flow", checkpoint).await;
        assert_eq!(result["feature"]["batch_status"], status);
        assert_eq!(result["feature"]["downloads"].as_array().unwrap().len(), 3);
        s.server.shutdown().await;
    }
    // After receipt the next batch; after cancellation the re-batched one
    // with the backend's `previouslyCancelledIn`.
    let s = seeded_stack(&[snapshot("received"), later("nextBatch")]).await;
    shared_smoke(&s.server.base_url, "flow", "next-batch").await;
    s.server.shutdown().await;
    let s = seeded_stack(&[snapshot("cancelled"), later("rebatchedBatch")]).await;
    let result = shared_smoke(&s.server.base_url, "cancel", "rebatched").await;
    assert_eq!(result["feature"]["downloads"].as_array().unwrap().len(), 4);
    let html = s
        .browser
        .send(s.browser.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(html.contains("Este item já esteve no lote <strong>LOT-0001</strong>, cancelado"));
    s.server.shutdown().await;
    // Nothing current: empty history, or only finished batches.
    for history in [
        vec![],
        vec![snapshot("received")],
        vec![snapshot("cancelled")],
    ] {
        let s = seeded_stack(&history).await;
        shared_smoke(&s.server.base_url, "empty-history", "empty").await;
        s.server.shutdown().await;
    }
}

#[tokio::test]
async fn home_cards_follow_contract_order_and_keep_residual_instructions_apart() {
    let open = snapshot("open");
    let s = seeded_stack(std::slice::from_ref(&open)).await;
    let b = &s.browser;
    let html = b
        .send(b.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    let item = &open.items[0];
    // Header: reference, status, item count, total copies, progress bar.
    assert!(html.contains("LOT-0001") && html.contains("Pronto"));
    assert!(
        html.contains("<dt>Itens</dt><dd>1</dd>") && html.contains("<dt>Cópias</dt><dd>36</dd>")
    );
    let steps = [
        "Pronto",
        "Arquivos retirados",
        "Orçamento enviado",
        "Orçamento aprovado",
        "Impresso",
    ];
    let mut at = html.find("class=\"progress\"").expect("progress bar");
    for step in steps {
        at += html[at..].find(&format!(">{step}</li>")).expect(step);
    }
    // One card per file, in contract order: jobs, then the residual file.
    let mut at = 0;
    for file in item.files() {
        at += html[at..]
            .find(&format!("data-file-id=\"{}\"", file.id))
            .unwrap_or_else(|| panic!("card {}", file.name));
        assert_eq!(
            html.matches(&format!("data-file-id=\"{}\"", file.id))
                .count(),
            1
        );
    }
    assert_eq!(html.matches("data-ttp=\"download\"").count(), 3);
    assert!(html.contains("Não identificadas") && html.contains("Sem vínculo seguro"));
    // The residual text is its own block inside its own request only.
    assert_eq!(html.matches("data-ttp=\"general-instructions\"").count(), 1);
    assert!(html.contains("Instruções gerais"));
    assert_eq!(
        html.matches("data-ttp=\"copies\"").count(),
        2,
        "no invented copies"
    );
    // Hostile upstream text is escaped, never markup.
    let mut hostile = renumbered(&snapshot("open"), "LOT-0042");
    hostile.items[0].title = "<script>alert(1)</script>".into();
    hostile.items[0].jobs[0].instructions = "Instrução <img src=x onerror=alert(1)>".into();
    hostile.items[0].general_instructions.as_mut().unwrap().text = "<b>geral</b>".into();
    let other = seeded_stack(&[hostile]).await;
    let html = other
        .browser
        .send(other.browser.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(!html.contains("<script>alert(1)</script>") && html.contains("&lt;script&gt;"));
    assert!(!html.contains("<img src=x") && html.contains("&lt;b&gt;geral&lt;/b&gt;"));
    assert!(!html.contains(TOKEN));
    other.server.shutdown().await;
    let mut files_only = renumbered(&snapshot("open"), "LOT-0043");
    files_only.items[0]
        .general_instructions
        .as_mut()
        .unwrap()
        .text = String::new();
    let other = seeded_stack(&[files_only]).await;
    let html = other
        .browser
        .send(other.browser.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(html.contains("<p class=\"instructions\" data-ttp=\"general-instructions\"></p>"));
    assert!(html.contains("Sem texto adicional.") && html.contains("Não identificadas"));
    other.server.shutdown().await;
    s.server.shutdown().await;
}

fn etag_of(response: &reqwest::Response) -> String {
    response.headers()[header::ETAG]
        .to_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn print_shop_journey_from_open_batch_to_printed_and_invoice() {
    let open = snapshot("open");
    let s = seeded_stack(std::slice::from_ref(&open)).await;
    let b = &s.browser;
    let id = open.id.clone();
    let batch_path = format!("/api/print/v2/batches/{id}");

    // Only the collect action, behind a required "Conferi" checkbox + confirmation.
    let html = b
        .send(b.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(html.contains("<input type=\"checkbox\" name=\"checked\" required>"));
    assert!(html.contains("Conferi todos os arquivos") && html.contains("Retirei os arquivos"));
    assert!(html.contains("Confirma que retirou os 3 arquivos deste lote (1 solicitação)?"));
    assert!(html.contains(&format!("data-etag=\"&quot;{id}:1&quot;\"")));
    for absent in ["upload-quote", "mark-printed", "status-message"] {
        assert!(!html.contains(absent), "{absent} not rendered while open");
    }

    // JSON detail mirrors the upstream DTO and ETag; downloads are exact bytes.
    let response = b.send(b.request(Method::GET, &batch_path)).await;
    let etag1 = etag_of(&response);
    assert_eq!(etag1, format!("\"{id}:1\""));
    let body: Value = response.json().await.unwrap();
    assert_eq!(body["batch"], serde_json::to_value(&open).unwrap());
    let item = &open.items[0];
    for file in item.files() {
        let response = b
            .send(b.request(
                Method::GET,
                &format!("{batch_path}/orders/{}/files/{}", item.order_id, file.id),
            ))
            .await;
        assert_eq!(response.status(), 200);
        let h = response.headers().clone();
        assert!(
            h[header::CONTENT_DISPOSITION]
                .to_str()
                .unwrap()
                .starts_with("attachment; filename=")
        );
        assert_eq!(h[header::CONTENT_TYPE], "application/pdf");
        assert_eq!(h[header::X_CONTENT_TYPE_OPTIONS], "nosniff");
        assert_eq!(h[header::CACHE_CONTROL], "private, no-store");
        assert!(
            h[header::CONTENT_SECURITY_POLICY]
                .to_str()
                .unwrap()
                .contains("sandbox")
        );
        let bytes = response.bytes().await.unwrap();
        assert_eq!(&bytes[..], asset(&file.id));
        assert_eq!(sha(&bytes), file.sha256);
    }
    for bad in [
        format!(
            "{batch_path}/orders/{}/files/{}",
            item.order_id,
            uuid::Uuid::new_v4()
        ),
        format!("{batch_path}/orders/..%2F..%2Fetc/files/x"),
    ] {
        assert_eq!(b.json(b.request(Method::GET, &bad)).await.0, 404, "{bad}");
    }
    let (status, list) = b
        .json(b.request(Method::GET, "/api/print/v2/batches?limit=1"))
        .await;
    assert_eq!(
        (status, list["items"][0]["reference"].as_str()),
        (200, Some("LOT-0001"))
    );
    for bad in ["?limit=0", "?limit=101", "?limit=01", "?status=ready"] {
        let (status, body) = b
            .json(b.request(Method::GET, &format!("/api/print/v2/batches{bad}")))
            .await;
        assert_eq!(
            (status, body["error"]["code"].as_str()),
            (400, Some("INVALID_REQUEST")),
            "{bad}"
        );
    }

    // Collect: CSRF first, then 428, body discipline, 412 for a stale ETag.
    let collected = format!("{batch_path}/collected");
    let collect = |etag: &str, key: &str| {
        b.command(Method::POST, &collected)
            .header(header::IF_MATCH, etag)
            .header("idempotency-key", key)
            .json(&json!({}))
    };
    let (status, _) = b
        .json(
            b.request(Method::POST, &collected)
                .header(header::ORIGIN, &b.base)
                .json(&json!({})),
        )
        .await;
    assert_eq!(status, 403);
    let (status, body) = b
        .json(b.command(Method::POST, &collected).json(&json!({})))
        .await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (428, Some("PRECONDITION_REQUIRED"))
    );
    for raw in ["1", "{\"revision\":1}", "[]", "{"] {
        let (status, _) = b
            .json(
                b.command(Method::POST, &collected)
                    .header(header::CONTENT_TYPE, "application/json")
                    .header(header::IF_MATCH, &etag1)
                    .header("idempotency-key", uuid::Uuid::new_v4().to_string())
                    .body(raw),
            )
            .await;
        assert_eq!(status, 400, "{raw}");
    }
    let (status, body) = b
        .json(collect(
            &format!("\"{id}:0\""),
            &uuid::Uuid::new_v4().to_string(),
        ))
        .await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (412, Some("VERSION_MISMATCH"))
    );
    let key = uuid::Uuid::new_v4().to_string();
    let response = b.send(collect(&etag1, &key)).await;
    assert_eq!(response.status(), 200);
    let etag2 = etag_of(&response);
    assert!(response.headers().get("idempotency-replayed").is_none());
    let first: Value = response.json().await.unwrap();
    assert_eq!(first["batch"]["status"], "files_collected");
    let replay = b.send(collect(&etag1, &key)).await;
    assert_eq!(replay.headers()["idempotency-replayed"], "true");
    assert_eq!(replay.json::<Value>().await.unwrap(), first);
    let (status, body) = b
        .json(collect(&etag1, &uuid::Uuid::new_v4().to_string()))
        .await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (412, Some("VERSION_MISMATCH"))
    );

    // The home now offers only the batch quote upload.
    let html = b
        .send(b.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(html.contains("data-action=\"upload-quote\"") && html.contains("Enviar orçamento"));
    assert!(html.contains("Valor total do lote (R$)") && !html.contains("Retirei os arquivos"));

    // Quote upload: field discipline and limits before the upstream.
    let quotes = format!("{batch_path}/quotes");
    let send_quote = |form: multipart::Form, key: String| {
        b.command(Method::POST, &quotes)
            .header(header::IF_MATCH, &etag2)
            .header("idempotency-key", key)
            .multipart(form)
    };
    let extra = quote_form("45900", QUOTE_PDF).text("supplierId", "x");
    let repeated = quote_form("45900", QUOTE_PDF).text("amountCents", "1");
    let revision = quote_form("45900", QUOTE_PDF).text("orderRevision", "1");
    let missing = multipart::Form::new().part(
        "file",
        multipart::Part::bytes(QUOTE_PDF.to_vec()).file_name("o.pdf"),
    );
    let not_canonical = quote_form("459.00", QUOTE_PDF);
    let empty = quote_form("45900", b"");
    for form in [extra, repeated, revision, missing, not_canonical, empty] {
        let (status, body) = b
            .json(send_quote(form, uuid::Uuid::new_v4().to_string()))
            .await;
        assert_eq!(
            (status, body["error"]["code"].as_str()),
            (400, Some("INVALID_REQUEST"))
        );
    }
    let mut big = b"%PDF-1.4\n".to_vec();
    big.resize(5 * 1024 * 1024 + 1, b'a');
    let (status, body) = b
        .json(send_quote(
            quote_form("45900", &big),
            uuid::Uuid::new_v4().to_string(),
        ))
        .await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (413, Some("FILE_TOO_LARGE"))
    );
    big.resize(7 * 1024 * 1024, b'a');
    let response = b
        .send(send_quote(
            quote_form("45900", &big),
            uuid::Uuid::new_v4().to_string(),
        ))
        .await;
    assert_eq!(response.status(), 413, "body cap applies before buffering");
    for disallowed in [
        &b"<svg onload=alert(1)>"[..],
        b"GIF89a....",
        b"PK\x03\x04docx",
    ] {
        let (status, body) = b
            .json(send_quote(
                quote_form("45900", disallowed),
                uuid::Uuid::new_v4().to_string(),
            ))
            .await;
        assert_eq!(
            (status, body["error"]["code"].as_str()),
            (415, Some("UNSUPPORTED_MEDIA_TYPE"))
        );
        assert_eq!(body["error"]["message"], "Envie um PDF, JPEG, PNG ou WebP.");
    }

    // A 503 leaves nothing applied; the same intent retried with the same
    // Idempotency-Key applies once, and a further retry is a replay.
    let intent = uuid::Uuid::new_v4().to_string();
    s.fake.set_unavailable(true);
    let (status, body) = b
        .json(send_quote(quote_form("45900", QUOTE_PDF), intent.clone()))
        .await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (503, Some("UPSTREAM_UNAVAILABLE"))
    );
    s.fake.set_unavailable(false);
    let response = b
        .send(send_quote(quote_form("45900", QUOTE_PDF), intent.clone()))
        .await;
    assert_eq!(response.status(), 201);
    let quoted: Value = response.json().await.unwrap();
    assert_eq!(quoted["batch"]["status"], "quote_pending");
    let replay = b
        .send(send_quote(quote_form("45900", QUOTE_PDF), intent.clone()))
        .await;
    assert_eq!(
        (
            replay.status().as_u16(),
            replay.headers()["idempotency-replayed"].to_str().unwrap()
        ),
        (201, "true")
    );
    assert_eq!(
        replay.json::<Value>().await.unwrap(),
        quoted,
        "no duplicate quote"
    );
    let current = s.fake.get_batch(&id).await.unwrap().body;
    assert_eq!(current.current_quote.as_ref().unwrap().revision, 1);
    let quote_id = quoted["batch"]["currentQuote"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let doc = b
        .send(b.request(Method::GET, &format!("{batch_path}/quotes/{quote_id}/file")))
        .await;
    assert_eq!(&doc.bytes().await.unwrap()[..], QUOTE_PDF);
    let html = b
        .send(b.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(
        html.contains("Aguardando aprovação do Financeiro")
            && !html.contains("data-ttp=\"action\"")
    );
    assert!(!html.contains("Aprovar") && !html.contains("Rejeitar"));

    // Rejected: the reason is shown and a new quote can be sent.
    s.fake
        .decide_quote(&id, false, Some("Corrigir quantidade total"))
        .unwrap();
    let html = b
        .send(b.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(html.contains("Orçamento rejeitado.") && html.contains("Corrigir quantidade total"));
    assert!(html.contains("data-action=\"upload-quote\""));
    let response = b.send(b.request(Method::GET, &batch_path)).await;
    let etag = etag_of(&response);
    let (status, _) = b
        .json(
            b.command(Method::POST, &quotes)
                .header(header::IF_MATCH, &etag)
                .header("idempotency-key", uuid::Uuid::new_v4().to_string())
                .multipart(quote_form("45900", QUOTE_PDF)),
        )
        .await;
    assert_eq!(status, 201);

    // Approved: only "Marcar como impresso", with confirmation.
    s.fake.decide_quote(&id, true, None).unwrap();
    let response = b.send(b.request(Method::GET, &batch_path)).await;
    let etag = etag_of(&response);
    let approved: Value = response.json().await.unwrap();
    let quote_id = approved["batch"]["currentQuote"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let html = b
        .send(b.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(html.contains("Marcar como impresso") && html.contains("Confirmar impressão"));
    assert!(!html.contains("upload-quote") && !html.contains("data-action=\"collect\""));
    let printed = |etag: &str, body: Value| {
        b.command(Method::POST, &format!("{batch_path}/printed"))
            .header(header::IF_MATCH, etag)
            .header("idempotency-key", uuid::Uuid::new_v4().to_string())
            .json(&body)
    };
    assert_eq!(b.json(printed(&etag, json!({"quoteId": "x"}))).await.0, 400);
    assert_eq!(
        b.json(printed(&etag, json!({"quoteId": quote_id, "revision": 1})))
            .await
            .0,
        400
    );
    let (status, body) = b.json(printed(&etag, json!({"quoteId": quote_id}))).await;
    assert_eq!(
        (status, body["batch"]["status"].as_str()),
        (200, Some("printed"))
    );
    assert_eq!(body["batch"]["approvedAmountCents"], 45_900);
    let html = b
        .send(b.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(html.contains("Aguardando recebimento") && !html.contains("data-ttp=\"action\""));

    // Receipt (Financeiro) ends it: empty home, the batch is in history.
    s.fake.receive(&id).unwrap();
    let html = b
        .send(b.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(html.contains("Nenhum pedido aguardando") && !html.contains("data-ttp=\"batch\""));
    let history = b
        .send(b.request(Method::GET, "/batches"))
        .await
        .text()
        .await
        .unwrap();
    assert!(
        history.contains("Lotes anteriores")
            && history.contains(&format!("href=\"/batches/{id}\""))
    );
    assert!(
        history.contains("LOT-0001")
            && history.contains("Recebido")
            && history.contains("R$ 459,00")
    );
    let detail = b
        .send(b.request(Method::GET, &format!("/batches/{id}")))
        .await;
    assert_eq!(detail.status(), 200);
    let detail = detail.text().await.unwrap();
    assert_eq!(detail.matches("data-ttp=\"file\"").count(), 3, "same cards");
    assert!(detail.contains("Baixar arquivo") && detail.contains("Recebido em"));
    assert!(
        !detail.contains("data-ttp=\"action\"") && !detail.contains("id=\"actions\""),
        "read-only"
    );

    // Monthly close (v2): the whole batch quote once; NF after month end.
    let month = Competence::containing(s.clock.now());
    let close_path = format!("/api/print/v2/monthly-closes/{month}");
    let response = b.send(b.request(Method::GET, &close_path)).await;
    let close_etag = etag_of(&response);
    let close: Value = response.json().await.unwrap();
    assert_eq!(close["close"]["expectedTotalCents"], 45_900);
    assert_eq!(close["close"]["items"][0]["kind"], "batch");
    let invoice = |etag: &str| {
        b.command(Method::POST, &format!("{close_path}/invoice"))
            .header(header::IF_MATCH, etag)
            .header("idempotency-key", uuid::Uuid::new_v4().to_string())
            .multipart(
                multipart::Form::new()
                    .part(
                        "file",
                        multipart::Part::bytes(INVOICE_PDF.to_vec()).file_name("NF.pdf"),
                    )
                    .text("declaredTotalCents", "45900"),
            )
    };
    let (status, body) = b.json(invoice(&close_etag)).await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (409, Some("PERIOD_OPEN"))
    );
    let page = b
        .send(b.request(Method::GET, &format!("/invoices?competence={month}")))
        .await
        .text()
        .await
        .unwrap();
    assert!(page.contains("Total calculado") && page.contains("R$ 459,00"));
    assert!(page.contains(&format!("href=\"/batches/{id}\"")) && page.contains("Lote ou pedido"));
    assert!(page.contains("Competência em andamento") && !page.contains("Enviar NF"));
    s.clock.set(month.ends_at() + chrono::TimeDelta::days(1));
    let (status, _) = b
        .json(b.request(Method::GET, "/api/print/v2/batches"))
        .await;
    assert_eq!(status, 401, "weeks later the session is long expired");
    assert_eq!(b.login(PASSWORD).await.0, 200);
    let page = b
        .send(b.request(Method::GET, &format!("/invoices?competence={month}")))
        .await
        .text()
        .await
        .unwrap();
    assert!(page.contains("Enviar NF") && page.contains("Valor total da NF"));
    let (status, body) = b.json(invoice(&close_etag)).await;
    assert_eq!(
        (status, body["close"]["state"].as_str()),
        (201, Some("submitted"))
    );
    let nf = b
        .send(b.request(Method::GET, &format!("{close_path}/invoice")))
        .await;
    assert_eq!(&nf.bytes().await.unwrap()[..], INVOICE_PDF);
    let (status, body) = b
        .json(b.request(Method::GET, "/api/print/v2/monthly-closes/2026-13"))
        .await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (400, Some("INVALID_COMPETENCE"))
    );

    // Not a proxy for arbitrary paths/methods.
    let (status, body) = b.json(b.request(Method::GET, "/api/print/v2/admin")).await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (404, Some("NOT_FOUND"))
    );
    let (status, body) = b.json(b.command(Method::DELETE, &batch_path)).await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (405, Some("METHOD_NOT_ALLOWED"))
    );
    s.server.shutdown().await;
}

#[tokio::test]
async fn a_stale_collect_is_refused_and_recoverable_after_reload() {
    // The page was loaded at version 1; membership changed upstream since.
    let mut grown = snapshot("open");
    grown.version = 2;
    let id = grown.id.clone();
    let s = seeded_stack(&[grown]).await;
    let b = &s.browser;
    let collect = |etag: String| {
        b.command(
            Method::POST,
            &format!("/api/print/v2/batches/{id}/collected"),
        )
        .header(header::IF_MATCH, etag)
        .header("idempotency-key", uuid::Uuid::new_v4().to_string())
        .json(&json!({}))
    };
    let (status, body) = b.json(collect(format!("\"{id}:1\""))).await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (412, Some("VERSION_MISMATCH"))
    );
    let script = b
        .send(b.request(Method::GET, "/assets/portal.js"))
        .await
        .text()
        .await
        .unwrap();
    assert!(script.contains("O lote mudou desde que esta página foi aberta. Atualize, confira os arquivos e confirme novamente."));
    assert!(script.contains("Marque “Conferi todos os arquivos” antes de confirmar."));
    // Reload: the page carries the new ETag and the checkbox must be ticked again.
    let reloaded = b
        .send(b.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(reloaded.contains(&format!("data-etag=\"&quot;{id}:2&quot;\"")));
    assert!(reloaded.contains("<input type=\"checkbox\" name=\"checked\" required>"));
    let (status, body) = b.json(collect(format!("\"{id}:2\""))).await;
    assert_eq!(
        (status, body["batch"]["status"].as_str()),
        (200, Some("files_collected"))
    );
    s.server.shutdown().await;
}

#[tokio::test]
async fn the_script_keeps_one_idempotency_key_per_intent_and_checks_quote_types() {
    let s = seeded_stack(&[]).await;
    let b = &s.browser;
    let script = b
        .send(b.request(Method::GET, "/assets/portal.js"))
        .await
        .text()
        .await
        .unwrap();
    // Key stored per (batch, action, ETag, fingerprint); reused on retry, dropped on success/412.
    assert!(script.contains("const scope = box.dataset.batchId"));
    assert!(
        script.contains("prior.etag === box.dataset.etag && prior.fingerprint === fingerprint")
    );
    assert!(
        script.contains("'Idempotency-Key': key")
            && script.contains("'If-Match': box.dataset.etag")
    );
    assert!(
        script.contains("data-retry")
            && script.contains("Tipo de arquivo não aceito. Envie PDF, JPEG, PNG ou WebP.")
    );
    for url in ["'/collected'", "'/quotes'", "'/printed'"] {
        assert!(script.contains(url), "{url}");
    }
    s.server.shutdown().await;
}

#[tokio::test]
async fn old_per_order_screens_and_routes_are_gone() {
    let s = seeded_stack(&[snapshot("open")]).await;
    let b = &s.browser;
    let id = uuid::Uuid::new_v4();
    for path in ["/orders".to_owned(), format!("/orders/{id}")] {
        assert_eq!(
            b.send(b.request(Method::GET, &path)).await.status(),
            404,
            "{path}"
        );
    }
    for path in [
        "/api/print/v1/orders".to_owned(),
        format!("/api/print/v1/orders/{id}"),
    ] {
        assert_eq!(b.json(b.request(Method::GET, &path)).await.0, 404, "{path}");
    }
    let html = b
        .send(b.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    assert!(!html.contains("href=\"/orders") && !html.contains("Ver pedido"));
    assert!(html.contains("href=\"/batches\"") && html.contains("Lotes anteriores"));
    s.server.shutdown().await;
}

#[tokio::test]
async fn two_sessions_racing_on_one_etag_apply_exactly_once() {
    let s = stack(Observability::default(), Timeouts::default()).await;
    let other = Browser::new(&s.server.base_url);
    assert_eq!(other.login(PASSWORD).await.0, 200);
    let p1 = seed(&s.fake, &snapshot("open"));
    let etag = format!("\"{p1}:1\"");
    let send = |b: &Browser| {
        b.command(
            Method::POST,
            &format!("/api/print/v2/batches/{p1}/collected"),
        )
        .header(header::IF_MATCH, &etag)
        .header("idempotency-key", uuid::Uuid::new_v4().to_string())
        .json(&json!({}))
        .send()
    };
    let (a, c) = tokio::join!(send(&s.browser), send(&other));
    let mut statuses = [a.unwrap().status().as_u16(), c.unwrap().status().as_u16()];
    statuses.sort();
    assert_eq!(statuses, [200, 412]);
    let (_, batch) = s
        .browser
        .json(
            s.browser
                .request(Method::GET, &format!("/api/print/v2/batches/{p1}")),
        )
        .await;
    assert_eq!(batch["batch"]["version"], 2);
    s.server.shutdown().await;
}

#[tokio::test]
async fn upstream_credential_redirect_timeout_and_outage_are_503_not_a_new_login() {
    let s = stack(
        Observability::default(),
        Timeouts {
            json: Duration::from_millis(300),
            ..Timeouts::default()
        },
    )
    .await;
    let b = &s.browser;
    let id = seed(&s.fake, &snapshot("open"));
    let check = |mode: u8, delay: u64| {
        s.upstream.set_mode(mode);
        s.upstream.set_delay_ms(delay);
    };
    for (mode, delay) in [(3, 0), (1, 0), (2, 0), (0, 1_000)] {
        check(mode, delay);
        let (status, body) = b
            .json(b.request(Method::GET, "/api/print/v2/batches"))
            .await;
        assert_eq!(
            (status, body["error"]["code"].as_str()),
            (503, Some("UPSTREAM_UNAVAILABLE")),
            "mode {mode}"
        );
        assert!(!body.to_string().contains(TOKEN));
        let (status, body) = b
            .json(
                b.command(
                    Method::POST,
                    &format!("/api/print/v2/batches/{id}/collected"),
                )
                .header(header::IF_MATCH, format!("\"{id}:1\""))
                .header("idempotency-key", uuid::Uuid::new_v4().to_string())
                .json(&json!({})),
            )
            .await;
        assert_eq!(
            (status, body["error"]["code"].as_str()),
            (503, Some("UPSTREAM_UNAVAILABLE"))
        );
        let page = b.send(b.request(Method::GET, "/")).await;
        assert_eq!(page.status(), 503);
        let html = page.text().await.unwrap();
        assert!(html.contains("Consultar novamente") && !html.contains("Senha"));
        assert_eq!(
            b.session().await["authenticated"],
            true,
            "session survives upstream failures"
        );
        let ready = b.send(b.request(Method::GET, "/readyz")).await;
        assert_eq!(ready.status(), 503);
        assert!(!ready.text().await.unwrap().contains(TOKEN));
    }
    check(0, 0);
    assert_eq!(
        b.send(b.request(Method::GET, "/readyz")).await.status(),
        200
    );
    // The timed-out command never ran, so the same intent can now be applied once.
    let (_, batch) = b
        .json(b.request(Method::GET, &format!("/api/print/v2/batches/{id}")))
        .await;
    assert_eq!(batch["batch"]["status"], "open");
    s.server.shutdown().await;
}

#[tokio::test]
async fn invoices_page_reports_unavailable_close_api_without_failing() {
    // PR B Hono has no monthly-close routes: its 404 is a product state.
    let clock = TestClock::at(2026, 10, 8);
    let server = plain_portal(memory(&clock), &clock).await;
    let b = Browser::new(&server.base_url);
    b.login(PASSWORD).await;
    let html = b
        .send(b.request(Method::GET, "/invoices"))
        .await
        .text()
        .await
        .unwrap();
    assert!(html.contains("Competência") && html.contains("setembro de 2026"));
    server.shutdown().await;

    struct NoCloses(PrintApiMemory);
    #[async_trait::async_trait]
    impl PrintApi for NoCloses {
        async fn list_batches(
            &self,
            q: &frame_portal_port::ListQuery,
        ) -> frame_portal_port::ApiResult<frame_portal_domain::BatchList> {
            self.0.list_batches(q).await
        }
        async fn open_batch(
            &self,
        ) -> frame_portal_port::ApiResult<Option<frame_portal_port::Tagged<Batch>>> {
            self.0.open_batch().await
        }
        async fn get_batch(
            &self,
            id: &str,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Tagged<Batch>> {
            self.0.get_batch(id).await
        }
        async fn batch_file(
            &self,
            b: &str,
            o: &str,
            f: &str,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Download> {
            self.0.batch_file(b, o, f).await
        }
        async fn collect(
            &self,
            b: &str,
            p: &frame_portal_port::Preconditions,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Command<Batch>> {
            self.0.collect(b, p).await
        }
        async fn submit_quote(
            &self,
            b: &str,
            a: i64,
            f: frame_portal_port::Upload,
            p: &frame_portal_port::Preconditions,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Command<Batch>> {
            self.0.submit_quote(b, a, f, p).await
        }
        async fn quote_file(
            &self,
            b: &str,
            q: &str,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Download> {
            self.0.quote_file(b, q).await
        }
        async fn mark_printed(
            &self,
            b: &str,
            q: &str,
            p: &frame_portal_port::Preconditions,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Command<Batch>> {
            self.0.mark_printed(b, q, p).await
        }
        async fn get_close(
            &self,
            _: Competence,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Tagged<frame_portal_domain::Close>>
        {
            Err(frame_portal_port::ApiError::rejected(
                404,
                "NOT_FOUND",
                "Recurso não encontrado.",
            ))
        }
        async fn submit_invoice(
            &self,
            _: Competence,
            _: i64,
            _: frame_portal_port::Upload,
            _: &frame_portal_port::Preconditions,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Command<frame_portal_domain::Close>>
        {
            Err(frame_portal_port::ApiError::rejected(
                404,
                "NOT_FOUND",
                "Recurso não encontrado.",
            ))
        }
        async fn invoice_file(
            &self,
            _: Competence,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Download> {
            Err(frame_portal_port::ApiError::rejected(
                404,
                "NOT_FOUND",
                "Recurso não encontrado.",
            ))
        }
    }
    let server = start_portal(
        Arc::new(NoCloses(PrintApiMemory::new(clock.as_fn()))),
        clock.as_fn(),
        Observability::default(),
        |_| {},
    )
    .await;
    let b = Browser::new(&server.base_url);
    b.login(PASSWORD).await;
    let page = b.send(b.request(Method::GET, "/invoices")).await;
    assert_eq!(page.status(), 200);
    assert!(
        page.text()
            .await
            .unwrap()
            .contains("Notas fiscais ainda indisponíveis")
    );
    let (status, body) = b
        .json(b.request(Method::GET, "/api/print/v2/monthly-closes/2026-09"))
        .await;
    assert_eq!(
        (status, body["error"]["code"].as_str()),
        (404, Some("NOT_FOUND"))
    );
    server.shutdown().await;
}

#[tokio::test]
async fn secrets_instructions_and_documents_never_reach_spans_or_logs() {
    let obs = frame_testing::TestObservability::new();
    let logger = Arc::new(CapturingLogger::default());
    let observability = Observability {
        logger: logger.clone(),
        tracer: opentelemetry::global::tracer("frame-test"),
    };
    let s = stack(observability, Timeouts::default()).await;
    let b = &s.browser;
    let marker_instructions = "INSTRUCAO-SECRETA-7731 frente e verso";
    let marker_doc = b"%PDF-1.4\n% DOCUMENTO-SECRETO-4410\n";
    let mut batch = snapshot("open");
    batch.items[0].jobs[0].instructions = marker_instructions.into();
    batch.items[0].jobs[0].file.name = "ARQUIVO-SECRETO.pdf".into();
    batch.items[0].general_instructions.as_mut().unwrap().text = marker_instructions.into();
    let files: Vec<String> = batch.items[0].files().map(|f| f.id.clone()).collect();
    let bytes: Vec<(&str, &[u8])> = files
        .iter()
        .map(|f| (f.as_str(), &marker_doc[..]))
        .collect();
    let id = s.fake.seed_batch(batch.clone(), &bytes);
    let order_id = batch.items[0].order_id.clone();
    // Valid, malformed, scalar, wrong password, CSRF failure, 401, 429.
    let other = Browser::new(&s.server.base_url);
    for _ in 0..6 {
        other.login("SENHA-ERRADA-9921-xyz").await;
    }
    other
        .json(
            other
                .command(Method::POST, "/api/session")
                .header(header::CONTENT_TYPE, "application/json")
                .body("{\"password\":"),
        )
        .await;
    other
        .json(
            other
                .command(Method::POST, "/api/session")
                .header(header::CONTENT_TYPE, "application/json")
                .body("\"SENHA-ESCALAR\""),
        )
        .await;
    other
        .json(other.request(Method::GET, "/api/print/v2/batches"))
        .await;
    b.json(b.request(Method::GET, &format!("/api/print/v2/batches/{id}")))
        .await;
    b.send(b.request(Method::GET, "/"))
        .await
        .text()
        .await
        .unwrap();
    b.send(b.request(Method::GET, "/batches"))
        .await
        .text()
        .await
        .unwrap();
    let file_id = &files[0];
    b.send(b.request(
        Method::GET,
        &format!("/api/print/v2/batches/{id}/orders/{order_id}/files/{file_id}"),
    ))
    .await
    .bytes()
    .await
    .unwrap();
    let response = b
        .send(
            b.command(
                Method::POST,
                &format!("/api/print/v2/batches/{id}/collected"),
            )
            .header(header::IF_MATCH, format!("\"{id}:1\""))
            .header("idempotency-key", uuid::Uuid::new_v4().to_string())
            .json(&json!({})),
        )
        .await;
    let etag = response.headers()[header::ETAG]
        .to_str()
        .unwrap()
        .to_owned();
    b.send(
        b.command(Method::POST, &format!("/api/print/v2/batches/{id}/quotes"))
            .header(header::IF_MATCH, &etag)
            .header("idempotency-key", uuid::Uuid::new_v4().to_string())
            .multipart(quote_form("12345", marker_doc)),
    )
    .await;
    b.json(
        b.command(Method::POST, &format!("/api/print/v2/batches/{id}/printed"))
            .body("{"),
    )
    .await;

    let secrets = [
        PASSWORD,
        "SENHA-ERRADA-9921",
        "SENHA-ESCALAR",
        TOKEN,
        &b.csrf(),
        &b.cookie(frame_portal_web::SESSION_COOKIE).unwrap(),
        "INSTRUCAO-SECRETA-7731",
        "DOCUMENTO-SECRETO-4410",
        "ARQUIVO-SECRETO",
    ];
    let spans = obs.get_spans();
    assert!(spans.iter().any(|s| s.name == "login"));
    assert!(spans.iter().any(|s| s.name == "submitQuote"));
    assert!(spans.iter().any(|s| s.name == "getCurrentBatch"));
    let telemetry: Vec<String> = spans
        .iter()
        .map(|s| {
            format!(
                "{} {:?} {:?} {:?}",
                s.name, s.attributes, s.events, s.status
            )
        })
        .chain(logger.0.lock().unwrap().iter().cloned())
        .collect();
    assert!(telemetry.iter().any(|l| l.contains("portal.login.failed")));
    assert!(
        telemetry
            .iter()
            .any(|l| l.contains("print.quote.submitted"))
    );
    for line in &telemetry {
        for secret in secrets {
            assert!(
                !line.contains(secret),
                "telemetry leaked {secret:?}: {line}"
            );
        }
    }
    s.server.shutdown().await;
}

#[tokio::test]
async fn browser_authorization_headers_are_refused_not_ignored() {
    let clock = TestClock::at(2026, 10, 8);
    let fake = memory(&clock);
    let id = seed(&fake, &snapshot("open"));
    let server = plain_portal(fake, &clock).await;
    let b = Browser::new(&server.base_url);
    assert_eq!(b.login(PASSWORD).await.0, 200);
    let bearer =
        |req: reqwest::RequestBuilder| req.header(header::AUTHORIZATION, format!("Bearer {TOKEN}"));
    let requests = [
        bearer(b.request(Method::GET, "/api/print/v2/batches")),
        bearer(b.request(Method::GET, &format!("/api/print/v2/batches/{id}"))),
        bearer(b.request(Method::GET, "/api/session")),
        bearer(
            b.command(Method::POST, "/api/session")
                .json(&json!({"password": PASSWORD})),
        ),
        bearer(b.command(Method::DELETE, "/api/session")),
        bearer(
            b.command(
                Method::POST,
                &format!("/api/print/v2/batches/{id}/collected"),
            )
            .header(header::IF_MATCH, format!("\"{id}:1\""))
            .header("idempotency-key", uuid::Uuid::new_v4().to_string())
            .json(&json!({})),
        ),
        b.request(Method::GET, "/api/print/v2/batches")
            .header(header::AUTHORIZATION, "Basic Z3JhZmljYTp4"),
    ];
    for req in requests {
        let (status, body) = b.json(req).await;
        assert_eq!(
            (status, body["error"]["code"].as_str()),
            (400, Some("INVALID_REQUEST"))
        );
    }
    // Nothing was applied and the session is intact.
    let (status, batch) = b
        .json(b.request(Method::GET, &format!("/api/print/v2/batches/{id}")))
        .await;
    assert_eq!(
        (status, batch["batch"]["status"].as_str()),
        (200, Some("open"))
    );
    server.shutdown().await;
}

#[tokio::test]
async fn referrer_policy_keeps_same_origin_origin_headers() {
    // Under `no-referrer`, browsers send `Origin: null` on same-origin
    // POST/DELETE (Fetch "append a request Origin header"), so the exact
    // Origin check would refuse every real login/command. Proven in a real
    // headless Chromium; this pins the header that makes it work.
    let clock = TestClock::at(2026, 10, 8);
    let server = plain_portal(memory(&clock), &clock).await;
    let b = Browser::new(&server.base_url);
    for path in ["/login", "/api/session", "/assets/portal.js", "/healthz"] {
        let response = b.send(b.request(Method::GET, path)).await;
        assert_eq!(
            response.headers()[header::REFERRER_POLICY],
            "same-origin",
            "{path}"
        );
    }
    server.shutdown().await;
}

#[tokio::test]
async fn early_rejected_uploads_still_get_a_readable_json_response() {
    // A command refused before its body is read (no session / no CSRF) must
    // still answer 401/403 JSON: the server drains the bounded body instead
    // of closing the socket while the client is writing (EPIPE).
    let clock = TestClock::at(2026, 10, 8);
    let fake = memory(&clock);
    let id = seed(&fake, &snapshot("open"));
    let server = plain_portal(fake, &clock).await;
    let b = Browser::new(&server.base_url);
    assert_eq!(b.login(PASSWORD).await.0, 200);
    let mut doc = b"%PDF-1.4\n".to_vec();
    for size in [2 * 1024, 4 * 1024 * 1024] {
        doc.resize(size, b'a');
        let no_csrf = b
            .request(Method::POST, &format!("/api/print/v2/batches/{id}/quotes"))
            .header(header::ORIGIN, &b.base)
            .multipart(quote_form("45900", &doc));
        let response = no_csrf.send().await.expect("response, not a broken pipe");
        assert_eq!(response.status(), 403, "{size}");
        let body: Value = response.json().await.unwrap();
        assert_eq!(body["error"]["code"], "CSRF_FAILED");
        let anonymous = Browser::new(&server.base_url);
        let response = anonymous
            .command(Method::POST, "/api/print/v2/monthly-closes/2026-09/invoice")
            .multipart(
                multipart::Form::new()
                    .part(
                        "file",
                        multipart::Part::bytes(doc.clone()).file_name("nf.pdf"),
                    )
                    .text("declaredTotalCents", "100"),
            )
            .send()
            .await
            .expect("response, not a broken pipe");
        assert_eq!(response.status(), 401, "{size}");
        assert_eq!(
            response.json::<Value>().await.unwrap()["error"]["code"],
            "UNAUTHENTICATED"
        );
    }
    server.shutdown().await;
}

#[tokio::test]
async fn early_rejection_waits_for_the_body_so_slow_writers_read_the_answer() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    // Like undici: headers first, body afterwards. The 403 must arrive on an
    // intact connection after the whole body was written.
    let clock = TestClock::at(2026, 10, 8);
    let server = plain_portal(memory(&clock), &clock).await;
    for path in [
        "/api/print/v2/batches/00000000-0000-4000-8000-000000000000/quotes",
        "/api/print/v2/batches/00000000-0000-4000-8000-000000000000/collected",
        "/api/session",
    ] {
        let body = vec![b'a'; 64 * 1024];
        let mut socket = tokio::net::TcpStream::connect(server.addr).await.unwrap();
        let head = format!(
            "POST {path} HTTP/1.1\r\nHost: {}\r\nOrigin: http://evil.example\r\n\
             Content-Type: multipart/form-data; boundary=x\r\nContent-Length: {}\r\n\r\n",
            server.addr,
            body.len()
        );
        socket.write_all(head.as_bytes()).await.unwrap();
        for chunk in body.chunks(8 * 1024) {
            tokio::time::sleep(Duration::from_millis(15)).await;
            socket
                .write_all(chunk)
                .await
                .unwrap_or_else(|e| panic!("{path}: connection dropped mid-body: {e}"));
        }
        let mut response = vec![0u8; 4096];
        let n = socket.read(&mut response).await.unwrap();
        let text = String::from_utf8_lossy(&response[..n]);
        assert!(text.starts_with("HTTP/1.1 4"), "{path}: {text}");
        assert!(text.contains("\"error\""), "{path}: JSON error body");
    }
    server.shutdown().await;
}

#[tokio::test]
async fn a_truncated_upstream_file_never_reaches_the_browser_as_complete() {
    use crate::portal_adapter::{file_response, raw_upstream};
    let clock = TestClock::at(2026, 10, 8);
    let origin = raw_upstream(file_response("Content-Length: 100000\r\n", b"%PDF-1.4\n")).await;
    let adapter: Arc<dyn PrintApi> =
        Arc::new(PrintApiHono::new(&origin, TOKEN, Timeouts::default()).unwrap());
    let server = start_portal(adapter, clock.as_fn(), Observability::default(), |_| {}).await;
    let b = Browser::new(&server.base_url);
    assert_eq!(b.login(PASSWORD).await.0, 200);
    let path = format!(
        "/api/print/v2/batches/{}/orders/{}/files/{}",
        uuid::Uuid::new_v4(),
        uuid::Uuid::new_v4(),
        uuid::Uuid::new_v4()
    );
    let response = b.send(b.request(Method::GET, &path)).await;
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()[header::CONTENT_LENGTH], "100000");
    assert!(
        response.bytes().await.is_err(),
        "browser sees an aborted transfer"
    );
    server.shutdown().await;
}

#[tokio::test]
async fn a_panicking_handler_answers_a_sanitized_500_and_leaks_nothing() {
    const MARKER: &str = "MARKER-rust-crash-detail-99173";
    struct Exploding;
    #[async_trait::async_trait]
    impl PrintApi for Exploding {
        async fn list_batches(
            &self,
            _: &frame_portal_port::ListQuery,
        ) -> frame_portal_port::ApiResult<frame_portal_domain::BatchList> {
            panic!("{MARKER} token=secret")
        }
        async fn open_batch(
            &self,
        ) -> frame_portal_port::ApiResult<Option<frame_portal_port::Tagged<Batch>>> {
            panic!("{MARKER}")
        }
        async fn get_batch(
            &self,
            _: &str,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Tagged<Batch>> {
            panic!("{MARKER}")
        }
        async fn batch_file(
            &self,
            _: &str,
            _: &str,
            _: &str,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Download> {
            panic!("{MARKER}")
        }
        async fn collect(
            &self,
            _: &str,
            _: &frame_portal_port::Preconditions,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Command<Batch>> {
            panic!("{MARKER}")
        }
        async fn submit_quote(
            &self,
            _: &str,
            _: i64,
            _: frame_portal_port::Upload,
            _: &frame_portal_port::Preconditions,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Command<Batch>> {
            panic!("{MARKER}")
        }
        async fn quote_file(
            &self,
            _: &str,
            _: &str,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Download> {
            panic!("{MARKER}")
        }
        async fn mark_printed(
            &self,
            _: &str,
            _: &str,
            _: &frame_portal_port::Preconditions,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Command<Batch>> {
            panic!("{MARKER}")
        }
        async fn get_close(
            &self,
            _: Competence,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Tagged<frame_portal_domain::Close>>
        {
            panic!("{MARKER}")
        }
        async fn submit_invoice(
            &self,
            _: Competence,
            _: i64,
            _: frame_portal_port::Upload,
            _: &frame_portal_port::Preconditions,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Command<frame_portal_domain::Close>>
        {
            panic!("{MARKER}")
        }
        async fn invoice_file(
            &self,
            _: Competence,
        ) -> frame_portal_port::ApiResult<frame_portal_port::Download> {
            panic!("{MARKER}")
        }
    }
    let obs = frame_testing::TestObservability::new();
    let logger = Arc::new(CapturingLogger::default());
    let observability = Observability {
        logger: logger.clone(),
        tracer: opentelemetry::global::tracer("frame-test"),
    };
    // The production hook (installed by `print-portal`) with a captured sink.
    let hook_output = Arc::new(std::sync::Mutex::new(String::new()));
    let sink = hook_output.clone();
    let previous = std::panic::take_hook();
    std::panic::set_hook(frame_portal_web::panic_hook(Box::new(move |line: &str| {
        sink.lock().unwrap().push_str(line);
    })));
    let clock = TestClock::at(2026, 10, 8);
    let server = start_portal(Arc::new(Exploding), clock.as_fn(), observability, |_| {}).await;
    let b = Browser::new(&server.base_url);
    assert_eq!(b.login(PASSWORD).await.0, 200);
    let api = b
        .send(b.request(Method::GET, "/api/print/v2/batches"))
        .await;
    assert_eq!(api.status(), 500);
    let body: Value = api
        .json()
        .await
        .expect("a complete JSON response, not a reset");
    assert_eq!(body["error"]["code"], "INTERNAL");
    let page = b.send(b.request(Method::GET, "/")).await;
    assert_eq!(page.status(), 500);
    let page = page.text().await.unwrap();
    // The server keeps serving after the panics.
    assert_eq!(
        b.send(b.request(Method::GET, "/healthz")).await.status(),
        200
    );
    std::panic::set_hook(previous);
    server.shutdown().await;

    let hook = hook_output.lock().unwrap().clone();
    assert!(hook.contains("print-portal: internal error"), "{hook}");
    let telemetry: Vec<String> = obs
        .get_spans()
        .iter()
        .map(|s| {
            format!(
                "{} {:?} {:?} {:?}",
                s.name, s.attributes, s.events, s.status
            )
        })
        .chain(logger.0.lock().unwrap().iter().cloned())
        .collect();
    assert!(
        telemetry
            .iter()
            .any(|l| l.contains("portal.internal_error"))
    );
    for text in [body.to_string(), page, hook]
        .iter()
        .chain(telemetry.iter())
    {
        assert!(
            !text.contains(MARKER) && !text.contains("token=secret"),
            "leaked: {text}"
        );
    }
}

#[tokio::test]
async fn version_is_public_no_store_and_contains_only_build_revision() {
    let clock = TestClock::at(2026, 10, 8);
    let server = plain_portal(memory(&clock), &clock).await;
    let response = reqwest::get(format!("{}/version", server.base_url))
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert!(
        response.headers()[header::CONTENT_TYPE]
            .to_str()
            .unwrap()
            .starts_with("application/json")
    );
    assert_eq!(response.headers()[header::CACHE_CONTROL], "no-store");
    assert_eq!(
        response.json::<Value>().await.unwrap(),
        json!({"revision": "unknown"})
    );
    server.shutdown().await;
}

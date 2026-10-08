//! Shared `PrintApi` contract suite. Runs against the in-memory fake
//! directly and against the real HTTP adapter (over a socket to the fake
//! Hono, and — via `examples` — to the real Hono). `hooks` is the in-memory
//! fake that plays Financeiro and the clock.
#![allow(dead_code)]
use chrono::{DateTime, TimeZone, Utc};
use frame_portal_domain::{CloseState, Competence, OrderStatus, QuoteDecision};
use frame_portal_memory::{PrintApiMemory, SeedJob};
use frame_portal_port::{ApiError, ListQuery, Preconditions, PrintApi, Upload};
use futures_util::TryStreamExt;
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};

pub const PDF_A: &[u8] = b"%PDF-1.4\n% apostila de matematica\n%%EOF\n";
pub const PDF_B: &[u8] = b"%PDF-1.4\n% lista de fisica\n%%EOF\n";
pub const QUOTE_PDF: &[u8] = b"%PDF-1.4\n% orcamento\n%%EOF\n";
pub const INVOICE_PDF: &[u8] = b"%PDF-1.4\n% nota fiscal\n%%EOF\n";

/// Controllable clock shared by the fake and the portal under test.
#[derive(Clone)]
pub struct TestClock(Arc<Mutex<DateTime<Utc>>>);
impl TestClock {
    pub fn at(y: i32, m: u32, d: u32) -> Self {
        Self(Arc::new(Mutex::new(
            Utc.with_ymd_and_hms(y, m, d, 15, 0, 0).unwrap(),
        )))
    }
    pub fn now(&self) -> DateTime<Utc> {
        *self.0.lock().unwrap()
    }
    pub fn set(&self, at: DateTime<Utc>) {
        *self.0.lock().unwrap() = at;
    }
    pub fn advance(&self, by: chrono::TimeDelta) {
        let mut t = self.0.lock().unwrap();
        *t += by;
    }
    pub fn as_fn(&self) -> Arc<dyn Fn() -> DateTime<Utc> + Send + Sync> {
        let me = self.clone();
        Arc::new(move || me.now())
    }
}

pub fn job(title: &str, copies: u32, instructions: &str, filename: &str, bytes: &[u8]) -> SeedJob {
    SeedJob {
        title: title.into(),
        copies,
        instructions: instructions.into(),
        filename: filename.into(),
        bytes: bytes.to_vec(),
    }
}

/// P1 of the acceptance seed: two files with distinct instructions.
pub fn seed_p1(fake: &PrintApiMemory) -> String {
    fake.seed_order(
        "Apostila de Matemática (+1)",
        vec![
            job(
                "Apostila de Matemática",
                2,
                "Frente e verso, grampeado",
                "matematica.pdf",
                PDF_A,
            ),
            job(
                "Lista de Física",
                7,
                "Só frente, colorido",
                "../física final.pdf",
                PDF_B,
            ),
        ],
    )
}

pub fn sha(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub fn key() -> String {
    uuid::Uuid::new_v4().to_string()
}

pub fn pre(etag: &str, key: &str) -> Preconditions {
    Preconditions {
        if_match: Some(etag.into()),
        idempotency_key: Some(key.into()),
    }
}

pub fn upload(name: &str, bytes: &[u8]) -> Upload {
    Upload {
        filename: name.into(),
        bytes: bytes.to_vec().into(),
    }
}

pub fn code<T: std::fmt::Debug>(result: Result<T, ApiError>) -> (u16, String) {
    match result {
        Err(ApiError::Rejected { status, code, .. }) => (status, code),
        other => panic!("expected a contract rejection, got {other:?}"),
    }
}

pub async fn bytes(download: frame_portal_port::Download) -> Vec<u8> {
    download
        .body
        .try_fold(Vec::new(), |mut acc, chunk| async move {
            acc.extend_from_slice(&chunk);
            Ok(acc)
        })
        .await
        .unwrap()
}

/// `clock` must start inside a month (e.g. 2026-09-10).
pub async fn run(api: &dyn PrintApi, hooks: &PrintApiMemory, clock: &TestClock) {
    // ── visibility, list, read ───────────────────────────────────────────
    let p1 = seed_p1(hooks);
    let foreign = hooks.seed_foreign_order(
        "Outro fornecedor",
        vec![job("Alheio", 1, "Nada a ver", "x.pdf", PDF_A)],
    );
    let list = api.list_orders(&ListQuery::default()).await.unwrap();
    assert_eq!(list.items.len(), 1);
    assert_eq!(list.items[0].id, p1);
    assert_eq!(list.items[0].status, OrderStatus::Ready);
    assert!(list.next_cursor.is_none());

    let got = api.get_order(&p1).await.unwrap();
    assert_eq!(got.etag, format!("\"{p1}:1\""));
    let order = got.body;
    assert_eq!(order.jobs.len(), 2);
    assert_eq!((order.jobs[0].copies, order.jobs[1].copies), (2, 7));
    assert_eq!(order.jobs[1].file.name, "física final.pdf");
    for id in [
        foreign.as_str(),
        "not-a-uuid",
        &uuid::Uuid::new_v4().to_string(),
    ] {
        assert_eq!(code(api.get_order(id).await), (404, "NOT_FOUND".into()));
    }

    // ── downloads: each card's own bytes; foreign/unknown ids are 404 ────
    for (job, expected) in order.jobs.iter().zip([PDF_A, PDF_B]) {
        let d = api.order_file(&p1, &job.file.id).await.unwrap();
        assert_eq!(d.mime, "application/pdf");
        let body = bytes(d).await;
        assert_eq!(body, expected);
        assert_eq!(sha(&body), job.file.sha256);
    }
    let file_id = order.jobs[0].file.id.clone();
    assert_eq!(code(api.order_file(&foreign, &file_id).await).0, 404);
    assert_eq!(code(api.order_file(&p1, &key()).await).0, 404);
    // GET never changes business state.
    assert_eq!(
        api.get_order(&p1).await.unwrap().body.status,
        OrderStatus::Ready
    );

    // ── collect: preconditions, CAS, idempotency, state machine ─────────
    let etag1 = format!("\"{p1}:1\"");
    assert_eq!(
        code(api.collect(&p1, 1, &Preconditions::default()).await),
        (428, "PRECONDITION_REQUIRED".into())
    );
    assert_eq!(
        code(api.collect(&p1, 1, &pre(&etag1, "not-a-uuid")).await).0,
        400
    );
    assert_eq!(
        code(
            api.collect(&p1, 1, &pre(&format!("\"{p1}:9\""), &key()))
                .await
        ),
        (412, "VERSION_MISMATCH".into())
    );
    assert_eq!(code(api.collect(&p1, 2, &pre(&etag1, &key())).await).0, 412);
    assert_eq!(
        code(
            api.collect(&foreign, 1, &pre(&format!("\"{foreign}:1\""), &key()))
                .await
        )
        .0,
        404
    );
    let k = key();
    let first = api.collect(&p1, 1, &pre(&etag1, &k)).await.unwrap();
    assert_eq!((first.status, first.replayed), (200, false));
    assert_eq!(first.body.status, OrderStatus::FilesCollected);
    assert_eq!(first.etag, format!("\"{p1}:2\""));
    assert!(first.body.collected_at.is_some());
    let replay = api.collect(&p1, 1, &pre(&etag1, &k)).await.unwrap();
    assert!(replay.replayed);
    assert_eq!(
        (replay.body.clone(), replay.etag.clone()),
        (first.body.clone(), first.etag.clone())
    );
    assert_eq!(
        code(api.collect(&p1, 1, &pre(&first.etag, &k)).await),
        (409, "IDEMPOTENCY_CONFLICT".into())
    );
    assert_eq!(
        code(api.collect(&p1, 1, &pre(&first.etag, &key())).await),
        (409, "INVALID_STATE".into())
    );

    // ── quote: document checks, then pending; no printing before approval ─
    let etag2 = first.etag.clone();
    let quote_id_none = key();
    assert_eq!(
        code(
            api.mark_printed(&p1, 1, &quote_id_none, &pre(&etag2, &key()))
                .await
        ),
        (409, "INVALID_STATE".into())
    );
    assert_eq!(
        code(
            api.submit_quote(
                &p1,
                45_900,
                1,
                upload("x.html", b"<html>hi</html>"),
                &pre(&etag2, &key())
            )
            .await
        ),
        (415, "UNSUPPORTED_MEDIA_TYPE".into())
    );
    let mut big = b"%PDF-1.4\n".to_vec();
    big.resize(5 * 1024 * 1024 + 1, b'a');
    assert_eq!(
        code(
            api.submit_quote(
                &p1,
                45_900,
                1,
                upload("big.pdf", &big),
                &pre(&etag2, &key())
            )
            .await
        ),
        (413, "FILE_TOO_LARGE".into())
    );
    assert_eq!(
        code(
            api.submit_quote(
                &foreign,
                45_900,
                1,
                upload("x.html", b"<html>"),
                &pre(&etag2, &key())
            )
            .await
        )
        .0,
        404,
        "authorization precedes document validation"
    );
    let quoted = api
        .submit_quote(
            &p1,
            45_900,
            1,
            upload("orcamento.pdf", QUOTE_PDF),
            &pre(&etag2, &key()),
        )
        .await
        .unwrap();
    assert_eq!(quoted.status, 201);
    assert_eq!(quoted.body.status, OrderStatus::QuotePending);
    let quote = quoted.body.current_quote.clone().unwrap();
    assert_eq!(
        (quote.amount_cents, quote.revision, quote.decision),
        (45_900, 1, QuoteDecision::Pending)
    );
    assert_eq!(quote.document.sha256, sha(QUOTE_PDF));
    assert_eq!(
        bytes(api.quote_file(&p1, &quote.id).await.unwrap()).await,
        QUOTE_PDF
    );
    assert_eq!(code(api.quote_file(&p1, &key()).await).0, 404);
    assert_eq!(
        code(
            api.submit_quote(
                &p1,
                1,
                1,
                upload("o.pdf", QUOTE_PDF),
                &pre(&quoted.etag, &key())
            )
            .await
        ),
        (409, "INVALID_STATE".into()),
        "no second quote while one is pending"
    );

    // ── Financeiro rejects → new quote revision; approves → printed ─────
    hooks
        .decide_quote(&p1, false, Some("Valor acima do combinado"))
        .unwrap();
    let rejected = api.get_order(&p1).await.unwrap();
    assert_eq!(rejected.body.status, OrderStatus::QuoteRejected);
    assert_eq!(
        rejected
            .body
            .current_quote
            .as_ref()
            .unwrap()
            .rejection_reason
            .as_deref(),
        Some("Valor acima do combinado")
    );
    let requoted = api
        .submit_quote(
            &p1,
            41_000,
            1,
            upload("orcamento-2.pdf", QUOTE_PDF),
            &pre(&rejected.etag, &key()),
        )
        .await
        .unwrap();
    let quote2 = requoted.body.current_quote.clone().unwrap();
    assert_eq!((quote2.revision, quote2.amount_cents), (2, 41_000));
    hooks.decide_quote(&p1, true, None).unwrap();
    let approved = api.get_order(&p1).await.unwrap();
    assert_eq!(approved.body.status, OrderStatus::QuoteApproved);
    assert_eq!(approved.body.approved_amount_cents, Some(41_000));
    assert_eq!(
        code(
            api.mark_printed(&p1, 1, &quote.id, &pre(&approved.etag, &key()))
                .await
        ),
        (412, "VERSION_MISMATCH".into()),
        "an obsolete quote id never prints"
    );
    let printed = api
        .mark_printed(&p1, 1, &quote2.id, &pre(&approved.etag, &key()))
        .await
        .unwrap();
    assert_eq!(printed.body.status, OrderStatus::Printed);
    assert!(printed.body.printed_at.is_some());

    // ── keyset paging and filters ────────────────────────────────────────
    let mut more = vec![];
    for i in 0..3 {
        clock.advance(chrono::TimeDelta::seconds(1));
        more.push(hooks.seed_order(
            &format!("Pedido {i}"),
            vec![job("Folha", 1, "Simples, A4", "f.pdf", PDF_A)],
        ));
    }
    let page1 = api
        .list_orders(&ListQuery {
            limit: Some(2),
            ..ListQuery::default()
        })
        .await
        .unwrap();
    assert_eq!(
        page1.items.iter().map(|o| o.id.clone()).collect::<Vec<_>>(),
        vec![p1.clone(), more[0].clone()]
    );
    let page2 = api
        .list_orders(&ListQuery {
            limit: Some(2),
            cursor: page1.next_cursor.clone(),
            ..ListQuery::default()
        })
        .await
        .unwrap();
    assert_eq!(
        page2.items.iter().map(|o| o.id.clone()).collect::<Vec<_>>(),
        more[1..].to_vec()
    );
    assert!(page2.next_cursor.is_none());
    let ready = api
        .list_orders(&ListQuery {
            status: Some(OrderStatus::Ready),
            ..ListQuery::default()
        })
        .await
        .unwrap();
    assert_eq!(ready.items.len(), 3);
    assert_eq!(
        code(
            api.list_orders(&ListQuery {
                cursor: Some("bogus".into()),
                ..ListQuery::default()
            })
            .await
        ),
        (400, "INVALID_CURSOR".into())
    );
    assert_eq!(
        code(
            api.list_orders(&ListQuery {
                status: Some(OrderStatus::Ready),
                cursor: page1.next_cursor.clone(),
                ..ListQuery::default()
            })
            .await
        )
        .0,
        400,
        "a cursor is bound to its filter"
    );

    // ── monthly close: open period, virtual close, submit, replay, reject ─
    let month = Competence::containing(clock.now());
    let open = api.get_close(month).await.unwrap();
    assert_eq!(open.body.state, CloseState::Open);
    assert!(!open.body.period_closed);
    assert_eq!(open.body.items.len(), 1);
    assert_eq!(open.body.expected_total_cents, 41_000);
    let close_id = open.body.id.clone().unwrap();
    assert_eq!(open.etag, format!("\"{close_id}:{}\"", open.body.version));
    assert_eq!(
        code(
            api.submit_invoice(
                month,
                41_000,
                upload("nf.pdf", INVOICE_PDF),
                &pre(&open.etag, &key())
            )
            .await
        ),
        (409, "PERIOD_OPEN".into())
    );
    let empty = month.previous();
    let virtual_close = api.get_close(empty).await.unwrap();
    assert_eq!(virtual_close.etag, format!("\"month:{empty}:0\""));
    assert_eq!(
        (virtual_close.body.id.clone(), virtual_close.body.version),
        (None, 0)
    );
    assert_eq!(
        code(
            api.submit_invoice(
                empty,
                100,
                upload("nf.pdf", INVOICE_PDF),
                &pre(&virtual_close.etag, &key())
            )
            .await
        ),
        (409, "EMPTY_CLOSE".into())
    );
    assert_eq!(code(api.invoice_file(month).await).0, 404);

    clock.set(month.ends_at() + chrono::TimeDelta::days(3));
    let closed = api.get_close(month).await.unwrap();
    assert!(closed.body.period_closed && closed.body.accepts_invoice());
    let k = key();
    let submitted = api
        .submit_invoice(
            month,
            40_000,
            upload("NF setembro.pdf", INVOICE_PDF),
            &pre(&closed.etag, &k),
        )
        .await
        .unwrap();
    assert_eq!(submitted.status, 201);
    assert_eq!(submitted.body.state, CloseState::Submitted);
    assert_eq!(submitted.body.declared_total_cents, Some(40_000));
    let again = api
        .submit_invoice(
            month,
            40_000,
            upload("NF setembro.pdf", INVOICE_PDF),
            &pre(&closed.etag, &k),
        )
        .await
        .unwrap();
    assert!(again.replayed);
    assert_eq!(again.body, submitted.body);
    assert_eq!(
        code(
            api.submit_invoice(
                month,
                41_000,
                upload("NF setembro.pdf", INVOICE_PDF),
                &pre(&closed.etag, &k)
            )
            .await
        ),
        (409, "IDEMPOTENCY_CONFLICT".into())
    );
    assert_eq!(
        bytes(api.invoice_file(month).await.unwrap()).await,
        INVOICE_PDF
    );
    assert_eq!(
        code(
            api.submit_invoice(
                month,
                41_000,
                upload("nf.pdf", INVOICE_PDF),
                &pre(&submitted.etag, &key())
            )
            .await
        ),
        (409, "INVALID_STATE".into())
    );
    hooks
        .decide_invoice(month, false, Some("Valor diverge"))
        .unwrap();
    let rejected = api.get_close(month).await.unwrap();
    assert_eq!(rejected.body.state, CloseState::Rejected);
    let resubmitted = api
        .submit_invoice(
            month,
            41_000,
            upload("nf.pdf", INVOICE_PDF),
            &pre(&rejected.etag, &key()),
        )
        .await
        .unwrap();
    assert_eq!(resubmitted.body.state, CloseState::Submitted);
    hooks.decide_invoice(month, true, None).unwrap();
    assert_eq!(
        api.get_close(month).await.unwrap().body.state,
        CloseState::Accepted
    );

    // ── cancelled orders serve no files ──────────────────────────────────
    hooks.cancel(&more[0], "Pedido duplicado").unwrap();
    let cancelled = api.get_order(&more[0]).await.unwrap().body;
    assert_eq!(cancelled.status, OrderStatus::Cancelled);
    assert_eq!(
        cancelled.cancellation_reason.as_deref(),
        Some("Pedido duplicado")
    );
    assert_eq!(
        code(api.order_file(&more[0], &cancelled.jobs[0].file.id).await).0,
        404
    );
}

/// The span every adapter emits for the operations `run` exercises.
pub const SPANS: &[&str] = &[
    "print_api.listOrders",
    "print_api.getOrder",
    "print_api.orderFile",
    "print_api.collect",
    "print_api.submitQuote",
    "print_api.quoteFile",
    "print_api.markPrinted",
    "print_api.getClose",
    "print_api.submitInvoice",
    "print_api.invoiceFile",
];

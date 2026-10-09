//! Shared `PrintApi` contract suite. Runs against the in-memory fake
//! directly and against the real HTTP adapter (over a socket to the fake
//! Hono, and — via `examples` — to the real Hono). `hooks` is the in-memory
//! fake that plays Financeiro and the clock.
#![allow(dead_code)]
use chrono::{DateTime, TimeZone, Utc};
use frame_portal_domain::{Batch, BatchStatus, CloseItem, CloseState, Competence, QuoteDecision};
use frame_portal_memory::PrintApiMemory;
use frame_portal_port::{ApiError, ListQuery, Preconditions, PrintApi, Upload};
use futures_util::TryStreamExt;
use serde_json::Value;
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

/// The frozen upstream fixture vendored byte-exact for the smoke
/// (`infra/ttp/smoke-fixtures`, monorepo-incluir @ 27022467).
pub const FIXTURE: &str =
    include_str!("../../infra/ttp/smoke-fixtures/print-portal-v2.fixture.json");

pub fn fixture() -> Value {
    serde_json::from_str(FIXTURE).unwrap()
}

/// The `batches[]` snapshot of one status (`open`, `quote_pending`…).
pub fn snapshot(status: &str) -> Batch {
    let all = fixture()["batches"].clone();
    let raw = all
        .as_array()
        .unwrap()
        .iter()
        .find(|b| b["status"] == status)
        .unwrap_or_else(|| panic!("no {status} snapshot"))
        .clone();
    serde_json::from_value(raw).unwrap()
}

/// `nextBatch` / `rebatchedBatch`: complete DTOs of later timeline batches.
pub fn later(key: &str) -> Batch {
    serde_json::from_value(fixture()[key]["batch"].clone()).unwrap()
}

/// Real bytes of a fixture file (every File.id has a one-page PDF).
pub fn asset(id: &str) -> Vec<u8> {
    std::fs::read(format!(
        "{}/../infra/ttp/smoke-fixtures/print-portal-v2.assets/{id}.pdf",
        env!("CARGO_MANIFEST_DIR")
    ))
    .unwrap()
}

/// Seeds a batch with the asset bytes of all its files and current quote.
pub fn seed(fake: &PrintApiMemory, batch: &Batch) -> String {
    let mut ids: Vec<String> = batch
        .items
        .iter()
        .flat_map(|i| i.files().map(|f| f.id.clone()).collect::<Vec<_>>())
        .collect();
    ids.extend(batch.current_quote.iter().map(|q| q.document.id.clone()));
    let bytes: Vec<(String, Vec<u8>)> =
        ids.into_iter().map(|id| (id.clone(), asset(&id))).collect();
    let files: Vec<(&str, &[u8])> = bytes
        .iter()
        .map(|(id, b)| (id.as_str(), b.as_slice()))
        .collect();
    fake.seed_batch(batch.clone(), &files)
}

/// The same batch under fresh ids (another LOT, another supplier…).
pub fn renumbered(batch: &Batch, reference: &str) -> Batch {
    let mut copy = batch.clone();
    copy.id = uuid::Uuid::new_v4().to_string();
    copy.reference = reference.into();
    copy
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
    // ── nothing waiting, then the open batch ─────────────────────────────
    assert!(api.open_batch().await.unwrap().is_none());
    assert!(
        api.list_batches(&ListQuery::default())
            .await
            .unwrap()
            .items
            .is_empty()
    );
    let open = snapshot("open");
    let id = seed(hooks, &open);
    let foreign = renumbered(&later("nextBatch"), "LOT-0900");
    hooks.seed_foreign_batch(
        foreign.clone(),
        &[("00000000-0000-4000-8000-000000000015", b"x")],
    );
    let tagged = api.open_batch().await.unwrap().expect("open batch");
    assert_eq!(tagged.body, open, "fixture order and content, verbatim");
    assert_eq!(tagged.etag, format!("\"{id}:1\""));
    let list = api.list_batches(&ListQuery::default()).await.unwrap();
    assert_eq!(list.items, vec![open.summary()]);
    assert_eq!(api.get_batch(&id).await.unwrap().body, open);
    assert_eq!(code(api.get_batch(&foreign.id).await).0, 404);
    assert_eq!(code(api.get_batch("../etc").await).0, 404);

    // ── downloads: exact bytes of each member file, nothing else ─────────
    let item = &open.items[0];
    for file in item.files() {
        let download = api.batch_file(&id, &item.order_id, &file.id).await.unwrap();
        assert_eq!(download.mime, "application/pdf");
        assert_eq!(download.length, Some(file.bytes));
        let body = bytes(download).await;
        assert_eq!(sha(&body), file.sha256);
    }
    let first = &item.jobs[0].file.id;
    assert_eq!(code(api.batch_file(&id, &foreign.id, first).await).0, 404);
    assert_eq!(
        code(api.batch_file(&foreign.id, &item.order_id, first).await).0,
        404
    );

    // ── collect: 428 → 400 → 412 → applied once → replay → conflict ─────
    let missing = Preconditions::default();
    assert_eq!(
        code(api.collect(&id, &missing).await),
        (428, "PRECONDITION_REQUIRED".into())
    );
    assert_eq!(
        code(api.collect(&id, &pre(&tagged.etag, "nope")).await).0,
        400
    );
    let stale = format!("\"{id}:0\"");
    assert_eq!(
        code(api.collect(&id, &pre(&stale, &key())).await),
        (412, "VERSION_MISMATCH".into())
    );
    let k = key();
    let collected = api.collect(&id, &pre(&tagged.etag, &k)).await.unwrap();
    assert_eq!((collected.status, collected.replayed), (200, false));
    assert_eq!(collected.body.status, BatchStatus::FilesCollected);
    assert_eq!(
        collected.body.items, open.items,
        "membership frozen as seen"
    );
    assert_eq!(collected.etag, format!("\"{id}:2\""));
    let replay = api.collect(&id, &pre(&tagged.etag, &k)).await.unwrap();
    assert!(replay.replayed);
    assert_eq!(
        (replay.body, replay.etag),
        (collected.body.clone(), collected.etag.clone())
    );
    assert_eq!(
        code(api.collect(&id, &pre(&collected.etag, &k)).await),
        (409, "IDEMPOTENCY_CONFLICT".into())
    );
    assert_eq!(
        code(api.collect(&id, &pre(&tagged.etag, &key())).await).0,
        412
    );
    assert_eq!(
        code(api.collect(&id, &pre(&collected.etag, &key())).await),
        (409, "INVALID_STATE".into())
    );
    assert!(
        api.open_batch().await.unwrap().is_none(),
        "active batch hides open"
    );
    assert_eq!(
        code(
            api.collect(&foreign.id, &pre(&collected.etag, &key()))
                .await
        )
        .0,
        404
    );

    // ── quote: type and size checked, one quote per intent ──────────────
    let etag = collected.etag;
    let svg = upload("o.svg", b"<svg onload=alert(1)>");
    assert_eq!(
        code(
            api.submit_quote(&id, 45_900, svg, &pre(&etag, &key()))
                .await
        ),
        (415, "UNSUPPORTED_MEDIA_TYPE".into())
    );
    let mut big = b"%PDF-1.4\n".to_vec();
    big.resize(5 * 1024 * 1024 + 1, b'a');
    assert_eq!(
        code(
            api.submit_quote(&id, 45_900, upload("big.pdf", &big), &pre(&etag, &key()))
                .await
        ),
        (413, "FILE_TOO_LARGE".into())
    );
    let k = key();
    let quoted = api
        .submit_quote(
            &id,
            45_900,
            upload("orcamento.pdf", QUOTE_PDF),
            &pre(&etag, &k),
        )
        .await
        .unwrap();
    assert_eq!(
        (quoted.status, quoted.body.status),
        (201, BatchStatus::QuotePending)
    );
    let quote = quoted.body.current_quote.clone().unwrap();
    assert_eq!(
        (quote.revision, quote.amount_cents, quote.decision),
        (1, 45_900, QuoteDecision::Pending)
    );
    let again = api
        .submit_quote(
            &id,
            45_900,
            upload("orcamento.pdf", QUOTE_PDF),
            &pre(&etag, &k),
        )
        .await
        .unwrap();
    assert!(again.replayed);
    assert_eq!(again.body, quoted.body, "no duplicate quote");
    assert_eq!(
        code(
            api.submit_quote(
                &id,
                46_000,
                upload("orcamento.pdf", QUOTE_PDF),
                &pre(&etag, &k)
            )
            .await
        )
        .0,
        409
    );
    assert_eq!(
        bytes(api.quote_file(&id, &quote.id).await.unwrap()).await,
        QUOTE_PDF
    );
    assert_eq!(code(api.quote_file(&id, &key()).await).0, 404);

    // ── Financeiro rejects, the shop re-quotes, Financeiro approves ─────
    hooks
        .decide_quote(&id, false, Some("Corrigir quantidade total"))
        .unwrap();
    let rejected = api.get_batch(&id).await.unwrap();
    assert_eq!(rejected.body.status, BatchStatus::QuoteRejected);
    let reason = rejected
        .body
        .current_quote
        .as_ref()
        .unwrap()
        .rejection_reason
        .clone();
    assert_eq!(reason.as_deref(), Some("Corrigir quantidade total"));
    let requoted = api
        .submit_quote(
            &id,
            41_000,
            upload("novo.pdf", QUOTE_PDF),
            &pre(&rejected.etag, &key()),
        )
        .await
        .unwrap();
    assert_eq!(requoted.body.current_quote.as_ref().unwrap().revision, 2);
    assert_eq!(
        code(
            api.mark_printed(&id, &quote.id, &pre(&requoted.etag, &key()))
                .await
        ),
        (409, "INVALID_STATE".into())
    );
    hooks.decide_quote(&id, true, None).unwrap();
    let approved = api.get_batch(&id).await.unwrap();
    assert_eq!(
        (approved.body.status, approved.body.approved_amount_cents),
        (BatchStatus::QuoteApproved, Some(41_000))
    );
    let quote_id = approved.body.current_quote.as_ref().unwrap().id.clone();

    // ── printed bills the whole batch once; receipt ends it ─────────────
    assert_eq!(
        code(
            api.mark_printed(&id, &quote.id, &pre(&approved.etag, &key()))
                .await
        )
        .0,
        412
    );
    let printed = api
        .mark_printed(&id, &quote_id, &pre(&approved.etag, &key()))
        .await
        .unwrap();
    assert_eq!(printed.body.status, BatchStatus::Printed);
    assert!(printed.body.printed_at.is_some());
    assert!(api.open_batch().await.unwrap().is_none());
    hooks.receive(&id).unwrap();
    assert_eq!(
        api.get_batch(&id).await.unwrap().body.status,
        BatchStatus::Received
    );

    // ── history: every batch, createdAt order, paged, filter-bound cursor ─
    let next = later("nextBatch");
    seed(hooks, &next);
    assert_eq!(api.open_batch().await.unwrap().unwrap().body, next);
    let page1 = api
        .list_batches(&ListQuery {
            limit: Some(1),
            ..ListQuery::default()
        })
        .await
        .unwrap();
    assert_eq!(page1.items.len(), 1);
    let page2 = api
        .list_batches(&ListQuery {
            limit: Some(1),
            cursor: page1.next_cursor.clone(),
            ..ListQuery::default()
        })
        .await
        .unwrap();
    assert_eq!(page2.items.len(), 1);
    assert_ne!(page1.items[0].id, page2.items[0].id);
    assert!(page2.next_cursor.is_none());
    let received = api
        .list_batches(&ListQuery {
            status: Some(BatchStatus::Received),
            ..ListQuery::default()
        })
        .await
        .unwrap();
    assert_eq!(received.items.len(), 1);
    assert_eq!(received.items[0].id, id);
    let bound = ListQuery {
        status: Some(BatchStatus::Open),
        cursor: page1.next_cursor.clone(),
        ..ListQuery::default()
    };
    assert_eq!(
        code(api.list_batches(&bound).await),
        (400, "INVALID_CURSOR".into())
    );
    let bad = ListQuery {
        limit: Some(0),
        ..ListQuery::default()
    };
    assert_eq!(code(api.list_batches(&bad).await).0, 400);

    // ── cancellation keeps history and files; the next batch is flagged ─
    hooks
        .cancel(&next.id, "Lote cancelado pelo Financeiro")
        .unwrap();
    let cancelled = api.get_batch(&next.id).await.unwrap().body;
    assert_eq!(cancelled.status, BatchStatus::Cancelled);
    let next_file = &next.items[0].jobs[0].file;
    let kept = api
        .batch_file(&next.id, &next.items[0].order_id, &next_file.id)
        .await
        .unwrap();
    assert_eq!(sha(&bytes(kept).await), next_file.sha256);
    let rebatched = later("rebatchedBatch");
    seed(hooks, &rebatched);
    let current = api.open_batch().await.unwrap().unwrap().body;
    assert_eq!(
        current.items[0].previously_cancelled_in.as_deref(),
        Some("LOT-0001")
    );
    assert_eq!(current.items[1].previously_cancelled_in, None);

    // ── an empty open batch is not collectable ──────────────────────────
    hooks.cancel(&rebatched.id, "Teste").unwrap();
    let mut empty = renumbered(&open, "LOT-0004");
    empty.items.clear();
    empty.item_count = 0;
    let empty_id = hooks.seed_batch(empty, &[]);
    let etag = api.get_batch(&empty_id).await.unwrap().etag;
    assert_eq!(
        code(api.collect(&empty_id, &pre(&etag, &key())).await),
        (409, "EMPTY_BATCH".into())
    );

    // ── monthly close: open period, virtual close, submit, replay, reject ─
    let month = Competence::containing(clock.now());
    let open = api.get_close(month).await.unwrap();
    assert_eq!(open.body.state, CloseState::Open);
    assert!(!open.body.period_closed);
    assert_eq!(open.body.expected_total_cents, 41_000);
    assert!(matches!(
        &open.body.items[..],
        [CloseItem::Batch { batch_id, amount_cents: 41_000, .. }] if *batch_id == id
    ));
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
}

/// The span every adapter emits for the operations `run` exercises.
pub const SPANS: &[&str] = &[
    "print_api.listBatches",
    "print_api.openBatch",
    "print_api.getBatch",
    "print_api.batchFile",
    "print_api.collect",
    "print_api.submitQuote",
    "print_api.quoteFile",
    "print_api.markPrinted",
    "print_api.getClose",
    "print_api.submitInvoice",
    "print_api.invoiceFile",
];

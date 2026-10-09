//! Print-shop operations over the `PrintApi` port. The Incluir API is the
//! single authority (state, price, revision, idempotency); these use cases
//! add one span each, business logs on success and an operational warning
//! when the upstream is unavailable. Attributes carry ids and shapes only:
//! never instructions, file names, amounts, tokens or documents.
use frame_observability::{LogAttributes, Observability, in_span};
use frame_portal_domain::{Batch, BatchList, Close, Competence};
use frame_portal_port::{
    ApiError, ApiResult, Command, Download, ListQuery, Preconditions, PrintApi, Tagged, Upload,
};
use opentelemetry::KeyValue;
use serde_json::Value;
use std::future::Future;

pub struct PrintDeps<'a> {
    pub api: &'a dyn PrintApi,
    pub observability: &'a Observability,
}

fn attrs(pairs: Vec<(&str, Value)>) -> LogAttributes {
    pairs.into_iter().map(|(k, v)| (k.to_owned(), v)).collect()
}

async fn run<T>(
    deps: &PrintDeps<'_>,
    name: &'static str,
    attributes: Vec<KeyValue>,
    future: impl Future<Output = ApiResult<T>>,
) -> ApiResult<T> {
    let result = in_span(&deps.observability.tracer, name, attributes, future).await;
    if let Err(ApiError::Unavailable { reason }) = &result {
        deps.observability.logger.warn(
            "portal.upstream.unavailable",
            Some(&attrs(vec![
                ("operation", name.into()),
                ("reason", (*reason).into()),
            ])),
        );
    }
    result
}

fn command_log<T>(
    deps: &PrintDeps<'_>,
    event: &str,
    key: &str,
    id: &str,
    result: &ApiResult<Command<T>>,
) {
    if let Ok(command) = result {
        deps.observability.logger.info(
            event,
            Some(&attrs(vec![
                (key, id.into()),
                ("replayed", command.replayed.into()),
            ])),
        );
    }
}

pub async fn list_batches(deps: PrintDeps<'_>, query: ListQuery) -> ApiResult<BatchList> {
    let mut attributes = vec![KeyValue::new(
        "print.list.limit",
        i64::from(query.limit.unwrap_or(20)),
    )];
    if let Some(status) = query.status {
        attributes.push(KeyValue::new("print.list.status", status.as_str()));
    }
    attributes.push(KeyValue::new("print.list.paged", query.cursor.is_some()));
    run(
        &deps,
        "listBatches",
        attributes,
        deps.api.list_batches(&query),
    )
    .await
}

/// Upper bound of history pages scanned for the active batch.
const CURRENT_SCAN_PAGES: usize = 20;

/// The supplier's single current batch: the open one, else the active
/// collected…printed one (the upstream hides the open batch meanwhile).
/// `None` = nothing waiting for the print shop.
pub async fn get_current_batch(deps: PrintDeps<'_>) -> ApiResult<Option<Tagged<Batch>>> {
    let api = deps.api;
    let future = async move {
        if let Some(open) = api.open_batch().await? {
            return Ok(Some(open));
        }
        let mut cursor = None;
        for _ in 0..CURRENT_SCAN_PAGES {
            let query = ListQuery {
                status: None,
                limit: Some(100),
                cursor,
            };
            let page = api.list_batches(&query).await?;
            if let Some(active) = page.items.iter().find(|b| b.status.is_current()) {
                return api.get_batch(&active.id).await.map(Some);
            }
            match page.next_cursor {
                Some(next) => cursor = Some(next),
                None => return Ok(None),
            }
        }
        Err(ApiError::Unavailable { reason: "contract" })
    };
    run(&deps, "getCurrentBatch", vec![], future).await
}

pub async fn get_batch(deps: PrintDeps<'_>, batch_id: &str) -> ApiResult<Tagged<Batch>> {
    let attributes = vec![KeyValue::new("print.batch.id", batch_id.to_owned())];
    run(&deps, "getBatch", attributes, deps.api.get_batch(batch_id)).await
}

pub async fn download_batch_file(
    deps: PrintDeps<'_>,
    batch_id: &str,
    order_id: &str,
    file_id: &str,
) -> ApiResult<Download> {
    let attributes = vec![
        KeyValue::new("print.batch.id", batch_id.to_owned()),
        KeyValue::new("print.order.id", order_id.to_owned()),
        KeyValue::new("print.file.id", file_id.to_owned()),
    ];
    let future = deps.api.batch_file(batch_id, order_id, file_id);
    run(&deps, "downloadBatchFile", attributes, future).await
}

pub async fn collect_files(
    deps: PrintDeps<'_>,
    batch_id: &str,
    pre: &Preconditions,
) -> ApiResult<Command<Batch>> {
    let attributes = vec![KeyValue::new("print.batch.id", batch_id.to_owned())];
    let future = deps.api.collect(batch_id, pre);
    let result = run(&deps, "collectFiles", attributes, future).await;
    command_log(&deps, "print.batch.collected", "batchId", batch_id, &result);
    result
}

pub async fn submit_quote(
    deps: PrintDeps<'_>,
    batch_id: &str,
    amount_cents: i64,
    file: Upload,
    pre: &Preconditions,
) -> ApiResult<Command<Batch>> {
    let attributes = vec![
        KeyValue::new("print.batch.id", batch_id.to_owned()),
        KeyValue::new("print.document.bytes", file.bytes.len() as i64),
    ];
    let future = deps.api.submit_quote(batch_id, amount_cents, file, pre);
    let result = run(&deps, "submitQuote", attributes, future).await;
    command_log(&deps, "print.quote.submitted", "batchId", batch_id, &result);
    result
}

pub async fn download_quote_file(
    deps: PrintDeps<'_>,
    batch_id: &str,
    quote_id: &str,
) -> ApiResult<Download> {
    let attributes = vec![
        KeyValue::new("print.batch.id", batch_id.to_owned()),
        KeyValue::new("print.quote.id", quote_id.to_owned()),
    ];
    let future = deps.api.quote_file(batch_id, quote_id);
    run(&deps, "downloadQuoteFile", attributes, future).await
}

pub async fn mark_printed(
    deps: PrintDeps<'_>,
    batch_id: &str,
    quote_id: &str,
    pre: &Preconditions,
) -> ApiResult<Command<Batch>> {
    let attributes = vec![
        KeyValue::new("print.batch.id", batch_id.to_owned()),
        KeyValue::new("print.quote.id", quote_id.to_owned()),
    ];
    let future = deps.api.mark_printed(batch_id, quote_id, pre);
    let result = run(&deps, "markPrinted", attributes, future).await;
    command_log(&deps, "print.batch.printed", "batchId", batch_id, &result);
    result
}

pub async fn get_monthly_close(
    deps: PrintDeps<'_>,
    competence: Competence,
) -> ApiResult<Tagged<Close>> {
    let attributes = vec![KeyValue::new(
        "print.close.competence",
        competence.to_string(),
    )];
    run(
        &deps,
        "getMonthlyClose",
        attributes,
        deps.api.get_close(competence),
    )
    .await
}

pub async fn submit_invoice(
    deps: PrintDeps<'_>,
    competence: Competence,
    declared_total_cents: i64,
    file: Upload,
    pre: &Preconditions,
) -> ApiResult<Command<Close>> {
    let attributes = vec![
        KeyValue::new("print.close.competence", competence.to_string()),
        KeyValue::new("print.document.bytes", file.bytes.len() as i64),
    ];
    let future = deps
        .api
        .submit_invoice(competence, declared_total_cents, file, pre);
    let result = run(&deps, "submitInvoice", attributes, future).await;
    let competence = competence.to_string();
    command_log(
        &deps,
        "print.invoice.submitted",
        "competence",
        &competence,
        &result,
    );
    result
}

pub async fn download_invoice(deps: PrintDeps<'_>, competence: Competence) -> ApiResult<Download> {
    let attributes = vec![KeyValue::new(
        "print.close.competence",
        competence.to_string(),
    )];
    let future = deps.api.invoice_file(competence);
    run(&deps, "downloadInvoice", attributes, future).await
}

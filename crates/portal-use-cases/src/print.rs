//! Print-shop operations over the `PrintApi` port. The Incluir API is the
//! single authority (state, price, revision, idempotency); these use cases
//! add one span each, business logs on success and an operational warning
//! when the upstream is unavailable. Attributes carry ids and shapes only:
//! never instructions, file names, amounts, tokens or documents.
use frame_observability::{LogAttributes, Observability, in_span};
use frame_portal_domain::{Close, Competence, Order, OrderList};
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

pub async fn list_orders(deps: PrintDeps<'_>, query: ListQuery) -> ApiResult<OrderList> {
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
        "listOrders",
        attributes,
        deps.api.list_orders(&query),
    )
    .await
}

pub async fn get_order(deps: PrintDeps<'_>, order_id: &str) -> ApiResult<Tagged<Order>> {
    let attributes = vec![KeyValue::new("print.order.id", order_id.to_owned())];
    run(&deps, "getOrder", attributes, deps.api.get_order(order_id)).await
}

pub async fn download_order_file(
    deps: PrintDeps<'_>,
    order_id: &str,
    file_id: &str,
) -> ApiResult<Download> {
    let attributes = vec![
        KeyValue::new("print.order.id", order_id.to_owned()),
        KeyValue::new("print.file.id", file_id.to_owned()),
    ];
    let future = deps.api.order_file(order_id, file_id);
    run(&deps, "downloadOrderFile", attributes, future).await
}

pub async fn collect_files(
    deps: PrintDeps<'_>,
    order_id: &str,
    revision: u64,
    pre: &Preconditions,
) -> ApiResult<Command<Order>> {
    let attributes = vec![
        KeyValue::new("print.order.id", order_id.to_owned()),
        KeyValue::new("print.order.revision", revision as i64),
    ];
    let future = deps.api.collect(order_id, revision, pre);
    let result = run(&deps, "collectFiles", attributes, future).await;
    command_log(&deps, "print.order.collected", "orderId", order_id, &result);
    result
}

pub async fn submit_quote(
    deps: PrintDeps<'_>,
    order_id: &str,
    amount_cents: i64,
    order_revision: u64,
    file: Upload,
    pre: &Preconditions,
) -> ApiResult<Command<Order>> {
    let attributes = vec![
        KeyValue::new("print.order.id", order_id.to_owned()),
        KeyValue::new("print.order.revision", order_revision as i64),
        KeyValue::new("print.document.bytes", file.bytes.len() as i64),
    ];
    let future = deps
        .api
        .submit_quote(order_id, amount_cents, order_revision, file, pre);
    let result = run(&deps, "submitQuote", attributes, future).await;
    command_log(&deps, "print.quote.submitted", "orderId", order_id, &result);
    result
}

pub async fn download_quote_file(
    deps: PrintDeps<'_>,
    order_id: &str,
    quote_id: &str,
) -> ApiResult<Download> {
    let attributes = vec![
        KeyValue::new("print.order.id", order_id.to_owned()),
        KeyValue::new("print.quote.id", quote_id.to_owned()),
    ];
    let future = deps.api.quote_file(order_id, quote_id);
    run(&deps, "downloadQuoteFile", attributes, future).await
}

pub async fn mark_printed(
    deps: PrintDeps<'_>,
    order_id: &str,
    revision: u64,
    quote_id: &str,
    pre: &Preconditions,
) -> ApiResult<Command<Order>> {
    let attributes = vec![
        KeyValue::new("print.order.id", order_id.to_owned()),
        KeyValue::new("print.order.revision", revision as i64),
        KeyValue::new("print.quote.id", quote_id.to_owned()),
    ];
    let future = deps.api.mark_printed(order_id, revision, quote_id, pre);
    let result = run(&deps, "markPrinted", attributes, future).await;
    command_log(&deps, "print.order.printed", "orderId", order_id, &result);
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

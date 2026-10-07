use opentelemetry::{
    Context, KeyValue, global,
    trace::{FutureExt, Status, TraceContextExt, Tracer},
};
use std::{error::Error, future::Future};

/// Like TS noopTracer, this resolves the global provider under a distinct name.
pub fn noop_tracer() -> global::BoxedTracer {
    global::tracer("frame-noop")
}

/// Attach context per poll, never hold a thread-local guard across `.await`.
/// End every span on success and typed failure; adapters emit no log records.
pub async fn in_span<T, E: Error, F: Future<Output = Result<T, E>>>(
    tracer: &global::BoxedTracer,
    name: &'static str,
    attributes: Vec<KeyValue>,
    future: F,
) -> Result<T, E> {
    let span = tracer
        .span_builder(name)
        .with_attributes(attributes)
        .start(tracer);
    let context = Context::current_with_span(span);
    let result = future.with_context(context.clone()).await;
    let span = context.span();
    match &result {
        Ok(_) => span.set_status(Status::Ok),
        Err(error) => {
            span.record_error(error);
            span.set_status(Status::error(error.to_string()));
        }
    }
    span.end();
    result
}

pub async fn repository_span<T, E: Error, F: Future<Output = Result<T, E>>>(
    system: &'static str,
    method: &'static str,
    operation: &'static str,
    future: F,
) -> Result<T, E> {
    in_span(
        &global::tracer("frame"),
        method,
        vec![
            KeyValue::new("db.system", system),
            KeyValue::new("db.collection.name", "cats"),
            KeyValue::new("db.operation.name", operation),
        ],
        future,
    )
    .await
}

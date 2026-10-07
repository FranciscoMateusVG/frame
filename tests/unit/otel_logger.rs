use frame::{Logger, OtelLogger};
use frame_testing::TestObservability;
use opentelemetry::{
    Context,
    logs::{AnyValue, LoggerProvider, Severity},
    trace::{TraceContextExt, Tracer},
};
use opentelemetry_sdk::logs::{InMemoryLogExporter, SdkLoggerProvider};
use serde_json::json;

#[test]
fn otel_logger_forwards_all_levels_attributes_and_scope() {
    let exporter = InMemoryLogExporter::default();
    let provider = SdkLoggerProvider::builder()
        .with_simple_exporter(exporter.clone())
        .build();
    let logger = OtelLogger::new(provider.logger("frame-test"));
    logger.info(
        "cat.created",
        json!({"catId":"abc-123", "nameLength":7}).as_object(),
    );
    logger.warn("cat.suspicious", None);
    logger.error("cat.lost", None);
    logger.debug("cat.napping", None);
    let logs = exporter.get_emitted_logs().unwrap();
    assert_eq!(logs.len(), 4);
    for (i, (severity, text, body)) in [
        (Severity::Info, "INFO", "cat.created"),
        (Severity::Warn, "WARN", "cat.suspicious"),
        (Severity::Error, "ERROR", "cat.lost"),
        (Severity::Debug, "DEBUG", "cat.napping"),
    ]
    .iter()
    .enumerate()
    {
        assert_eq!(logs[i].record.severity_number(), Some(*severity));
        assert_eq!(logs[i].record.severity_text(), Some(*text));
        assert_eq!(
            logs[i].record.body(),
            Some(&AnyValue::from(body.to_string()))
        );
    }
    let attrs: Vec<_> = logs[0].record.attributes_iter().cloned().collect();
    assert!(attrs.contains(&("catId".into(), "abc-123".into())));
    assert!(attrs.contains(&("nameLength".into(), 7_i64.into())));
    assert_eq!(logs[1].record.attributes_iter().count(), 0);
    exporter.reset();
    OtelLogger::new(provider.logger("my-app")).info("hello", None);
    assert_eq!(
        exporter.get_emitted_logs().unwrap()[0]
            .instrumentation
            .name(),
        "my-app"
    );
    provider.shutdown().unwrap();
}

#[test]
fn otel_logs_automatically_correlate_with_active_span_only() {
    let obs = TestObservability::new();
    let exporter = InMemoryLogExporter::default();
    let provider = SdkLoggerProvider::builder()
        .with_simple_exporter(exporter.clone())
        .build();
    let logger = OtelLogger::new(provider.logger("frame-test"));
    let span = obs.observability.tracer.start("parent.op");
    let context = Context::current_with_span(span);
    let ids = context.span().span_context().clone();
    {
        let _guard = context.clone().attach();
        logger.info("inside.span", json!({"phase":"mid"}).as_object());
    }
    context.span().end();
    logger.info("outside.span", None);
    let logs = exporter.get_emitted_logs().unwrap();
    assert_eq!(logs.len(), 2);
    let trace = logs[0].record.trace_context().unwrap();
    assert_eq!(trace.trace_id, ids.trace_id());
    assert_eq!(trace.span_id, ids.span_id());
    assert!(logs[1].record.trace_context().is_none());
    provider.shutdown().unwrap();
}

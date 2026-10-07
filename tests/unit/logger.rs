use frame::{ConsoleLogger, LogLevel, Logger, NoopLogger, OtelLogger};
use serde_json::json;

#[test]
fn console_info_formats_timestamp_level_message_attributes() {
    let mut out = vec![];
    let mut err = vec![];
    ConsoleLogger
        .write(
            &mut out,
            &mut err,
            LogLevel::Info,
            "test message",
            json!({"key":"value"}).as_object(),
        )
        .unwrap();
    let line = String::from_utf8(out).unwrap();
    assert!(line.starts_with('['));
    assert!(line.contains("Z] INFO  test message {\"key\":\"value\"}"));
    assert!(err.is_empty());
}
#[test]
fn console_routes_warn_error_to_stderr_debug_to_stdout() {
    for level in [LogLevel::Warn, LogLevel::Error, LogLevel::Debug] {
        let mut out = vec![];
        let mut err = vec![];
        ConsoleLogger
            .write(&mut out, &mut err, level, "message", None)
            .unwrap();
        let line = String::from_utf8(if level == LogLevel::Debug {
            assert!(err.is_empty());
            out
        } else {
            assert!(out.is_empty());
            err
        })
        .unwrap();
        assert!(line.contains(level.label()));
    }
}
#[test]
fn console_omits_empty_or_absent_attributes() {
    let empty = serde_json::Map::new();
    for attrs in [None, Some(&empty)] {
        let mut out = vec![];
        ConsoleLogger
            .write(&mut out, &mut vec![], LogLevel::Info, "no attrs", attrs)
            .unwrap();
        assert!(!String::from_utf8(out).unwrap().contains('{'));
    }
}
#[test]
fn noop_and_unconfigured_otel_are_safe_for_all_levels() {
    for logger in [&NoopLogger as &dyn Logger, &OtelLogger::default()] {
        logger.info("msg", json!({"a":1}).as_object());
        logger.warn("msg", None);
        logger.error("msg", None);
        logger.debug("msg", None);
    }
}

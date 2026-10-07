use opentelemetry::logs::{AnyValue, LogRecord, Logger as OtelLoggerApi, Severity};
use serde_json::{Map, Value};
use std::io::Write;

pub type LogAttributes = Map<String, Value>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogLevel {
    Info,
    Warn,
    Error,
    Debug,
}
impl LogLevel {
    pub fn label(self) -> &'static str {
        match self {
            Self::Info => "INFO",
            Self::Warn => "WARN",
            Self::Error => "ERROR",
            Self::Debug => "DEBUG",
        }
    }
    fn severity(self) -> Severity {
        match self {
            Self::Info => Severity::Info,
            Self::Warn => Severity::Warn,
            Self::Error => Severity::Error,
            Self::Debug => Severity::Debug,
        }
    }
}

pub trait Logger: Send + Sync {
    fn log(&self, level: LogLevel, message: &str, attrs: Option<&LogAttributes>);
    fn info(&self, message: &str, attrs: Option<&LogAttributes>) {
        self.log(LogLevel::Info, message, attrs);
    }
    fn warn(&self, message: &str, attrs: Option<&LogAttributes>) {
        self.log(LogLevel::Warn, message, attrs);
    }
    fn error(&self, message: &str, attrs: Option<&LogAttributes>) {
        self.log(LogLevel::Error, message, attrs);
    }
    fn debug(&self, message: &str, attrs: Option<&LogAttributes>) {
        self.log(LogLevel::Debug, message, attrs);
    }
}

pub struct NoopLogger;
impl Logger for NoopLogger {
    fn log(&self, _: LogLevel, _: &str, _: Option<&LogAttributes>) {}
}

pub struct ConsoleLogger;
impl ConsoleLogger {
    /// Writer boundary keeps formatting and stdout/stderr routing testable.
    pub fn write<'a>(
        &self,
        stdout: &'a mut dyn Write,
        stderr: &'a mut dyn Write,
        level: LogLevel,
        message: &str,
        attrs: Option<&LogAttributes>,
    ) -> std::io::Result<()> {
        let date: chrono::DateTime<chrono::Utc> = std::time::SystemTime::now().into();
        let attrs = attrs
            .filter(|a| !a.is_empty())
            .map(|a| {
                format!(
                    " {}",
                    serde_json::to_string(a).expect("JSON values serialize")
                )
            })
            .unwrap_or_default();
        let writer = if matches!(level, LogLevel::Warn | LogLevel::Error) {
            stderr
        } else {
            stdout
        };
        writeln!(
            writer,
            "[{}] {:5} {message}{attrs}",
            date.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            level.label()
        )
    }
}
impl Logger for ConsoleLogger {
    fn log(&self, level: LogLevel, message: &str, attrs: Option<&LogAttributes>) {
        let _ = self.write(
            &mut std::io::stdout().lock(),
            &mut std::io::stderr().lock(),
            level,
            message,
            attrs,
        );
    }
}

/// The Rust API has no global logger provider. Inject the API logger from the
/// consumer's provider; use Default for no-op behavior without an SDK.
pub struct OtelLogger<L: OtelLoggerApi + Send + Sync> {
    inner: L,
}
impl<L: OtelLoggerApi + Send + Sync> OtelLogger<L> {
    pub fn new(inner: L) -> Self {
        Self { inner }
    }
}
impl Default
    for OtelLogger<
        <opentelemetry::logs::NoopLoggerProvider as opentelemetry::logs::LoggerProvider>::Logger,
    >
{
    fn default() -> Self {
        Self::new(opentelemetry::logs::LoggerProvider::logger(
            &opentelemetry::logs::NoopLoggerProvider::new(),
            "frame",
        ))
    }
}
impl<L: OtelLoggerApi + Send + Sync> Logger for OtelLogger<L> {
    fn log(&self, level: LogLevel, message: &str, attrs: Option<&LogAttributes>) {
        let mut record = self.inner.create_log_record();
        record.set_severity_number(level.severity());
        record.set_severity_text(level.label());
        record.set_body(message.to_owned().into());
        for (key, value) in attrs.into_iter().flatten() {
            record.add_attribute(key.clone(), json_value(value));
        }
        self.inner.emit(record);
    }
}
fn json_value(value: &Value) -> AnyValue {
    match value {
        Value::Bool(v) => (*v).into(),
        Value::Number(n) => n
            .as_i64()
            .map(AnyValue::Int)
            .unwrap_or_else(|| AnyValue::Double(n.as_f64().unwrap_or_default())),
        Value::String(v) => v.clone().into(),
        Value::Array(v) => AnyValue::ListAny(Box::new(v.iter().map(json_value).collect())),
        Value::Object(v) => AnyValue::Map(Box::new(
            v.iter()
                .map(|(k, v)| (k.clone().into(), json_value(v)))
                .collect(),
        )),
        Value::Null => "null".into(),
    }
}

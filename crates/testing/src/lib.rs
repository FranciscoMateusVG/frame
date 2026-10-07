//! Consumer test helper; the only SDK-dependent library crate.
use frame_observability::{NoopLogger, Observability};
use opentelemetry::{global, trace::TracerProvider};
use opentelemetry_sdk::trace::{InMemorySpanExporter, SdkTracerProvider, SpanData};
use std::{
    cell::Cell,
    sync::{Arc, Mutex, MutexGuard},
};

// The OTel provider is process-global. Serialize fixtures, not application logic.
static PROVIDER_LOCK: Mutex<()> = Mutex::new(());
pub struct TestObservability {
    pub observability: Observability,
    provider: SdkTracerProvider,
    exporter: InMemorySpanExporter,
    shutdown: Cell<bool>,
    _guard: MutexGuard<'static, ()>,
}
impl TestObservability {
    pub fn new() -> Self {
        let guard = PROVIDER_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let exporter = InMemorySpanExporter::default();
        let provider = SdkTracerProvider::builder()
            .with_simple_exporter(exporter.clone())
            .build();
        global::set_tracer_provider(provider.clone());
        Self {
            observability: Observability {
                logger: Arc::new(NoopLogger),
                tracer: global::BoxedTracer::new(Box::new(provider.tracer("frame-test"))),
            },
            provider,
            exporter,
            shutdown: Cell::new(false),
            _guard: guard,
        }
    }
    pub fn get_spans(&self) -> Vec<SpanData> {
        self.exporter
            .get_finished_spans()
            .expect("span exporter readable")
    }
    pub fn reset(&self) {
        self.exporter.reset();
    }
    pub fn shutdown(&self) {
        if self.shutdown.replace(true) {
            return;
        }
        self.provider
            .shutdown()
            .expect("tracer provider shuts down");
        global::set_tracer_provider(opentelemetry::trace::noop::NoopTracerProvider::new());
    }
}
impl Default for TestObservability {
    fn default() -> Self {
        Self::new()
    }
}
impl Drop for TestObservability {
    fn drop(&mut self) {
        self.shutdown();
    }
}

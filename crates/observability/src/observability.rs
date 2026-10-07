use crate::{Logger, NoopLogger, noop_tracer};
use opentelemetry::global::BoxedTracer;
use std::sync::Arc;

pub struct Observability {
    pub logger: Arc<dyn Logger>,
    pub tracer: BoxedTracer,
}
impl Default for Observability {
    fn default() -> Self {
        Self {
            logger: Arc::new(NoopLogger),
            tracer: noop_tracer(),
        }
    }
}

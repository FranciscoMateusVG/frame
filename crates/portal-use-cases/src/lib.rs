//! Portal use cases: session lifecycle (in-memory registry, login limiter)
//! and the print-shop operations over the `PrintApi` port. Plain async
//! functions with explicit deps; exactly one span per use case.
mod auth;
mod limiter;
mod print;
mod session;
pub use auth::*;
pub use limiter::*;
pub use print::*;
pub use session::*;

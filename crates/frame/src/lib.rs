//! Public SDK surface. Concrete adapters are separate crates, not re-exports.
pub use frame_domain::*;
pub use frame_errors::*;
pub use frame_observability::*;
pub use frame_port::CatRepository;
pub use frame_postgres::{Database, create_database};
pub use frame_use_cases::*;

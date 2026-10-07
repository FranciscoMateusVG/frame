//! Concrete adapter subpath equivalent; not re-exported by the public facade.
mod cat_repository;
mod database;
pub use cat_repository::CatRepositoryPostgres;
pub use database::{Database, MIGRATOR, create_database};

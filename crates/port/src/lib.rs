//! Cat persistence port. No concrete adapter dependencies.
use async_trait::async_trait;
use frame_domain::Cat;
use frame_errors::Error;

#[async_trait]
pub trait CatRepository: Send + Sync {
    async fn save(&self, cat: &Cat) -> Result<(), Error>;
    async fn find_by_id(&self, id: &str) -> Result<Option<Cat>, Error>;
    async fn find_by_name(&self, name: &str) -> Result<Option<Cat>, Error>;
    async fn delete_by_id(&self, id: &str) -> Result<bool, Error>;
}

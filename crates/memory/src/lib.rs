use async_trait::async_trait;
use frame_domain::Cat;
use frame_errors::{CatAlreadyExistsError, Error};
use frame_observability::repository_span;
use frame_port::CatRepository;
use std::{collections::HashMap, sync::Mutex};

#[derive(Default)]
pub struct CatRepositoryMemory {
    cats: Mutex<HashMap<String, Cat>>,
}

#[async_trait]
impl CatRepository for CatRepositoryMemory {
    async fn save(&self, cat: &Cat) -> Result<(), Error> {
        repository_span("memory", "db.cats.save", "INSERT", async {
            let mut cats = self.cats.lock().expect("cat map lock poisoned");
            if cats.values().any(|existing| existing.name == cat.name) {
                return Err(CatAlreadyExistsError {
                    cat_name: cat.name.clone(),
                }
                .into());
            }
            // Deliberately preserve TS Map.set's same-ID/different-name overwrite.
            cats.insert(cat.id.clone(), cat.clone());
            Ok(())
        })
        .await
    }
    async fn find_by_id(&self, id: &str) -> Result<Option<Cat>, Error> {
        repository_span("memory", "db.cats.findById", "SELECT", async {
            Ok(self
                .cats
                .lock()
                .expect("cat map lock poisoned")
                .get(id)
                .cloned())
        })
        .await
    }
    async fn find_by_name(&self, name: &str) -> Result<Option<Cat>, Error> {
        repository_span("memory", "db.cats.findByName", "SELECT", async {
            Ok(self
                .cats
                .lock()
                .expect("cat map lock poisoned")
                .values()
                .find(|cat| cat.name == name)
                .cloned())
        })
        .await
    }
    async fn delete_by_id(&self, id: &str) -> Result<bool, Error> {
        repository_span("memory", "db.cats.deleteById", "DELETE", async {
            Ok(self
                .cats
                .lock()
                .expect("cat map lock poisoned")
                .remove(id)
                .is_some())
        })
        .await
    }
}

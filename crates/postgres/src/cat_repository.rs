use crate::Database;
use async_trait::async_trait;
use frame_domain::Cat;
use frame_errors::{CatAlreadyExistsError, Error};
use frame_observability::repository_span;
use frame_port::CatRepository;

#[derive(Clone)]
pub struct CatRepositoryPostgres {
    db: Database,
}
impl CatRepositoryPostgres {
    pub fn new(db: Database) -> Self {
        Self { db }
    }
}
fn infrastructure(error: sqlx::Error) -> Error {
    Error::Infrastructure(Box::new(error))
}

#[async_trait]
impl CatRepository for CatRepositoryPostgres {
    async fn save(&self, cat: &Cat) -> Result<(), Error> {
        // Record the original database exception, then translate *all* 23505
        // violations, including primary-key conflicts, exactly like TS.
        repository_span("postgresql", "db.cats.save", "INSERT", async {
            sqlx::query!(
                "INSERT INTO cats (id, name, created_at) VALUES ($1::text::uuid, $2, $3)",
                cat.id,
                cat.name,
                cat.created_at
            )
            .execute(&self.db)
            .await
            .map(|_| ())
        })
        .await
        .map_err(|error| {
            if error
                .as_database_error()
                .is_some_and(|e| e.code().as_deref() == Some("23505"))
            {
                CatAlreadyExistsError {
                    cat_name: cat.name.clone(),
                }
                .into()
            } else {
                infrastructure(error)
            }
        })
    }
    async fn find_by_id(&self, id: &str) -> Result<Option<Cat>, Error> {
        repository_span("postgresql", "db.cats.findById", "SELECT", async {
            let row = sqlx::query!(
                "SELECT id, name, created_at FROM cats WHERE id = $1::text::uuid",
                id
            )
            .fetch_optional(&self.db)
            .await?;
            Ok::<_, sqlx::Error>(row.map(|row| Cat {
                id: row.id.to_string(),
                name: row.name,
                created_at: row.created_at,
            }))
        })
        .await
        .map_err(infrastructure)
    }
    async fn find_by_name(&self, name: &str) -> Result<Option<Cat>, Error> {
        repository_span("postgresql", "db.cats.findByName", "SELECT", async {
            let row = sqlx::query!(
                "SELECT id, name, created_at FROM cats WHERE name = $1",
                name
            )
            .fetch_optional(&self.db)
            .await?;
            Ok::<_, sqlx::Error>(row.map(|row| Cat {
                id: row.id.to_string(),
                name: row.name,
                created_at: row.created_at,
            }))
        })
        .await
        .map_err(infrastructure)
    }
    async fn delete_by_id(&self, id: &str) -> Result<bool, Error> {
        repository_span("postgresql", "db.cats.deleteById", "DELETE", async {
            sqlx::query!("DELETE FROM cats WHERE id = $1::text::uuid", id)
                .execute(&self.db)
                .await
                .map(|r| r.rows_affected() > 0)
        })
        .await
        .map_err(infrastructure)
    }
}

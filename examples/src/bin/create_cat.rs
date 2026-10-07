use frame::{
    CatRepository, ConsoleLogger, CreateCatDeps, CreateCatInput, Observability, create_cat,
    noop_tracer,
};
use frame_examples::{clock, test_db::TestDatabase};
use frame_postgres::CatRepositoryPostgres;
use std::sync::Arc;

#[tokio::main]
async fn main() {
    let db = TestDatabase::new().await;
    let repo = CatRepositoryPostgres::new(db.db.clone());
    let obs = Observability {
        logger: Arc::new(ConsoleLogger),
        tracer: noop_tracer(),
    };
    let cat = create_cat(
        CreateCatDeps {
            cat_repository: &repo,
            clock: &clock,
            observability: &obs,
        },
        CreateCatInput {
            id: uuid::Uuid::new_v4().to_string(),
            name: "Whiskers".into(),
        },
    )
    .await
    .unwrap();
    assert_eq!(repo.find_by_id(&cat.id).await.unwrap(), Some(cat.clone()));
    assert!(repo.delete_by_id(&cat.id).await.unwrap());
    assert_eq!(repo.find_by_id(&cat.id).await.unwrap(), None);
    println!("create → fetch → delete → absent: {}", cat.id);
    db.teardown().await;
}

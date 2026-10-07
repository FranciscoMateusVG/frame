#[path = "helpers/cat_repository_conformance.rs"]
mod cat_repository_conformance;
#[path = "integration/create_cat.rs"]
mod create_cat;
#[path = "integration/http.rs"]
mod http;
#[path = "integration/migration.rs"]
mod migration;

#[tokio::test]
async fn postgres_repository_conformance_and_concurrency() {
    use frame::{CatRepository, Error};
    use frame_examples::test_db::TestDatabase;
    let obs = frame_testing::TestObservability::new();
    let db = TestDatabase::new().await;
    let repo = frame_postgres::CatRepositoryPostgres::new(db.db.clone());
    cat_repository_conformance::run(&repo, &obs, "postgresql").await;
    db.reset().await;
    let a = cat_repository_conformance::make_cat("ConcurrentCat");
    let b = cat_repository_conformance::make_cat("ConcurrentCat");
    let (a, b) = tokio::join!(repo.save(&a), repo.save(&b));
    let results = [a, b];
    assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
    assert_eq!(
        results
            .iter()
            .filter(|r| matches!(r, Err(Error::CatAlreadyExists(_))))
            .count(),
        1
    );
    db.reset().await;
    let mut cat = cat_repository_conformance::make_cat("Original");
    repo.save(&cat).await.unwrap();
    cat.name = "NewName".into();
    assert!(matches!(
        repo.save(&cat).await,
        Err(Error::CatAlreadyExists(_))
    ));
    // Non-unique SQL failures remain infrastructure errors and record spans.
    assert!(matches!(
        repo.find_by_id("invalid").await,
        Err(Error::Infrastructure(_))
    ));
    assert!(matches!(
        repo.delete_by_id("invalid").await,
        Err(Error::Infrastructure(_))
    ));
    cat.id = "invalid".into();
    assert!(matches!(
        repo.save(&cat).await,
        Err(Error::Infrastructure(_))
    ));
    db.teardown().await;
}

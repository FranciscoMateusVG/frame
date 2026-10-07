use frame_examples::test_db::TestDatabase;
use frame_postgres::MIGRATOR;
#[tokio::test]
async fn migration_up_and_down_changes_real_schema() {
    let db = TestDatabase::new().await;
    let exists = || {
        sqlx::query_scalar::<_, bool>("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'cats')").fetch_one(&db.db)
    };
    assert!(exists().await.unwrap());
    MIGRATOR.undo(&db.db, 0).await.unwrap();
    assert!(!exists().await.unwrap());
    MIGRATOR.run(&db.db).await.unwrap();
    assert!(exists().await.unwrap());
    db.teardown().await;
}

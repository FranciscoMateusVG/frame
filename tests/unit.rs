#[path = "unit/cat_domain.rs"]
mod cat_domain;
#[path = "unit/cat_property.rs"]
mod cat_property;
#[path = "helpers/cat_repository_conformance.rs"]
mod cat_repository_conformance;
#[path = "unit/logger.rs"]
mod logger;
#[path = "unit/otel_logger.rs"]
mod otel_logger;

#[tokio::test]
async fn memory_repository_conformance() {
    let obs = frame_testing::TestObservability::new();
    cat_repository_conformance::run(
        &frame_memory::CatRepositoryMemory::default(),
        &obs,
        "memory",
    )
    .await;
}

#[tokio::test]
async fn memory_preserves_ts_same_id_overwrite_quirk() {
    use frame::CatRepository;
    let _obs = frame_testing::TestObservability::new();
    let repo = frame_memory::CatRepositoryMemory::default();
    let mut cat = cat_repository_conformance::make_cat("Before");
    repo.save(&cat).await.unwrap();
    cat.name = "After".into();
    repo.save(&cat).await.unwrap();
    assert_eq!(repo.find_by_id(&cat.id).await.unwrap(), Some(cat));
    assert_eq!(repo.find_by_name("Before").await.unwrap(), None);
}

#[test]
fn consumer_observability_helper_supports_explicit_shutdown_before_drop() {
    use frame::opentelemetry::{global, trace::Tracer};
    let obs = frame_testing::TestObservability::new();
    obs.reset();
    assert!(obs.get_spans().is_empty());
    obs.shutdown();
    drop(obs);
    let next = frame_testing::TestObservability::new();
    drop(global::tracer("new-consumer").start("next.fixture"));
    assert_eq!(next.get_spans().len(), 1);
}

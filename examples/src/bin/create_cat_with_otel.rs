use frame::{
    CatRepository, ConsoleLogger, CreateCatDeps, CreateCatInput, Observability, create_cat,
};
use frame_examples::{clock, test_db::TestDatabase};
use frame_postgres::CatRepositoryPostgres;
use opentelemetry::global;
use opentelemetry_sdk::trace::{InMemorySpanExporter, SdkTracerProvider};
use std::sync::Arc;

#[tokio::main]
async fn main() {
    // Consumer-owned SDK setup. The library only knows the API.
    let exporter = InMemorySpanExporter::default();
    let provider = SdkTracerProvider::builder()
        .with_simple_exporter(exporter.clone())
        .build();
    global::set_tracer_provider(provider.clone());
    let db = TestDatabase::new().await;
    let repo = CatRepositoryPostgres::new(db.db.clone());
    let obs = Observability {
        logger: Arc::new(ConsoleLogger),
        tracer: global::tracer("frame-example"),
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
    provider.force_flush().unwrap();
    let spans = exporter.get_finished_spans().unwrap();
    let parent = spans.iter().find(|s| s.name == "createCat").unwrap();
    let child = spans.iter().find(|s| s.name == "db.cats.save").unwrap();
    assert_eq!(child.parent_span_id, parent.span_context.span_id());
    assert_eq!(
        child.span_context.trace_id(),
        parent.span_context.trace_id()
    );
    for span in spans {
        println!(
            "{} trace={} span={} parent={} status={:?}",
            span.name,
            span.span_context.trace_id(),
            span.span_context.span_id(),
            span.parent_span_id,
            span.status
        );
    }
    provider.shutdown().unwrap();
    db.teardown().await;
}

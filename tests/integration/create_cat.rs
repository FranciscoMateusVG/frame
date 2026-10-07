use frame::{
    CatRepository, CreateCatDeps, CreateCatInput, Error, LogAttributes, LogLevel, Logger,
    create_cat,
};
use frame_examples::test_db::TestDatabase;
use frame_postgres::CatRepositoryPostgres;
use frame_testing::TestObservability;
use opentelemetry::{Value, trace::Status};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct CapturedLogger(Mutex<Vec<(LogLevel, String, LogAttributes)>>);
impl Logger for CapturedLogger {
    fn log(&self, level: LogLevel, message: &str, attrs: Option<&LogAttributes>) {
        self.0
            .lock()
            .unwrap()
            .push((level, message.into(), attrs.cloned().unwrap_or_default()));
    }
}
fn input(name: &str) -> CreateCatInput {
    CreateCatInput {
        id: uuid::Uuid::new_v4().to_string(),
        name: name.into(),
    }
}

#[tokio::test]
async fn create_cat_real_postgres_behavior_and_observability() {
    let mut obs = TestObservability::new();
    let logger = Arc::new(CapturedLogger::default());
    obs.observability.logger = logger.clone();
    let db = TestDatabase::new().await;
    let repo = CatRepositoryPostgres::new(db.db.clone());
    let fixed_date = "2026-01-15T12:00:00Z".parse().unwrap();
    let clock = || fixed_date;
    let deps = || CreateCatDeps {
        cat_repository: &repo,
        clock: &clock,
        observability: &obs.observability,
    };
    // Six happy-path TS scenarios (return, clock, both lookups, trim, max).
    let original = input("Whiskers");
    let cat = create_cat(deps(), original.clone()).await.unwrap();
    assert_eq!(cat.id, original.id);
    assert_eq!(cat.name, "Whiskers");
    assert_eq!(cat.created_at, fixed_date);
    assert_eq!(repo.find_by_id(&cat.id).await.unwrap(), Some(cat.clone()));
    assert_eq!(repo.find_by_name("Whiskers").await.unwrap(), Some(cat));
    db.reset().await;
    let trimmed = create_cat(deps(), input("  Whiskers  ")).await.unwrap();
    assert_eq!(trimmed.name, "Whiskers");
    assert_eq!(
        create_cat(deps(), input(&"a".repeat(100)))
            .await
            .unwrap()
            .name
            .len(),
        100
    );
    // Four invalid input cases, called directly rather than through HTTP.
    for invalid in [
        input(""),
        input(&"a".repeat(101)),
        CreateCatInput {
            id: "not-a-uuid".into(),
            name: "Valid Name".into(),
        },
        input("   "),
    ] {
        obs.reset();
        let error = create_cat(deps(), invalid).await.unwrap_err();
        assert!(matches!(error, Error::InvalidCatName(_)));
        assert_eq!(error.code(), Some("INVALID_CAT_NAME"));
        assert!(error.to_string().starts_with("Invalid cat name:"));
        let spans = obs.get_spans();
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].name, "createCat");
        assert!(matches!(spans[0].status, Status::Error { .. }));
        assert!(spans[0].events.iter().any(|e| e.name == "exception"));
    }
    db.reset().await;
    create_cat(deps(), input("OnlyOne")).await.unwrap();
    assert!(matches!(
        create_cat(deps(), input("OnlyOne")).await,
        Err(Error::CatAlreadyExists(_))
    ));
    create_cat(deps(), input("Cat A")).await.unwrap();
    assert_eq!(
        create_cat(deps(), input("Cat B")).await.unwrap().name,
        "Cat B"
    );
    let first = input("Persistent");
    create_cat(deps(), first.clone()).await.unwrap();
    let retry = input("Persistent");
    assert_ne!(first.id, retry.id);
    assert!(matches!(
        create_cat(deps(), retry).await,
        Err(Error::CatAlreadyExists(_))
    ));
    // Parent/child relationship and no raw-name span attribute.
    obs.reset();
    logger.0.lock().unwrap().clear();
    let cat = create_cat(deps(), input("SpanCat")).await.unwrap();
    let spans = obs.get_spans();
    assert_eq!(spans.len(), 2);
    let parent = spans.iter().find(|s| s.name == "createCat").unwrap();
    let child = spans.iter().find(|s| s.name == "db.cats.save").unwrap();
    assert_eq!(parent.status, Status::Ok);
    assert_eq!(child.parent_span_id, parent.span_context.span_id());
    assert_eq!(
        child.span_context.trace_id(),
        parent.span_context.trace_id()
    );
    assert!(
        parent
            .attributes
            .iter()
            .any(|a| a.key.as_str() == "cat.name.length" && a.value == Value::I64(7))
    );
    assert!(
        parent
            .attributes
            .iter()
            .any(|a| a.key.as_str() == "cat.id" && a.value == Value::from(cat.id.clone()))
    );
    assert!(
        !parent
            .attributes
            .iter()
            .any(|a| a.value == Value::from("SpanCat"))
    );
    let logs = logger.0.lock().unwrap().clone();
    assert_eq!(logs.len(), 1);
    assert_eq!(logs[0].0, LogLevel::Info);
    assert_eq!(logs[0].1, "cat.created");
    assert_eq!(logs[0].2["catId"], cat.id);
    assert_eq!(logs[0].2["nameLength"], 7);
    obs.reset();
    logger.0.lock().unwrap().clear();
    let error = create_cat(deps(), input("SpanCat")).await.unwrap_err();
    assert_eq!(error.code(), Some("CAT_ALREADY_EXISTS"));
    assert_eq!(
        error.to_string(),
        "A cat with the name \"SpanCat\" already exists."
    );
    for name in ["createCat", "db.cats.save"] {
        let spans = obs.get_spans();
        let span = spans.iter().find(|s| s.name == name).unwrap();
        assert!(matches!(span.status, Status::Error { .. }));
        assert!(span.events.iter().any(|e| e.name == "exception"));
    }
    assert!(logger.0.lock().unwrap().is_empty());
    println!("all 16 TS createCat scenarios passed against real Postgres");
    db.teardown().await;
}

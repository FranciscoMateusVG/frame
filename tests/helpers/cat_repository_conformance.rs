use frame::{Cat, CatRepository, Error};
use frame_testing::TestObservability;
use opentelemetry::{Value, trace::Status};

pub fn make_cat(name: &str) -> Cat {
    Cat {
        id: uuid::Uuid::new_v4().to_string(),
        name: name.into(),
        created_at: "2026-01-15T12:00:00Z".parse().unwrap(),
    }
}

/// Same 12 TS conformance scenarios, shared verbatim by both implementations.
/// Unique names + delete keep scenarios independent without adapter-specific calls.
pub async fn run(repo: &dyn CatRepository, obs: &TestObservability, system: &'static str) {
    let cat = make_cat("Whiskers");
    repo.save(&cat).await.unwrap();
    assert_eq!(repo.find_by_id(&cat.id).await.unwrap(), Some(cat.clone()));
    let luna = make_cat("Luna");
    repo.save(&luna).await.unwrap();
    assert_eq!(repo.find_by_name("Luna").await.unwrap(), Some(luna));
    assert_eq!(
        repo.find_by_id(&uuid::Uuid::new_v4().to_string())
            .await
            .unwrap(),
        None
    );
    assert_eq!(repo.find_by_name("Ghost").await.unwrap(), None);
    assert!(repo.delete_by_id(&cat.id).await.unwrap());
    assert_eq!(repo.find_by_id(&cat.id).await.unwrap(), None);
    assert!(
        !repo
            .delete_by_id(&uuid::Uuid::new_v4().to_string())
            .await
            .unwrap()
    );
    repo.save(&make_cat("DuplicateCat")).await.unwrap();
    assert!(matches!(
        repo.save(&make_cat("DuplicateCat")).await,
        Err(Error::CatAlreadyExists(_))
    ));

    obs.reset();
    repo.save(&make_cat("SpanCat")).await.unwrap();
    repo.find_by_id(&uuid::Uuid::new_v4().to_string())
        .await
        .unwrap();
    repo.find_by_name("Ghost").await.unwrap();
    repo.delete_by_id(&uuid::Uuid::new_v4().to_string())
        .await
        .unwrap();
    let spans = obs.get_spans();
    assert_eq!(spans.len(), 4);
    for (name, operation) in [
        ("save", "INSERT"),
        ("findById", "SELECT"),
        ("findByName", "SELECT"),
        ("deleteById", "DELETE"),
    ] {
        let span = spans
            .iter()
            .find(|s| s.name == format!("db.cats.{name}"))
            .unwrap();
        assert_eq!(span.status, Status::Ok);
        for (key, value) in [
            ("db.system", system),
            ("db.operation.name", operation),
            ("db.collection.name", "cats"),
        ] {
            assert!(
                span.attributes
                    .iter()
                    .any(|a| a.key.as_str() == key && a.value == Value::from(value))
            );
        }
    }
    obs.reset();
    assert!(repo.save(&make_cat("SpanCat")).await.is_err());
    let spans = obs.get_spans();
    assert_eq!(spans.len(), 1);
    assert!(matches!(spans[0].status, Status::Error { .. }));
    assert!(spans[0].events.iter().any(|e| e.name == "exception"));
    println!("{system}: all 12 TS conformance scenarios passed");
}

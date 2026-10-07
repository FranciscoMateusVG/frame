use frame::Observability;
use frame_examples::{
    http::{Server, demonstrate},
    test_db::TestDatabase,
};
use serde_json::{Value, json};
#[tokio::test]
async fn real_http_composition_uses_postgres_and_maps_domain_errors() {
    let _obs = frame_testing::TestObservability::new();
    let db = TestDatabase::new().await;
    let server = Server::start(db.db.clone(), Observability::default()).await;
    demonstrate(&server.base_url).await;
    let client = reqwest::Client::new();
    let response = client
        .get(format!("{}/cats/{}", server.base_url, uuid::Uuid::new_v4()))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 404);
    assert_eq!(
        response.json::<Value>().await.unwrap(),
        json!({"error":"NOT_FOUND"})
    );
    for input in [json!({}), json!({"name":12}), json!({"name":null})] {
        let response = client
            .post(format!("{}/cats", server.base_url))
            .json(&input)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 400);
        assert_eq!(
            response.json::<Value>().await.unwrap()["error"],
            "INVALID_CAT_NAME"
        );
    }
    // DB errors aren't disguised as 400/409.
    let response = client
        .get(format!("{}/cats/invalid", server.base_url))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 500);
    server.shutdown().await;
    db.teardown().await;
}

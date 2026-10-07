use frame::{ConsoleLogger, Observability, noop_tracer};
use frame_examples::{
    http::{Server, demonstrate},
    test_db::TestDatabase,
};
use std::sync::Arc;

#[tokio::main]
async fn main() {
    let db = TestDatabase::new().await;
    let obs = Observability {
        logger: Arc::new(ConsoleLogger),
        tracer: noop_tracer(),
    };
    let server = Server::start(db.db.clone(), obs).await;
    demonstrate(&server.base_url).await;
    server.shutdown().await;
    db.teardown().await;
}

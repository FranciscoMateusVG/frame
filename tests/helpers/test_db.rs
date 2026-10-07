use frame_postgres::{Database, MIGRATOR, create_database};
use testcontainers::{
    ContainerAsync, GenericImage, ImageExt,
    core::{IntoContainerPort, WaitFor},
    runners::AsyncRunner,
};

pub struct TestDatabase {
    pub db: Database,
    pub connection_uri: String,
    container: ContainerAsync<GenericImage>,
}
impl TestDatabase {
    pub async fn new() -> Self {
        let container = GenericImage::new("postgres", "16")
            .with_exposed_port(5432.tcp())
            .with_wait_for(WaitFor::message_on_stderr(
                "database system is ready to accept connections",
            ))
            .with_env_var("POSTGRES_USER", "frame")
            .with_env_var("POSTGRES_PASSWORD", "frame")
            .with_env_var("POSTGRES_DB", "frame")
            .start()
            .await
            .expect("Docker must be running for real Postgres tests");
        let connection_uri = format!(
            "postgresql://frame:frame@{}:{}/frame",
            container.get_host().await.unwrap(),
            container.get_host_port_ipv4(5432).await.unwrap()
        );
        let db = create_database(&connection_uri).await.unwrap();
        MIGRATOR.run(&db).await.unwrap();
        Self {
            db,
            connection_uri,
            container,
        }
    }
    pub async fn reset(&self) {
        sqlx::query("DELETE FROM cats")
            .execute(&self.db)
            .await
            .unwrap();
    }
    pub async fn teardown(self) {
        self.db.close().await;
        self.container.stop().await.unwrap();
    }
}

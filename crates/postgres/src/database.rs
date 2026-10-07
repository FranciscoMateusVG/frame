pub type Database = sqlx::PgPool;
pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("../../migrations");

pub async fn create_database(connection_string: &str) -> Result<Database, sqlx::Error> {
    sqlx::postgres::PgPoolOptions::new()
        .connect(connection_string)
        .await
}

mod architecture;
mod coverage;
use std::{collections::BTreeMap, fs, path::Path, process::Command};
use testcontainers::{
    GenericImage, ImageExt,
    core::{IntoContainerPort, WaitFor},
    runners::AsyncRunner,
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
fn run(command: &mut Command) -> Result<()> {
    println!("+ {command:?}");
    if !command.status()?.success() {
        return Err(format!("command failed: {command:?}").into());
    }
    Ok(())
}
#[tokio::main]
async fn main() -> Result<()> {
    let current = std::env::current_dir()?;
    let root = current
        .ancestors()
        .find(|p| fs::read_to_string(p.join("Cargo.toml")).is_ok_and(|s| s.contains("[workspace]")))
        .ok_or("run inside the Frame workspace")?
        .to_owned();
    std::env::set_current_dir(&root)?;
    let command = std::env::args().nth(1).unwrap_or_else(|| "check".into());
    match command.as_str() {
        "architecture" => architecture::check(),
        "verify-hooks" => architecture::verify_hooks(),
        "install-hooks" => architecture::install_hooks(),
        "coverage" => coverage::check(),
        "codegen" => codegen(&root, true).await,
        "check-codegen" => codegen(&root, false).await,
        "migrate" => {
            let url = std::env::var("DATABASE_URL")
                .unwrap_or_else(|_| "postgresql://frame:frame@localhost:54320/frame".into());
            let db = sqlx::PgPool::connect(&url).await?;
            sqlx::migrate::Migrator::new(root.join("migrations"))
                .await?
                .run(&db)
                .await?;
            db.close().await;
            Ok(())
        }
        "check" => {
            let start = std::time::Instant::now();
            run(Command::new("cargo").args(["fmt", "--all", "--", "--check"]))?;
            architecture::check()?;
            run(Command::new("cargo").args([
                "clippy",
                "--workspace",
                "--all-targets",
                "--locked",
                "--",
                "-D",
                "warnings",
            ]))?;
            run(Command::new("cargo").args(["check", "--workspace", "--all-targets", "--locked"]))?;
            codegen(&root, false).await?;
            coverage::check()?;
            for example in ["create_cat", "create_cat_with_otel", "create_cat_axum"] {
                run(Command::new("cargo").args([
                    "run",
                    "--locked",
                    "-p",
                    "frame-examples",
                    "--bin",
                    example,
                ]))?;
            }
            architecture::verify_hooks()?;
            println!("CHECK PASSED in {:.2}s", start.elapsed().as_secs_f64());
            Ok(())
        }
        _ => Err(format!("unknown xtask command: {command}").into()),
    }
}
fn json_files(dir: &Path) -> Result<BTreeMap<String, serde_json::Value>> {
    let mut files = BTreeMap::new();
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        if path.extension().is_some_and(|e| e == "json") {
            files.insert(
                path.file_name().unwrap().to_str().unwrap().to_owned(),
                serde_json::from_slice(&fs::read(path)?)?,
            );
        }
    }
    Ok(files)
}
async fn codegen(root: &Path, write: bool) -> Result<()> {
    let container = GenericImage::new("postgres", "16")
        .with_exposed_port(5432.tcp())
        .with_wait_for(WaitFor::message_on_stderr(
            "database system is ready to accept connections",
        ))
        .with_env_var("POSTGRES_USER", "frame")
        .with_env_var("POSTGRES_PASSWORD", "frame")
        .with_env_var("POSTGRES_DB", "frame")
        .start()
        .await?;
    let result = async {
        let url = format!("postgresql://frame:frame@{}:{}/frame", container.get_host().await?, container.get_host_port_ipv4(5432).await?);
        let db = sqlx::PgPool::connect(&url).await?;
        sqlx::migrate::Migrator::new(root.join("migrations")).await?.run(&db).await?;
        let output = root.join("target/sqlx-drift");
        if output.exists() { fs::remove_dir_all(&output)?; }
        fs::create_dir_all(&output)?;
        // Force macro expansion against the migrated database, never stale cache.
        run(Command::new("cargo").args(["clean", "-p", "frame-postgres"]))?;
        run(Command::new("cargo").args(["check", "-p", "frame-postgres", "--locked"]).env("SQLX_OFFLINE", "false").env("DATABASE_URL", &url).env("SQLX_OFFLINE_DIR", &output))?;
        // query! caches only queried columns; include the complete schema too so
        // an added unused column cannot silently evade the Kysely-equivalent gate.
        let schema: Vec<serde_json::Value> = sqlx::query_scalar("SELECT json_build_object('table',table_name,'column',column_name,'type',udt_name,'nullable',is_nullable,'default',column_default,'length',character_maximum_length)::jsonb FROM information_schema.columns WHERE table_schema='public' AND table_name <> '_sqlx_migrations' ORDER BY table_name,ordinal_position").fetch_all(&db).await?;
        fs::write(output.join("schema.json"), format!("{}\n", serde_json::to_string_pretty(&schema)?))?;
        let generated = json_files(&output)?;
        if generated.len() < 2 { return Err("no SQLx query metadata generated".into()); }
        if write {
            for entry in fs::read_dir(root.join(".sqlx"))? { let path = entry?.path(); if path.extension().is_some_and(|e| e == "json") { fs::remove_file(path)?; } }
            for name in generated.keys() { fs::copy(output.join(name), root.join(".sqlx").join(name))?; }
            println!("SQLx metadata + complete schema regenerated");
        } else if generated != json_files(&root.join(".sqlx"))? {
            return Err("codegen drift: run cargo xtask codegen and commit .sqlx/".into());
        } else { println!("codegen drift: PASS (live PostgreSQL 16)"); }
        db.close().await;
        Ok(())
    }.await;
    container.stop().await?;
    result
}

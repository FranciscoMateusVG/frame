//! Inspect resolved Cargo dependency declarations plus parsed Rust syntax.
//! Crate boundaries are enforced by Cargo; this prevents changing those walls.
use crate::{Result, run};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    process::Command,
};
use syn::{UseTree, visit::Visit};

const CRATES: &[&str] = &[
    "domain",
    "errors",
    "port",
    "observability",
    "use-cases",
    "memory",
    "postgres",
    "frame",
    "testing",
    "portal-domain",
    "portal-port",
    "portal-use-cases",
    "portal-memory",
    "portal-hono",
    "portal-web",
];
fn allowed(name: &str) -> &[&str] {
    match name {
        "frame-domain" => &["chrono", "serde", "serde_json"],
        "frame-errors" => &["thiserror"],
        "frame-port" => &["frame-domain", "frame-errors", "async-trait"],
        "frame-observability" => &["opentelemetry", "chrono", "serde_json"],
        "frame-use-cases" => &[
            "frame-domain",
            "frame-errors",
            "frame-port",
            "frame-observability",
            "opentelemetry",
        ],
        "frame-memory" => &[
            "frame-domain",
            "frame-errors",
            "frame-port",
            "frame-observability",
            "async-trait",
        ],
        "frame-postgres" => &[
            "frame-domain",
            "frame-errors",
            "frame-port",
            "frame-observability",
            "opentelemetry",
            "async-trait",
            "sqlx",
            "uuid",
        ],
        "frame" => &[
            "frame-domain",
            "frame-errors",
            "frame-port",
            "frame-observability",
            "frame-use-cases",
            "frame-postgres",
        ],
        "frame-testing" => &["frame-observability", "opentelemetry", "opentelemetry_sdk"],
        // Print portal (BFF): pure domain → port → use cases; adapters and
        // the web composition root are leaves. No database, no blob store.
        "frame-portal-domain" => &["chrono", "serde", "serde_json"],
        "frame-portal-port" => &[
            "frame-portal-domain",
            "async-trait",
            "bytes",
            "futures-util",
        ],
        "frame-portal-use-cases" => &[
            "frame-portal-domain",
            "frame-portal-port",
            "frame-observability",
            "opentelemetry",
            "chrono",
            "serde_json",
            "sha2",
            "subtle",
        ],
        "frame-portal-memory" => &[
            "frame-portal-domain",
            "frame-portal-port",
            "frame-observability",
            "opentelemetry",
            "async-trait",
            "bytes",
            "chrono",
            "futures-util",
            "sha2",
            "uuid",
        ],
        "frame-portal-hono" => &[
            "frame-portal-domain",
            "frame-portal-port",
            "frame-observability",
            "opentelemetry",
            "async-trait",
            "bytes",
            "futures-util",
            "reqwest",
            "serde",
            "serde_json",
        ],
        "frame-portal-web" => &[
            "frame-portal-domain",
            "frame-portal-port",
            "frame-portal-use-cases",
            "frame-portal-hono",
            "frame-observability",
            "axum",
            "maud",
            "tokio",
            "chrono",
            "serde",
            "serde_json",
            "getrandom",
            "uuid",
        ],
        _ => &[],
    }
}
fn snake(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}
fn flat_rs(path: &Path) -> Result<Vec<PathBuf>> {
    let mut files = vec![];
    for entry in fs::read_dir(path)? {
        let path = entry?.path();
        if !path.is_file()
            || path.extension().and_then(|s| s.to_str()) != Some("rs")
            || !snake(path.file_stem().unwrap().to_str().unwrap())
        {
            return Err(format!(
                "structure violation: {} (expected flat snake_case.rs)",
                path.display()
            )
            .into());
        }
        files.push(path);
    }
    Ok(files)
}
pub fn check() -> Result<()> {
    for entry in fs::read_dir("crates")? {
        let path = entry?.path();
        if !CRATES.contains(&path.file_name().unwrap().to_str().unwrap()) {
            return Err(format!("unmodeled crate {}", path.display()).into());
        }
        for entry in fs::read_dir(&path)? {
            let entry = entry?;
            if !(["Cargo.toml", "src"].contains(&entry.file_name().to_str().unwrap())
                || path.ends_with("postgres") && entry.file_name() == "build.rs")
            {
                return Err(format!("structure violation: {}", entry.path().display()).into());
            }
        }
        check_sources(&path)?;
    }
    for path in [
        "tests/unit",
        "tests/integration",
        "tests/helpers",
        "examples/src/bin",
        "xtask/src",
    ] {
        flat_rs(Path::new(path))?;
    }
    for (path, names) in [
        (
            "tests",
            &[
                "Cargo.toml",
                "unit.rs",
                "integration.rs",
                "portal_unit.rs",
                "portal_integration.rs",
                "unit",
                "integration",
                "helpers",
            ][..],
        ),
        ("examples", &["Cargo.toml", "src"][..]),
        ("examples/src", &["lib.rs", "http.rs", "bin"][..]),
    ] {
        for entry in fs::read_dir(path)? {
            let entry = entry?;
            if !names.contains(&entry.file_name().to_str().unwrap()) {
                return Err(format!("structure violation: {}", entry.path().display()).into());
            }
        }
    }
    for entry in fs::read_dir("migrations")? {
        let path = entry?.path();
        let name = path.file_name().unwrap().to_str().unwrap();
        let stem = name
            .strip_suffix(".up.sql")
            .or_else(|| name.strip_suffix(".down.sql"))
            .ok_or("migration must be .up.sql/.down.sql")?;
        let (order, name) = stem
            .split_once('_')
            .ok_or("migration needs numeric order prefix")?;
        if order.is_empty() || !order.bytes().all(|b| b.is_ascii_digit()) || !snake(name) {
            return Err("migration filename violation".into());
        }
    }
    if Path::new("scripts").exists()
        && let Some(entry) = fs::read_dir("scripts")?.next()
    {
        return Err(format!(
            "unmodeled script {}: use xtask/src",
            entry?.path().display()
        )
        .into());
    }
    let output = Command::new("cargo")
        .args(["metadata", "--no-deps", "--format-version=1", "--locked"])
        .output()?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).into_owned().into());
    }
    let metadata: Value = serde_json::from_slice(&output.stdout)?;
    for package in metadata["packages"].as_array().unwrap() {
        let name = package["name"].as_str().unwrap();
        if !name.starts_with("frame") || ["frame-specs", "frame-examples"].contains(&name) {
            continue;
        }
        for dependency in package["dependencies"].as_array().unwrap() {
            if dependency["kind"] == "dev" {
                continue;
            }
            let dep = dependency["name"].as_str().unwrap();
            if !allowed(name).contains(&dep) {
                return Err(format!("architecture violation: {name} → {dep}").into());
            }
        }
    }
    // Cargo additionally rejects package dependency cycles, missing/undeclared
    // crates, and invalid imports when check/clippy run in the canonical gate.
    println!("architecture + layout: PASS (Cargo declarations + syn AST)");
    Ok(())
}
#[derive(Default)]
struct Paths {
    paths: Vec<Vec<String>>,
}
impl<'ast> Visit<'ast> for Paths {
    fn visit_path(&mut self, path: &'ast syn::Path) {
        self.paths
            .push(path.segments.iter().map(|s| s.ident.to_string()).collect());
        syn::visit::visit_path(self, path);
    }
    fn visit_item_use(&mut self, item: &'ast syn::ItemUse) {
        use_paths(&item.tree, vec![], &mut self.paths);
    }
}
fn use_paths(tree: &UseTree, mut prefix: Vec<String>, paths: &mut Vec<Vec<String>>) {
    match tree {
        UseTree::Path(p) => {
            prefix.push(p.ident.to_string());
            use_paths(&p.tree, prefix, paths);
        }
        UseTree::Name(n) => {
            prefix.push(n.ident.to_string());
            paths.push(prefix);
        }
        UseTree::Rename(n) => {
            prefix.push(n.ident.to_string());
            paths.push(prefix);
        }
        UseTree::Glob(_) => paths.push(prefix),
        UseTree::Group(g) => {
            for item in &g.items {
                use_paths(item, prefix.clone(), paths);
            }
        }
    }
}
fn check_sources(path: &Path) -> Result<()> {
    let mut edges: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let files = flat_rs(&path.join("src"))?;
    let names: BTreeSet<_> = files
        .iter()
        .map(|p| p.file_stem().unwrap().to_str().unwrap().to_owned())
        .collect();
    for file in files {
        let source = fs::read_to_string(&file)?;
        let syntax = syn::parse_file(&source)?;
        let mut paths = Paths::default();
        paths.visit_file(&syntax);
        let name = file.file_stem().unwrap().to_str().unwrap().to_owned();
        for p in paths.paths {
            if p.is_empty() {
                continue;
            }
            if p[0] == "frame" || (p[0] == "opentelemetry_sdk" && !path.ends_with("testing")) {
                return Err(format!(
                    "forbidden internal facade/SDK import in {}: {}",
                    file.display(),
                    p.join("::")
                )
                .into());
            }
            let domain = if path.ends_with("domain") {
                Some("frame_domain")
            } else if path.ends_with("portal-domain") {
                Some("frame_portal_domain")
            } else {
                None
            };
            if let Some(own) = domain
                && ((p[0].starts_with("frame_") && p[0] != own)
                    || (["std", "core"].contains(&p[0].as_str())
                        && p.get(1).is_some_and(|s| {
                            ["fs", "net", "io", "process", "thread", "time"].contains(&s.as_str())
                        })))
            {
                return Err(format!("domain purity violation: {}", p.join("::")).into());
            }
            if path.ends_with("use-cases")
                && ["frame_memory", "frame_postgres"].contains(&p[0].as_str())
            {
                return Err("use-case imports concrete adapter".into());
            }
            if path.ends_with("portal-use-cases")
                && ["frame_portal_memory", "frame_portal_hono"].contains(&p[0].as_str())
            {
                return Err("portal use case imports concrete adapter".into());
            }
            // The production composition root never wires the in-memory fake.
            if path.ends_with("portal-web") && p[0] == "frame_portal_memory" {
                return Err("portal web imports the in-memory upstream fake".into());
            }
            if name != "lib" {
                let module = if ["crate", "super", "self"].contains(&p[0].as_str()) {
                    p.get(1)
                } else {
                    p.first()
                };
                if let Some(module) = module.filter(|m| names.contains(*m) && *m != &name) {
                    edges
                        .entry(name.clone())
                        .or_default()
                        .insert(module.clone());
                }
            }
        }
    }
    fn visit(
        node: &str,
        edges: &BTreeMap<String, BTreeSet<String>>,
        active: &mut BTreeSet<String>,
        done: &mut BTreeSet<String>,
    ) -> Result<()> {
        if active.contains(node) {
            return Err(format!("module cycle at {node}").into());
        }
        if done.contains(node) {
            return Ok(());
        }
        active.insert(node.into());
        for target in edges.get(node).into_iter().flatten() {
            visit(target, edges, active, done)?;
        }
        active.remove(node);
        done.insert(node.into());
        Ok(())
    }
    let mut done = BTreeSet::new();
    for name in edges.keys() {
        visit(name, &edges, &mut BTreeSet::new(), &mut done)?;
    }
    Ok(())
}

pub fn verify_hooks() -> Result<()> {
    for (name, required) in [
        ("pre-commit", "cargo fmt --all -- --check"),
        ("pre-push", "cargo xtask check"),
    ] {
        let body = fs::read_to_string(format!(".husky/{name}"))?;
        if !body.contains(required) {
            return Err(format!("hook {name} must execute {required}").into());
        }
        let wrapper = fs::read_to_string(format!(".husky/_/{name}"))?;
        if !wrapper.contains(&format!("../{name}")) {
            return Err(format!("hook wrapper {name} missing delegation").into());
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for path in [format!(".husky/{name}"), format!(".husky/_/{name}")] {
                if fs::metadata(path)?.permissions().mode() & 0o111 == 0 {
                    return Err("hook not executable".into());
                }
            }
        }
    }
    println!("hooks: PASS (readable, executable, correct commands)");
    Ok(())
}
pub fn install_hooks() -> Result<()> {
    run(Command::new("git").args(["config", "core.hooksPath", ".husky/_"]))
}

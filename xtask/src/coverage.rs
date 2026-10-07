use crate::{Result, run};
use serde_json::Value;
use std::{
    fs,
    path::PathBuf,
    process::{Command, Stdio},
};

fn llvm_tool(name: &str, variable: &str) -> Result<PathBuf> {
    if let Some(path) = std::env::var_os(variable) {
        return Ok(path.into());
    }
    let sysroot = Command::new("rustc")
        .args(["--print", "sysroot"])
        .output()?;
    let version = Command::new("rustc").arg("-vV").output()?;
    let version = String::from_utf8(version.stdout)?;
    let host = version
        .lines()
        .find_map(|s| s.strip_prefix("host: "))
        .ok_or("rustc host missing")?;
    let llvm = version
        .lines()
        .find_map(|s| s.strip_prefix("LLVM version: "))
        .ok_or("rustc LLVM version missing")?
        .split('.')
        .next()
        .unwrap();
    for candidate in [
        PathBuf::from(String::from_utf8(sysroot.stdout)?.trim())
            .join(format!("lib/rustlib/{host}/bin/{name}")),
        PathBuf::from(format!("/opt/homebrew/opt/llvm@{llvm}/bin/{name}")),
    ] {
        if candidate.is_file() {
            return Ok(candidate);
        }
    }
    Ok(name.into())
}
pub fn check() -> Result<()> {
    let root = std::env::current_dir()?;
    let dir = root.join("target/coverage");
    let raw = dir.join("raw");
    if raw.exists() {
        fs::remove_dir_all(&raw)?;
    }
    fs::create_dir_all(&raw)?;
    println!("coverage: full workspace tests with LLVM instrumentation");
    let output = Command::new("cargo")
        .args(["test", "--workspace", "--locked", "--message-format=json"])
        .env("CARGO_TARGET_DIR", &dir)
        .env("RUSTFLAGS", "-C instrument-coverage")
        .env("LLVM_PROFILE_FILE", raw.join("frame-%p-%m.profraw"))
        .stderr(Stdio::inherit())
        .output()?;
    fs::write(dir.join("test-output.log"), &output.stdout)?;
    let mut objects = vec![];
    for line in String::from_utf8(output.stdout)?.lines() {
        if let Ok(v) = serde_json::from_str::<Value>(line) {
            if v["reason"] == "compiler-artifact"
                && v["profile"]["test"] == true
                && let Some(executable) = v["executable"].as_str()
            {
                objects.push(executable.to_owned());
            }
        } else {
            println!("{line}");
        }
    }
    if !output.status.success() {
        return Err("coverage test command failed".into());
    }
    let profile = dir.join("frame.profdata");
    let mut merge = Command::new(llvm_tool("llvm-profdata", "LLVM_PROFDATA")?);
    merge.args(["merge", "-sparse"]).arg("-o").arg(&profile);
    let mut count = 0;
    for entry in fs::read_dir(&raw)? {
        let file = entry?.path();
        if file.extension().is_some_and(|e| e == "profraw") {
            merge.arg(file);
            count += 1;
        }
    }
    if count == 0 || objects.is_empty() {
        return Err("no coverage profiles or test executables produced".into());
    }
    run(&mut merge)?;
    let mut export = Command::new(llvm_tool("llvm-cov", "LLVM_COV")?);
    export
        .args(["export", "--summary-only", "--format=text"])
        .arg(format!("--instr-profile={}", profile.display()));
    for object in objects {
        export.arg("--object").arg(object);
    }
    let exported = export.output()?;
    if !exported.status.success() {
        return Err(format!(
            "llvm-cov failed: {} (install matching llvm-tools or set LLVM_COV/LLVM_PROFDATA)",
            String::from_utf8_lossy(&exported.stderr)
        )
        .into());
    }
    fs::write(dir.join("coverage.json"), &exported.stdout)?;
    let report: Value = serde_json::from_slice(&exported.stdout)?;
    for file in [
        "crates/domain/src/cat.rs",
        "crates/use-cases/src/create_cat.rs",
    ] {
        let entry = report["data"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|d| d["files"].as_array().unwrap())
            .find(|f| f["filename"].as_str().is_some_and(|s| s.ends_with(file)))
            .ok_or_else(|| format!("missing coverage for {file}"))?;
        for (metric, minimum) in [("lines", 90.0), ("functions", 90.0), ("regions", 85.0)] {
            let percent = entry["summary"][metric]["percent"]
                .as_f64()
                .ok_or("coverage percentage missing")?;
            println!("coverage {file}: {metric} {percent:.2}% (required {minimum:.0}%)");
            if percent < minimum {
                return Err(format!("coverage threshold failed: {file} {metric}").into());
            }
        }
    }
    Ok(())
}

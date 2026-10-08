"""Small native CI orchestration: no deployment credentials are logged or persisted."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import urllib.request
from timing import breakdown

STAGES = ["install", "lint-format", "typecheck-compile", "tests", "image-build",
          "staging-deploy", "staging-smoke"]
STATE = Path(os.environ.get("TTP_STATE_DIR", ".ttp"))
RUST = str(Path.home() / ".cargo/bin/cargo")
PACKAGES = " ".join("-p frame-portal-" + name for name in
                    ["domain", "port", "use-cases", "memory", "hono", "web"])
COMMANDS = {
    "ts": {
        "install": "pnpm install --frozen-lockfile",
        "lint-format": "pnpm lint && pnpm lint:structure && pnpm depcruise",
        "typecheck-compile": "pnpm typecheck",
        "tests": "pnpm test:portal",
    },
    "rust": {
        "install": f"{RUST} fetch --locked",
        "lint-format": f"{RUST} fmt --all -- --check && {RUST} clippy --locked --all-targets {PACKAGES} -- -D warnings",
        "typecheck-compile": f"{RUST} check --locked -p frame-portal-web",
        "tests": f"{RUST} test --locked -p frame-specs --test portal_unit --test portal_integration",
    },
    "phoenix": {
        "install": "mix deps.get --check-locked",
        "lint-format": "mix lint && mix frame.lint_structure && mix frame.depcruise",
        "typecheck-compile": "MIX_ENV=test mix typecheck",
        "tests": "mix test",
    },
}


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def save(name, value):
    STATE.mkdir(parents=True, exist_ok=True)
    target = STATE / (name + ".json")
    tmp = target.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n")
    tmp.replace(target)


def load(name, default=None):
    path = STATE / (name + ".json")
    return json.loads(path.read_text()) if path.exists() else default


def variant():
    ref = os.environ.get("GITHUB_BASE_REF") or os.environ.get("GITHUB_REF_NAME", "")
    return {"portal-ts": "ts", "portal-rust": "rust", "portal-phoenix": "phoenix"}[ref]


def capture(args):
    return subprocess.check_output(args, text=True).strip()


def incluir_busy():
    # Never print arbitrary process arguments. Both existing Incluir runners are
    # distinct from actions-runner-frame, and have priority over TTP work.
    commands = capture(["ps", "-axo", "command"])
    return bool(re.search(r"/actions-runner(?:-2)?/bin/Runner[.]Worker\b", commands))


def wait_idle():
    started = now()
    deadline = time.monotonic() + 1800
    while incluir_busy():
        if time.monotonic() >= deadline:
            raise RuntimeError("Incluir priority wait exceeded")
        time.sleep(10)
    return {"started_at": started, "finished_at": now()}


def execute(args):
    """Wait directly for the process; monitor without rounding stage time to 1s."""
    stop = threading.Event()
    seen = []
    def monitor():
        while not stop.is_set():
            try:
                if incluir_busy(): seen.append(True)
            except Exception:
                seen.append(True)  # A missing contention probe cannot prove isolation.
            stop.wait(1)
    watcher = threading.Thread(target=monitor, daemon=True)
    watcher.start()
    try:
        return subprocess.run(args).returncode, seen
    finally:
        stop.set()
        watcher.join(timeout=2)


def init():
    kind = variant()
    sha = os.environ["GITHUB_SHA"]
    assert re.fullmatch(r"[0-9a-f]{40}", sha)
    assert capture(["git", "rev-parse", "HEAD"]) == sha
    versions = {
        "ts": [["node", "--version"], ["pnpm", "--version"]],
        "rust": [[str(Path.home() / ".cargo/bin/rustc"), "--version"], [RUST, "--version"]],
        "phoenix": [["elixir", "--version"], ["mix", "--version"]],
    }
    toolchains = [capture(cmd) for cmd in versions[kind]]
    cache_paths = {
        "ts": [capture(["pnpm", "store", "path"])],
        "rust": [str(Path(os.environ.get("CARGO_HOME", str(Path.home()/".cargo"))) / "registry"), str(Path(os.environ.get("CARGO_HOME", str(Path.home()/".cargo"))) / "git"), os.environ.get("CARGO_TARGET_DIR", "target")],
        "phoenix": ["deps", "_build"],
    }[kind]
    fake_sha = os.environ.get("TTP_FAKE_SHA", "")
    if os.environ["GITHUB_EVENT_NAME"] == "push":
        assert re.fullmatch(r"[0-9a-f]{40}", fake_sha), "frozen upstream revision required"
    save("context", {"schema_version": 1,
         "fake_upstream": {"source_sha": fake_sha or None,
             "fixture_sha256": "9d1ab88ca294c4a446cce579e21a538e6a78f430b45770a71022c0a344093f6d",
             "delay_ms": 0, "provenance": "pinned staging configuration; administrative readback at acceptance"}, "variant": kind, "source_sha": sha,
         "repo": os.environ["GITHUB_REPOSITORY"], "event": os.environ["GITHUB_EVENT_NAME"],
         "branch": os.environ.get("GITHUB_BASE_REF") or os.environ["GITHUB_REF_NAME"],
         "run_id": os.environ["GITHUB_RUN_ID"], "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
         "runner": os.environ["RUNNER_NAME"], "setup_at": now(), "toolchains": toolchains})
    with open(os.environ["GITHUB_OUTPUT"], "a") as out:
        out.write("variant=" + kind + "\n")
        out.write("toolchain_key=" + hashlib.sha256(json.dumps(toolchains).encode()).hexdigest()[:16] + "\n")
        out.write("cache_paths<<TTP_PATHS\n" + "\n".join(cache_paths) + "\nTTP_PATHS\n")


def run(stage):
    assert stage in STAGES
    ctx = load("context")
    try:
        admission = wait_idle()
    except Exception:
        save(stage, {"id": stage, "status": "blocked", "reason": "priority_admission_failed",
             "finished_at": now(), "external_contention": True})
        raise
    started = now()
    clock = time.monotonic()
    contention = False
    result = 1
    try:
        if stage in COMMANDS[ctx["variant"]]:
            cmd = COMMANDS[ctx["variant"]][stage]
            if ctx["variant"] == "rust":
                os.environ["RUSTC"] = str(Path.home() / ".cargo/bin/rustc")
                os.environ["RUSTDOC"] = str(Path.home() / ".cargo/bin/rustdoc")
                # cargo discovers fmt/clippy as subprocesses; CARGO_HOME is an
                # isolated cache, not the installed toolchain directory. This
                # PATH exists only in this stage process, never a login shell.
                os.environ["PATH"] = str(Path.home() / ".cargo/bin") + os.pathsep + os.environ["PATH"]
            result, seen = execute(["nice", "-n", "10", "bash", "-eo", "pipefail", "-c", cmd])
            contention = bool(seen)
        elif stage == "image-build":
            tag = f'frame-ttp-{ctx["variant"]}:{ctx["run_id"]}-{ctx["run_attempt"]}'
            result, seen = execute(["nice", "-n", "10", "docker", "build", "--platform", "linux/arm64",
                "--build-arg", "BUILD_SHA=" + ctx["source_sha"], "--label",
                "org.opencontainers.image.revision=" + ctx["source_sha"], "-t", tag, "."])
            contention = bool(seen)
            if result == 0:
                subprocess.run(["docker", "run", "--rm", "--entrypoint", "sh", tag, "-c",
                    'test -z "$(find /app -name .git -print -quit)"'], check=True)
                save("image", {"local_id": capture(["docker", "image", "inspect", tag, "--format", "{{.Id}}"]),
                     "publish": "not_performed", "platform": "linux/arm64"})
        else:
            result, seen = execute([sys.executable, "infra/ttp/staging.py", stage])
            contention = bool(seen)
    except Exception:
        result = 1
        raise
    finally:
        save(stage, {"id": stage, "started_at": started, "finished_at": now(),
             "duration_ms": round((time.monotonic() - clock) * 1000),
             "status": "success" if result == 0 else "failure", "exit_code": result,
             "admission_wait": admission, "external_contention": contention})
    return result


def resume():
    ctx = load("context")
    assert ctx["source_sha"] == os.environ["GITHUB_SHA"] == capture(["git", "rev-parse", "HEAD"])
    assert ctx["event"] == "push" and ctx["repo"] == os.environ["GITHUB_REPOSITORY"]
    assert ctx["run_id"] == os.environ["GITHUB_RUN_ID"]
    assert ctx["run_attempt"] == os.environ["GITHUB_RUN_ATTEMPT"]
    assert ctx["variant"] == variant()
    assert all(load(s)["status"] == "success" for s in STAGES[:4])
    save("checks-report", load("ttp-timings"))


def cleanup():
    # Only this run's known image tag. Never prune shared caches/images/volumes.
    ctx = load("context")
    if ctx is None: return
    assert ctx["run_id"] == os.environ["GITHUB_RUN_ID"]
    assert ctx["run_attempt"] == os.environ["GITHUB_RUN_ATTEMPT"]
    assert ctx["variant"] == variant()
    tag = f'frame-ttp-{ctx["variant"]}:{ctx["run_id"]}-{ctx["run_attempt"]}'
    exists = subprocess.run(["docker", "image", "inspect", tag], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL).returncode == 0
    if exists: subprocess.run(["docker", "image", "rm", tag], check=True)
    save("image-cleanup", {"completed_at": now(), "status": "removed" if exists else "absent"})


def report():
    data = load("context", {"schema_version": 1, "setup_failed": True})
    data["stages"] = [load(s, {"id": s, "status": "skipped"}) for s in STAGES]
    data["comparison_valid"] = not data.get("setup_failed", False) and not any(
        s.get("external_contention") for s in data["stages"])
    data["cache_hit"] = os.environ.get("TTP_CACHE_HIT", (load("checks-report") or {}).get("cache_hit", "unknown"))
    data["job_status_at_report"] = os.environ.get("TTP_JOB_STATUS")
    data["image"] = load("image")
    data["deployment"] = load("deployment")
    if (data["deployment"] or {}).get("status", "").startswith("invalidated"):
        data["comparison_valid"] = False
    data["smoke"] = load("smoke")
    data["report_at"] = now()
    # GitHub's authoritative timestamps include queue/setup separately from stages.
    try:
        url = f'https://api.github.com/repos/{os.environ["GITHUB_REPOSITORY"]}/actions/runs/{os.environ["GITHUB_RUN_ID"]}'
        headers = {"Accept": "application/vnd.github+json"}
        if os.environ.get("GH_TOKEN"):
            headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
        req = urllib.request.Request(url, headers=headers)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=20) as response:
            metadata = json.load(response)
        data["workflow_created_at"] = metadata["created_at"]
        data["workflow_started_at"] = metadata.get("run_started_at")
        jobs_url = url + "/attempts/" + os.environ["GITHUB_RUN_ATTEMPT"] + "/jobs"
        req = urllib.request.Request(jobs_url, headers=headers)
        with opener.open(req, timeout=20) as response:
            jobs = json.load(response)["jobs"]
        data["github_jobs"] = [{"name": j["name"], "started_at": j["started_at"],
            "completed_at": j["completed_at"], "steps": [
                {k: step.get(k) for k in ("name", "started_at", "completed_at", "conclusion")}
                for step in j["steps"]]} for j in jobs]
        job = next(j for j in jobs if j["name"] == os.environ["GITHUB_JOB"])
        data["github_job"] = {"started_at": job["started_at"], "completed_at": job["completed_at"],
            "steps": [{k: step.get(k) for k in ("name", "started_at", "completed_at", "conclusion")}
                      for step in job["steps"]]}
    except Exception:
        data["github_metadata_status"] = "unavailable"
    # The associated merged PR supplies the actual merge time, not an inferred
    # commit date. This public metadata query needs no additional token permission.
    if data.get("event") == "push" and (data.get("smoke") or {}).get("completed_at"):
        try:
            pulls_url = f'https://api.github.com/repos/{data["repo"]}/commits/{data["source_sha"]}/pulls'
            req = urllib.request.Request(pulls_url, headers={"Accept": "application/vnd.github+json"})
            with opener.open(req, timeout=20) as response: pulls = json.load(response)
            merged = [p for p in pulls if p.get("merged_at") and p.get("merge_commit_sha") == data["source_sha"]]
            if len(merged) == 1: data["merged_at"] = merged[0]["merged_at"]
        except Exception:
            data["merge_metadata_status"] = "unavailable"
    data["timing_breakdown"] = breakdown(data.get("merged_at"), data.get("workflow_created_at"),
        (data.get("smoke") or {}).get("completed_at"), data.get("github_jobs", []), data["stages"])
    data["checks_job"] = load("checks-report")
    data["image_cleanup"] = load("image-cleanup")
    data["limits"] = ["GitHub concurrency may cancel pending runs; retain cancellation metadata, not replacement samples","CI image is not the image rebuilt by Dokploy",
        "Webhook does not expose deployment ID, remote image ID, or internal finishedAt",
        "Artifact upload and workflow completion occur after this report; retain GitHub run metadata",
        "Runner death/offline can prevent artifact publication; missing evidence is not success"]
    if (data.get("smoke") or {}).get("status") == "success" and data["timing_breakdown"]["status"] != "complete":
        data["comparison_valid"] = False
    save("ttp-timings", data)
    if (data.get("smoke") or {}).get("status") == "success" and data["timing_breakdown"]["status"] != "complete":
        raise RuntimeError("successful smoke requires timing breakdown evidence")


if __name__ == "__main__":
    try:
        if sys.argv[1] == "init": init()
        elif sys.argv[1] == "run": sys.exit(run(sys.argv[2]))
        elif sys.argv[1] == "report": report()
        elif sys.argv[1] == "resume": resume()
        elif sys.argv[1] == "cleanup": cleanup()
        else: raise ValueError("unsupported operation")
    except Exception as error:
        # No exception repr/traceback: downstream HTTP failures can contain URLs/tokens.
        print("TTP operation failed: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)

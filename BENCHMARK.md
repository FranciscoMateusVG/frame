# Verification and measurements

## Print portal (benchmark scope)

The TS vs Rust vs Elixir benchmark measures **only the portal**. The Cat
crates stay as the template example, but they are outside that scope. The
portal-only commands are below. Run them from the workspace root.

| What | Command |
|---|---|
| Release artifact | `cargo build --release --locked -p frame-portal-web --bin print-portal` → `target/release/print-portal` (one native executable; config via env, see README) |
| Portal tests (no Docker needed) | `cargo test --locked -p frame-specs --test portal_unit --test portal_integration` |
| Portal lint | `cargo clippy --locked --all-targets -p frame-portal-domain -p frame-portal-port -p frame-portal-use-cases -p frame-portal-memory -p frame-portal-hono -p frame-portal-web -- -D warnings` |
| Canonical gate (whole workspace, includes Cat) | `just check` / `cargo xtask check` |
| Black-box run against a live Incluir Hono | `cargo run -p frame-examples --bin portal_e2e` with the env listed in its header (needs a running `print-portal` and Hono) |
| Production LOC | `cat crates/portal-*/src/*.rs \| wc -l` |
| Test LOC | `cat tests/portal_*.rs tests/*/portal_*.rs \| wc -l` |

Measured **2026-10-08**, on the same host as below: Apple M3, 16 GiB, macOS 15.7.4
arm64, rustc 1.94.1 (Homebrew). These are single wall-clock samples on a shared
developer machine, not a controlled benchmark.

| Measurement | Value |
|---|---:|
| clean release build of `print-portal` (empty target dir, crate cache warm; measured at 9ae2323) | 47.27 s (user 176.53 s) |
| `print-portal` executable size (default release profile, no strip/LTO; measured at 9ae2323) | 6,202,096 bytes (5.9 MiB), Mach-O arm64 |
| portal tests, warm artifacts (`portal_unit` 19 + `portal_integration` 17 tests, 5 of them proptests; re-measured at e35b363) | 1.90 s |
| production LOC (`crates/portal-*/src/*.rs`, including the inline JS/CSS in `assets.rs`; at e35b363) | 5,067 |
| test LOC (`tests/portal_*.rs` + `tests/*/portal_*.rs`, including verbatim contract fixtures; at e35b363) | 3,472 |

LOC per crate: portal-web 2201, portal-memory 867 (the upstream fake),
portal-use-cases 678, portal-domain 662, portal-hono 496, portal-port 163.

Measured **2026-10-07**, on Apple M3 (8 logical CPUs), 16 GiB RAM,
macOS 15.7.4 arm64. Rust/Cargo 1.94.1 (Homebrew), LLVM 21.1.8,
Docker Engine 29.4.0 (OrbStack), PostgreSQL 16 arm64 image:
`postgres@sha256:71e27bf60b70bded003791b5573f8b808365613f341df20ffcf0c1ed7bc13ddf`.

Single wall-clock samples, not a controlled statistical benchmark. Downloaded
crate sources and the Postgres image were cached. A clean build used an empty
Cargo target directory (dependencies still had to compile). No own builds/tests
were deliberately run concurrently with these measured commands; this remained
a shared developer machine, not an isolated benchmark runner. Lockfile committed.

## Timings

| Measurement | Elapsed |
|---|---:|
| release HTTP demo build | 102.014 s |
| clean SDK entrypoint build (empty target; downloaded crate cache warm) | 23.629 s |
| no-op incremental SDK entrypoint build | 0.232 s |
| incremental SDK entrypoint build after domain source edit | 0.319 s |
| clean workspace build (empty target; downloaded crate cache warm) | 50.801 s |
| no-op incremental workspace build | 0.390 s |
| incremental workspace build after domain source edit | 2.709 s |
| full tests (post-restore rebuild included) | 16.080 s |
| full tests (warm artifacts) | 9.244 s |

Commands:

```sh
# Closest scope to TS pnpm build: its three root/Postgres/testing SDK entrypoints
CARGO_TARGET_DIR=target/benchmark-sdk \
  cargo build -p frame -p frame-postgres -p frame-testing --locked

# Broader developer build, not directly equivalent to TS's SDK-only build
CARGO_TARGET_DIR=target/benchmark-workspace-final \
  cargo build --workspace --all-targets --locked

# Same target, no coverage instrumentation (all tests + doctests; real Postgres)
CARGO_TARGET_DIR=target/benchmark-workspace-final \
  cargo test --workspace --locked

# Default release profile, no custom stripping/LTO/size optimizations
CARGO_TARGET_DIR=target/benchmark-clean \
  cargo build --release --locked -p frame-examples --bin create_cat_axum
```

For each incremental source-edit measurement a comment was appended to
`crates/domain/src/cat.rs`, the same build was timed, then the original source
was restored. The first full test timing includes the resulting restoration
rebuild; the second full test timing has warm artifacts. No test filters/skips.
The SDK measurements do **not** include compilation of testcontainers, HTTP
examples, test harnesses, or xtask. Full-workspace measurements do.

## Release artifact

`create_cat_axum`: **14,791,536 bytes**
(**14.106 MiB**), Mach-O arm64 native executable.
It was also executed successfully: real Postgres and HTTP requests produced
201 / 200 / 409 / 400, then cleaned up.

This is the faithful **ephemeral HTTP demo**, including its Docker orchestration
and self-request client, not a minimal production server. A TS JS bundle does
not include Node or its external runtime packages; comparing only that bundle
size with a native executable would be misleading. No throughput measurement
or performance ranking is claimed here.

## Final canonical gate

Command: `cargo xtask check` (also `just check`). **Exit code: 0.**
The following is verbatim selected output, not a fabricated test summary:

```text
architecture + layout: PASS (Cargo declarations + syn AST)
codegen drift: PASS (live PostgreSQL 16)
running 4 tests
test result: ok. 4 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 11.54s
running 29 tests
test result: ok. 29 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.14s
coverage crates/domain/src/cat.rs: lines 100.00% (required 90%)
coverage crates/domain/src/cat.rs: functions 100.00% (required 90%)
coverage crates/domain/src/cat.rs: regions 100.00% (required 85%)
coverage crates/use-cases/src/create_cat.rs: lines 100.00% (required 90%)
coverage crates/use-cases/src/create_cat.rs: functions 100.00% (required 90%)
coverage crates/use-cases/src/create_cat.rs: regions 100.00% (required 85%)
hooks: PASS (readable, executable, correct commands)
CHECK PASSED in 100.78s
```

The reported pipeline timer starts inside xtask, after Cargo has built/started
that tool. It is not presented as an externally timed clean gate invocation.
The normal pre-push hook reruns this same complete gate; it is not bypassed.

Rust has **33 test functions** here; grouped fixtures execute the **72 original
TS scenarios**, plus documented regressions/composition assertions. Counts are
not interchangeable between harnesses. See PARITY.md for the scenario map and
why region coverage is not branch coverage. Both core files achieved 100% lines,
functions and regions, with independent mandatory 90/90/85 thresholds.

## Negative checks

A clean scratch copy passed architecture (exit 0). Eleven mutations failed
with exit 1: domain dependency, concrete use-case dependency, internal facade
import, production SDK import, local module cycle, invalid source filename,
missing hook, generated-schema corruption, newly added unused-column migration,
uncovered core functions, and a failing test through the top-level check.
PARITY.md lists commands and observed errors. Scratch copies were removed after
verification; the actual source branch was not mutated by those probes.

The public helper's explicit-shutdown-then-Drop regression was first observed
failing (`AlreadyShutdown`), then fixed and retained as a passing test. The
new-migration cache issue was likewise reproduced in scratch before replacing
xtask's compile-time migration list with runtime discovery and adding the
production migration-directory build watcher.

Development evidence retained locally for the reviewer:

- `/tmp/frame-rust-check-final.log`
- `/tmp/frame-rust-bench-sdk.log`
- `/tmp/frame-rust-bench-workspace-final.log`
- `/tmp/frame-rust-bench-final.log` (release build)
- `/tmp/frame-rust-release-smoke.log`
- `/tmp/frame-rust-helper-red.log` and `...-green.log`
- `/tmp/frame-rust-new-migration-red.log` and `...-green.log`
- `target/negative-gates.json`, `target/benchmark.json`, `target/coverage/coverage.json`

These transient paths are evidence locations on the development host, not
prerequisites for a fresh clone. Every check can be reproduced from committed
sources. The exact final commit SHA is supplied with the handoff, since a commit
cannot embed its own hash.

## Production container (2026-10-08)

The multi-stage Dockerfile uses the official rust:1.94.1-slim-bookworm builder
(the compiler version used by this branch's benchmark; workspace minimum 1.88)
and cargo build --release --locked -p frame-portal-web --bin print-portal.
Only the resulting binary enters **debian:bookworm-20261005-slim**, the same
Debian base tag as Phoenix. Runtime packages are CA certificates and libgcc-s1;
ldd verified the binary needs libgcc_s, libm, libc and the glibc loader, not
OpenSSL. The existing upstream HTTP adapter uses rustls. No cargo/rustc,
source tree or build cache enters the runtime.

This is ordinary [multi-stage packaging](https://docs.docker.com/build/building/multi-stage/)
with the [official Rust image](https://hub.docker.com/_/rust), not an image-size
contest using musl, scratch, distroless, UPX, extra strip/LTO flags or profile
changes. Like Phoenix: UID 10001, root-owned artifact, exec-form entrypoint,
and HTTP /healthz HEALTHCHECK at 30s/5s timeout/20s grace/3 retries. Packages
unused by Rust (the BEAM/OpenSSL runtime, for example) are not added as padding.

```bash
docker build --platform linux/arm64 -t print-portal-rust .
docker image inspect print-portal-rust --format '{{.Size}}'
# Supply the four required variables through your protected environment first.
docker run --rm -p 127.0.0.1:4000:4000 \
  -e PRINT_PORTAL_PASSWORD -e INCLUIR_PRINT_SERVICE_TOKEN \
  -e INCLUIR_PRINT_API_ORIGIN -e PRINT_PORTAL_ORIGIN print-portal-rust
curl --fail http://127.0.0.1:4000/healthz
```

The image overrides the native loopback default with
PRINT_PORTAL_BIND=0.0.0.0:4000. To change ports set PRINT_PORTAL_BIND, not PORT;
the health probe follows its port suffix, and the published port must match.
Secrets are runtime-only, never ARG/COPY. .dockerignore excludes .env files
and build outputs. Cargo sees all workspace manifests but compiles only the
portal binary and its transitive dependencies, not the Cat examples/tests.

Measured locally with Docker 29.4.0 on **linux/arm64**: **113,622,076 bytes
(108.36 MiB)** from docker image inspect .Size. This is the uncompressed logical
image size, not compressed registry transfer, unique disk usage or runtime RAM.
Base manifests: Debian
sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587;
Rust sha256:cf9dd0ec73e75f827fe59123fff9dc65af1a1c8363c3c31ee8d7f8ad0b6a5fb2.
Image ID: sha256:1b6805b5855f5b7cd27cdf64678622dca56d8b847a1beebde6e8ba5047010fb4.
Re-record digests/sizes after base or apt security updates.

Real-container checks: /healthz and /login 200; Docker healthy; default and
custom bind port 4010; UID 10001; no compiler; read-only root filesystem with
all capabilities dropped; missing env exits 2. Synthetic runtime secrets were
not present in logs. Health is liveness, not proof of an upstream Incluir
connection. No production service or credentials were used.

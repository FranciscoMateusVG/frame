# Frame — Rust

Rust port of the AI-native Frame SDK template at TypeScript `main` commit
`7a097f5e3cf52f2526b259958e755cb7298cec2d` (including Wave 3).
Cats are a placeholder, not a product. Replace the domain, retain the rails.
See [PARITY.md](PARITY.md) for the exact mapping and unavoidable differences.

## Prerequisites and quick start

- Rust/Cargo with rustfmt and Clippy (verified on Rust **1.94.1**, stable).
- Docker running; tests start **PostgreSQL 16** themselves using testcontainers-rs.
- LLVM coverage tools matching `rustc -vV`'s LLVM major. With rustup:
  `rustup component add llvm-tools-preview`. Alternatively set `LLVM_COV` and
  `LLVM_PROFDATA` to matching binaries. Matching Homebrew `llvm@<major>` is also
  auto-detected. Nothing is installed by the check command.
- `just` is optional: every recipe delegates to Cargo.

```sh
git clone --branch frame-rust https://github.com/FranciscoMateusVG/frame.git
cd frame
cargo xtask install-hooks
cargo xtask check                 # OR: just check
```

The gate is self-contained: fmt, architecture/layout, Clippy `-D warnings`,
all-target strict checking, SQLx/schema drift against a fresh container, **all
workspace tests with coverage thresholds**, three real-Postgres examples, hooks.
It stops on the first failure. No Compose database, SQLx CLI, Node, or pnpm is
needed. The TypeScript reference lives on `main`, not in this branch.

## Commands

| Command | Purpose |
|---|---|
| `cargo xtask check` / `just check` | Canonical binary gate |
| `cargo fmt --all` | Format |
| `cargo clippy --workspace --all-targets -- -D warnings` | Lint |
| `cargo xtask architecture` | Check declared dependencies, parsed module imports/cycles, layout |
| `cargo check --workspace --all-targets --locked` | Check every library, example, test, and tool |
| `cargo test --workspace --locked` | Full tests (real containers required) |
| `cargo xtask coverage` | Full instrumented tests + per-core-file coverage thresholds |
| `cargo xtask check-codegen` | Fresh Postgres → migrate → regenerate query metadata/schema → compare |
| `cargo xtask codegen` | Regenerate and write `.sqlx/` after query/migration changes |
| `just build` / `cargo build -p frame -p frame-postgres -p frame-testing --locked` | Build the three SDK distribution entrypoints (TS tsup counterpart) |
| `just build-all` / `cargo build --workspace --all-targets --locked` | Build all libraries, tests, tools and example executables |
| `cargo build --release -p frame-examples --bin create_cat_axum` | Release HTTP demo executable |
| `cargo xtask verify-hooks` | Check hooks exist, are executable and invoke required commands |
| `cargo xtask install-hooks` | Configure Git to use the checked-in, dependency-free hook wrappers |
| `just db-up` / `just db-down` | Optional persistent development database (port 54320) |
| `cargo xtask migrate` | Apply migrations to `DATABASE_URL` or the Compose default |

Do not use destructive database reset on valuable data. Testcontainers owns
only the temporary containers it creates. `.sqlx/` is committed so ordinary
builds do not connect to any database; the gate independently verifies it.

## Architecture

```text
crates/domain/         Cat, input schemas: data + pure validation, no I/O
crates/errors/         thiserror typed validation/duplicate/infrastructure errors
crates/port/           CatRepository trait only
crates/use-cases/      create_cat(deps, input); explicit repository, clock, observability
crates/memory/         memory implementation (same conformance suite)
crates/postgres/       SQLx implementation + production connection factory/migrations
crates/observability/  Logger, Console/Noop/OTel, tracer API and Observability
crates/frame/          public facade (NOT concrete repository implementations)
crates/testing/        separate consumer observability test helper (OTel SDK allowed)
tests/                 unit/, integration/, helpers/; proptest stays unit/memory
examples/              bare SDK, OTel wiring, Axum HTTP transport
migrations/            ordered up/down SQL
xtask/                 canonical checks; architecture uses Cargo metadata + syn AST
```

No application framework or DI container. `async_trait` only makes the async
repository port object-safe; it does not discover or construct dependencies.
Axum lives in the **example** package, not in the SDK. The HTTP composition root
constructs the required real Postgres repository; integration tests exercise that
same root through a listening socket and real network requests.

Cargo's package boundaries reject undeclared dependencies and package cycles.
The architecture check additionally locks permitted production dependencies,
rejects internal facade/SDK imports, catches local module cycles, and validates
flat snake_case source layout. Change its explicit structure/allowlists when
intentionally introducing a layer. Domain and use-case rules cannot be bypassed
simply by adding a forbidden dependency to a manifest.

### Basic SDK use

```rust,ignore
use frame::{create_cat, CreateCatDeps, CreateCatInput, Observability};
use frame_postgres::CatRepositoryPostgres;

let db = frame::create_database(&database_url).await?;
let repository = CatRepositoryPostgres::new(db);
let obs = Observability::default();
let clock = || std::time::SystemTime::now().into();
let cat = create_cat(
    CreateCatDeps { cat_repository: &repository, clock: &clock, observability: &obs },
    CreateCatInput { id: caller_uuid, name: "Whiskers".into() },
).await?;
```

The caller owns migrations and shutdown. IDs are caller-provided; duplicate
**names fail**, rather than returning the prior entity. Invalid UUIDs deliberately
produce `InvalidCatNameError`, retaining the reference's historical naming.

## Observability

Production crates use **only OpenTelemetry's API**, no SDK/provider/exporter
setup. Without consumer configuration, `Observability::default()` and default
`OtelLogger` are no-op safe. Consumers own resources, sampling, exporters, and
provider lifetime. See `examples/src/bin/create_cat_with_otel.rs` for the complete
wiring: a real SDK exporter prints finished spans, validates parent/child IDs,
and flushes/shuts down.

Each use case has one `createCat` span and a `cat.created` success log. Each
repository method has one `db.cats.<method>` span and **never logs**. Attributes
contain IDs and normalized **UTF-16 name lengths**, not raw names. Error events
carry the error message, just as in TS (duplicate error messages contain the
name; do not mistake attribute discipline for complete PII redaction).

`FutureExt::with_context` attaches context **per future poll**, so parent/child
relationships and automatic log correlation survive `.await` without leaking
thread-local guards between tasks. Adapters resolve the global API tracer on
each operation; their trait and constructors have no observability parameter.

Rust has no global Logs API provider. Construct `OtelLogger::new(provider.logger(
"your-scope"))` using the **API trait** `opentelemetry::logs::LoggerProvider`;
only the consumer knows the SDK type. `OtelLogger::default()` uses the API no-op
provider. `ConsoleLogger` writes INFO/DEBUG to stdout and WARN/ERROR to stderr.

`frame_testing::TestObservability` is a separate crate exposing `observability`,
`get_spans`, `reset`, and `shutdown`. It uses a real SDK/in-memory exporter and
serializes tests that alter the process-global tracer provider. Drop shuts down
and resets that provider. It is a test helper, not a production setup helper.

## Examples

All three are self-contained, create real Postgres, assert their results, and
are run by `cargo xtask check`:

```sh
cargo run -p frame-examples --bin create_cat
cargo run -p frame-examples --bin create_cat_with_otel
cargo run -p frame-examples --bin create_cat_axum
```

The Axum demo starts an ephemeral listener, performs real POST/GET requests
(201/200/409/400), then stops. It also implements missing-cat GET → 404.
There are no extra business routes or use cases. This is a demo executable,
**not a production daemon**; its release size includes testcontainer orchestration.

## Tests and coverage

The 72 original TS test scenarios are preserved, with shared/grouped Rust
fixtures described in PARITY.md. They include real Postgres uniqueness races,
migration up/down, clock injection, all validation errors, SDK spans/logs, and
proptest's 50/100/100 cases. Unit schemas explicitly pin ECMAScript trim and
UTF-16 limits rather than subtly changing Unicode behavior to Rust defaults.

`cargo xtask coverage` uses stable LLVM source coverage and enforces **each** of
`crates/domain/src/cat.rs` and `crates/use-cases/src/create_cat.rs`:

- lines ≥90%; functions ≥90%; **regions ≥85%**.

Region coverage is **not numerically equivalent** to TS's ≥85% branch coverage.
Stable rustc does not expose branch instrumentation. This is an explicit,
reviewer-approved substitution, not a claim of identical coverage metrics.
All workspace tests run without skips/filters. Reports and test output are in
`target/coverage/`; no extra core-code exclusions are used.

## Add a use case / fork the template

1. Describe behavior, write red specs, and obtain the human test gate first
   ([workflow](.claude/workflow.md)).
2. Define pure types/validators in `crates/domain/src/<entity>.rs`.
3. Define its repository trait in `crates/port/`; add typed errors in `errors/`.
4. Add memory and real adapters; both must run the same conformance scenarios.
5. Write one plain function file in `use-cases/` with explicit deps. Validate at
   its boundary, instrument its span, and log only business success.
6. Add ordered up/down SQL, run `cargo xtask codegen`, commit `.sqlx/`.
7. Export the contract/use case from `frame`; keep concrete adapters separate.
8. Wire the real adapter in the example composition root and exercise it.
9. Run `cargo xtask check`; review test diffs; never bypass hooks.

To fork, rename workspace packages, replace the Cat domain/port/use-case/adapters,
tests and migrations, update architectural allowlists, regenerate SQLx metadata,
and adapt all three examples. Keep the workflow, boundaries and gate.

## Print portal (`print-portal`)

The print-shop portal (spec `print-portal.md` §4.3/§4.5/§5/§7) is built on
these rails, next to the Cat example. It is a BFF that renders server-side
HTML. It has **no database and no object storage**. Its only dependency is the
Incluir Hono `/api/print-portal/v1` service API, reached with a server-only
bearer token. Sessions are kept in memory.

```text
crates/portal-domain/     frozen upstream DTOs (strict serde + schema checks), cents/BRL, competence, filenames
crates/portal-port/       PrintApi trait (the upstream port), ApiError, Preconditions, Download
crates/portal-use-cases/  session registry, login limiter, login/logout, one use case per print operation
crates/portal-memory/     in-memory upstream fake: ETag/If-Match CAS, idempotency, state machine, closes
crates/portal-hono/       real reqwest adapter: fixed origin, no redirects, strict parsing, timeouts
crates/portal-web/        axum router, maud pages, JSON BFF, cookies/CSRF; `print-portal` binary
```

Run it (all configuration comes from the environment; missing or invalid
values exit with code 2 and name the variable, never its value).
`PRINT_PORTAL_PASSWORD` requires at least 12 characters:

```sh
PRINT_PORTAL_PASSWORD=… INCLUIR_PRINT_SERVICE_TOKEN=… \
INCLUIR_PRINT_API_ORIGIN=https://hono.example PRINT_PORTAL_ORIGIN=https://grafica.example \
PRINT_PORTAL_BIND=127.0.0.1:4000 cargo run --release -p frame-portal-web --bin print-portal
```

Optional settings: `PRINT_PORTAL_SESSION_IDLE_SECONDS` (default 1800),
`PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS` (default 28800) and
`PRINT_PORTAL_TRUSTED_PROXIES` (comma-separated IPs; without it,
`X-Forwarded-For` is ignored). The binary serves `/healthz` and `/readyz`;
`/readyz` probes the upstream using the token but never exposes it.

The tests run the shared `PrintApi` conformance suite against the memory fake,
and against the real HTTP adapter through a fake Hono on a socket. The BFF is
exercised end to end over real sockets (`tests/portal_*.rs`). For the black-box
run against a live Incluir, see `examples/src/bin/portal_e2e.rs`. Benchmark
commands are listed in [BENCHMARK.md](BENCHMARK.md#print-portal-benchmark-scope).

## Stack

Rust stable · Cargo workspace · PostgreSQL 16 · SQLx compile-time macros/offline
metadata · thiserror · OpenTelemetry API/SDK boundary · axum (examples only) ·
testcontainers-rs · proptest · rustfmt · Clippy · syn/Cargo architecture checker ·
LLVM region coverage · dependency-free Git hooks · optional just.

License: MIT (same as reference).

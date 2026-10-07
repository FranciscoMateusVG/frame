# TypeScript → Rust parity

**Reference:** `origin/main` at
`7a097f5e3cf52f2526b259958e755cb7298cec2d` (Wave 3). The TS repo was read before
implementation: README, workflow, import/layout gates, all source/tests, migrations,
Docker and examples. This branch contains Rust only; the reference remains on main.

**Rust branch:** `frame-rust`. Exact reviewed commit is recorded in the handoff / Git
history (a commit cannot contain its own hash). **Canonical gate:** `cargo xtask
check` (`just check` is an alias). Benchmarks and verification evidence follow below.

This document follows the review checklist's numbered sections. It is a map of
behaviors and enforcement, not an assertion that line counts or test-function
counts are the same.

## 2. Architecture and layout

| TS item | Rust item | Notes |
|---|---|---|
| domain, Zod schemas | `crates/domain/src/cat.rs` | Pure functions/data, no I/O or other internal layers. serde handles untyped input; explicit pure validators replace Zod. |
| typed error classes | `crates/errors`, thiserror | Structs preserve codes/messages; `Error` is the typed sum returned across the port/use case. Infrastructure errors preserve their boxed source rather than being mislabeled. |
| adapter interface | `crates/port::CatRepository` | Async object-safe trait; async-trait only erases async method types, not DI. |
| memory implementation | `crates/memory` | Mutex-protected map, no external I/O. Required because Rust's trait is usable from concurrent tasks. |
| Kysely/Postgres implementation | `crates/postgres`, SQLx | All four repository queries use compile-time `query!`; committed offline descriptors support DB-free builds. |
| use-case functions + explicit deps | `crates/use-cases/src/create_cat.rs` | Borrowed repo/clock/observability struct; no application framework, globals for business deps, or DI container. |
| `src/index.ts` | `crates/frame` | Public types/validation/port/errors/observability/use case/database factory. Does not re-export concrete repositories. |
| Postgres subpath | `frame-postgres` crate | Concrete adapter and migration/DB utilities available explicitly. |
| `frame/testing` | `frame-testing` crate | Separate consumer SDK-backed helper; not a production dependency. |
| dependency-cruiser | Cargo crate boundaries + `xtask architecture` | Package dependency allowlists from Cargo metadata, parsed syn AST imports and flat-module cycle detection. Domain → layer, use case → concrete adapter, internal → facade, production → SDK all fail. Cargo compilation rejects unresolved imports/package cycles. |
| ESLint layout gate | `xtask/src/architecture.rs` | Named crate directories; flat snake_case `.rs` sources; separate unit/integration/helpers; example bins; ordered `.up.sql`/`.down.sql`; tools in flat `xtask/src`. Unexpected file/name/location fails. |
| tsup ESM/CJS/types | Cargo `.rlib` + native examples | Language-specific artifacts, not invented ESM equivalents. `just build` builds the three matching SDK entrypoints; full-workspace/all-target builds are separately labeled; the check compiles tests/examples incidentally, like executing the TS examples. |

The facade intentionally depends on Postgres to expose `create_database`, as the
TS root does. Use-case and domain crates cannot depend on that facade. The
production dependency allowlists also prevent SDK injection via a renamed Cargo
dependency. The architecture tool examines source/metadata, not documentation or
substring-only import greps; it is not a general-purpose verifier of arbitrary
third-party procedural macro expansions.

## 3. Functional contract and inherited quirks

| TS item | Rust item | Notes |
|---|---|---|
| Cat readonly fields, string IDs/names, Date | `Cat`, String aliases, `DateTime<Utc>` | Rust bindings are immutable by default; ownership/cloning replaces JS object identity. JSON is camelCase and millisecond UTC ISO (`createdAt`). Values, not reference identity, are the contract. |
| trim, length 1..100 | `trim_name`, `name_length`, `parse_cat_name` | Explicit ECMAScript whitespace including BOM, excluding NEL; counts UTF-16 code units rather than Rust bytes/scalars. Emoji limit tests pin this. |
| z.uuid() | `parse_cat_id` | Hyphenated RFC versions 1–8 with RFC variant, plus nil/max UUID; preserves input casing. Not restricted to v4 despite reference prose. |
| required input properties | `CreateCatInput` + `parse_create_cat_value` | Typed Rust callers cannot omit fields; untyped JSON schema entry point rejects omissions/non-strings. serde diagnostic wording for missing/wrong-type fields differs from Zod. Typed create-call validation messages for malformed ID/empty/long names match. |
| createCat validates directly | `create_cat` validates before persistence | Invalid UUID deliberately becomes `InvalidCatNameError`. Multiple ID/name issues are joined in order with `; `. Caller ID and injected timestamp preserved. |
| error codes/messages | `CatAlreadyExistsError::CODE`, `InvalidCatNameError::CODE`, `Error::code` | Stable strings and messages. Rust duplicate error retains `cat_name`; TS accidentally overwrites the constructor `name` property with the Error class name. No business semantics depend on that JS property collision. |
| save/find ID/find name/delete | same four trait methods | `Result<Option<Cat>, Error>` is explicit absence/error; delete returns bool. Case-sensitive unique names. No retry, update, auth, pagination or extra use case. |
| unique error code 23505 | Postgres maps all 23505 to duplicate error | Includes PK conflicts, just like TS. Original DB error is recorded on the adapter span before translation. Other SQL errors remain infrastructure errors. |
| memory Map same-ID overwrite | retained intentionally | Different name + existing ID overwrites memory; Postgres rejects it. Same-name retry always fails. This inherited discrepancy is regression-tested, not advertised as new idempotency semantics. |
| PostgreSQL UUID canonicalization | retained | Memory keys preserve caller strings; Postgres reads canonical UUID strings and accepts PostgreSQL's direct-query UUID syntax. Boundary creation validation remains stricter. |
| timestamp default/schema | SQL migration | UUID PK; name varchar(100) NOT NULL UNIQUE; created_at timestamptz NOT NULL DEFAULT now(). Ordered reversible migration. |
| Kysely codegen/drift | `.sqlx/query-*.json` + `.sqlx/schema.json` | Fresh migrated Postgres generates macro metadata into a temporary directory, compares parsed JSON, and fails on drift. Complete schema snapshot catches unused added columns too. Queries are typechecked against Postgres at generation time and committed metadata at ordinary compile time. |
| production DB factory used by tests | `create_database` | All test/example fixtures use the real pool factory; no fake SQL driver or alternate test-only connection implementation. The Rust async factory eagerly establishes a connection (SQLx `connect`); the TS pg pool connects lazily on first I/O. Startup failure timing differs, not repository behavior. |

Rust strings cannot represent unpaired UTF-16 surrogates (possible in JavaScript).
For valid Unicode, JS trim/length semantics are preserved. JS dates are
millisecond-resolution; the Rust timestamp type can carry finer precision if a
caller supplies it, while example clocks and JSON intentionally use milliseconds.
The fixture uses an exact injected timestamp. Repository failures use `Result`;
Rust panics are programming failures, not JavaScript-style thrown business errors.
They unwind/drop spans rather than being translated into a typed domain error;
normal validation/database Result failures record ERROR and exception events.
Memory returns owned copies, unlike
JS aliasing; mutation of readonly Cat objects is not part of the TS contract.

## 4. Observability

| TS item | Rust item | Notes |
|---|---|---|
| API-only production, consumer SDK setup | `opentelemetry` API dependency | SDK only in test helper/tests/examples. No production `setupObservability`. |
| Logger/Tracer deps | `Observability` | Logger trait object + API BoxedTracer. Default logger and unconfigured global tracer are safe no-ops. |
| module-level adapter tracer proxy | API tracer lookup per adapter operation | Rust global API tracers do not have TS's late-bound proxy semantics. Resolve on each call so consumer provider registration and independent fixtures work; no tracer constructor dependency added. |
| AsyncLocalStorage parent propagation | `FutureExt::with_context` per poll | No thread-local guard held across await. Real provider tests assert parent span ID and common trace ID. |
| exactly one use-case/adapter span | `in_span` / `repository_span` | Same span names/semantic attributes, OK/ERROR, exception events and end on both Result paths. SDK spans also finalize on drop/cancellation/unwind. |
| shapes, not raw-name attributes | ID and UTF-16 normalized length | Same `cat.id`, `cat.name.length`; logs `catId`, `nameLength`. Like TS, exception messages themselves may contain the duplicate name. |
| only use cases log | `cat.created` after successful save | Tests assert one success log and no success log on failure. Adapters emit spans only. |
| ConsoleLogger | stdout INFO/DEBUG; stderr WARN/ERROR | Timestamp, padded level, optional JSON attributes. Writer boundary allows testing real formatting/routing without mocking OTel. |
| NoopLogger | same trait, no effects | All levels exercised. |
| OtelLogger global provider | generic API-backed `OtelLogger::new(api_logger)` | Rust Logs API lacks TS's global logger provider; the consumer constructs a named API logger. `Default` uses API NoopLoggerProvider. SDK auto-correlates current span IDs; no manual ID threading. |
| SDK log tests | real InMemoryLogExporter/SdkLoggerProvider | INFO/WARN/ERROR/DEBUG, text/body/attrs, no attrs, inside/outside trace, custom scope all asserted. |
| public test helper | TestObservability | Observability/get_spans/reset/shutdown plus Drop cleanup. Fixtures that alter global tracing are serialized inside each test executable; ordinary application calls are not serialized. |
| console span exporter example | real SDK in-memory exporter + console rendering | Same traced create/fetch/delete and visible IDs/status; additionally asserts parent/child relationship before shutdown. Exporter choice remains consumer-owned. No new SDK setup in the library. |

## 5. Test scenario map

The TS baseline has **72 tests in 8 files**. Rust groups some scenarios within
shared container fixtures, rather than paying for a container per assertion.
Do **not** compare test-function counts as coverage/quality metrics.

| TS suite/scenarios | Rust location | Execution |
|---|---|---|
| Cat schemas: 13 | `tests/unit/cat_domain.rs` | 13 one-to-one tests; additional JS Unicode/UUID/error-order/JSON-shape regression checks. |
| Properties: 3, 50/100/100 cases | `tests/unit/cat_property.rs` | proptest generators of real Unicode strings; memory round-trip, overlong rejection, valid acceptance. Same run counts. |
| Repository conformance: 12 × 2 | `tests/helpers/cat_repository_conformance.rs` | Exactly the same helper runs for memory and real Postgres. Seven persistence behaviors + four operation span checks + duplicate error span. |
| Postgres concurrency: 1 | `tests/integration.rs` | `tokio::join!` submits competing saves to a real pool, asserts one success and one typed duplicate. |
| createCat: 16 | `tests/integration/create_cat.rs` | Real Postgres return/clock/readbacks/trim/100 limit, four invalid inputs, duplicate/different names/name retry, parent-child/error spans. Explicit delete reset between scenario groups. |
| Migration round trip: 1 | `tests/integration/migration.rs` | Real up → table present → down → absent (then re-up for repeatability). |
| Console/Noop: 6 | `tests/unit/logger.rs` | Six behaviors grouped in four Rust tests; all levels and stream routing. |
| OTel logger: 8 | `tests/unit/otel_logger.rs` | Eight scenarios grouped in two Rust tests, real providers/exporters. |
| Wave 3 HTTP example | `tests/integration/http.rs` + example | Actual TCP/HTTP/Postgres composition, same status/body contract, plus existing missing-ID route and non-string input fallback. |

Additional robustness assertions pin inherited same-ID divergence, non-unique
SQL errors, business logs/no raw-name attributes, fixture lifecycle, and HTTP 404/
500. These do not add features or replace any original scenario. Tests are not
ignored or filtered in the canonical command. There is no SQLite or mocked
repository/SQL/OTel integration boundary. Testcontainer handles and server guards
perform cleanup on failure; success explicitly shuts down server/pool/container.

## 6. HTTP parity

`examples/src/http.rs` is a thin Axum adapter: JSON parse → caller-generated UUID
→ the **same** `create_cat` → typed error translation. Required real
`CatRepositoryPostgres` is constructed by the composition root, which both the
example and integration test use.

- POST valid: 201 + Cat; duplicate: 409 + code/message; invalid: 400 + code/message.
- GET found: 200 + Cat; absent: 404 + `{"error":"NOT_FOUND"}`.
- Infrastructure errors produce 500, not disguised validation/duplicate errors.
  Unlike Hono's thrown-exception handler, Axum requires an explicit response path;
  the example uses an ordinary generic 500 without exposing database details.
- Axum's framework-native malformed JSON/media-type rejection differs from Hono's
  default exception handling. The reference has no special malformed-JSON
  contract, and no additional domain rule is introduced.
- PostgreSQL 16, migrations, ephemeral listener, actual self-requests, shutdown.
  Assertions make incorrect demonstrated statuses fail the check; TS merely prints.

## 7. Canonical gate and coverage substitution

`cargo xtask check` fails fast through:

1. `cargo fmt --all -- --check`;
2. Cargo-declaration/syn-AST architecture **and structural** checks;
3. `cargo clippy --workspace --all-targets --locked -- -D warnings`;
4. `cargo check --workspace --all-targets --locked`;
5. fresh Postgres SQLx macro/whole-schema drift check;
6. full workspace tests with LLVM source coverage;
7. bare real-Postgres SDK example;
8. consumer-wired OTel real-Postgres example;
9. real Axum/Postgres/self-request example;
10. readable/executable/correct-command hook verification.

Compared with TS, the format and lint stages are split around architecture;
there is no independent release build step in either gate. Cargo naturally
compiles test/example binaries as needed. `just check` does no additional work.
The check never installs tools or starts a pre-existing Compose stack.

**Each** core file (`domain/src/cat.rs`, `use-cases/src/create_cat.rs`) must have
**≥90% lines, ≥90% functions, ≥85% regions**. Stable Rust's LLVM instrumentation
does not expose branch coverage. **Region coverage is not numerically equivalent
to the TS ≥85% branch metric.** This substitution was explicitly accepted by the
lead/reviewer; every original conditional/error scenario remains tested. No
additional core-code exclusions are applied. LLVM reports full source coverage;
only the two TS-equivalent core files receive mandatory thresholds.

The coverage command saves its actual test output/report in `target/coverage/`;
it fails on test errors, missing profiles/files, export failure or a threshold
breach. `cargo xtask coverage` can be negative-tested independently.

Hooks keep the existing `.husky/_` path but are plain shell, with no JS tooling.
Pre-commit checks formatting across the workspace rather than TS's staged
formatter/autofix. Pre-push executes the entire canonical check. Verification is
stronger than TS's existence/readability check: executable bits and command
wiring are checked too. Install the path once with `cargo xtask install-hooks`.
No shared main-worktree Git config was modified during this port.

### Negative tests performed in a scratch copy

The clean scratch architecture check returned 0. Each mutation below returned
**1**; the actual logs are captured during development (no mutation touched the
source branch):

| Mutation | Command | Observed error |
|---|---|---|
| Add domain → errors dependency | `xtask architecture` | `architecture violation: frame-domain → frame-errors` |
| Add use-cases → memory dependency | same | `architecture violation: frame-use-cases → frame-memory` |
| Internal `use frame::Cat` | same | `forbidden internal facade/SDK import` |
| Add production OTel SDK dependency | same | `architecture violation: frame-observability → opentelemetry_sdk` |
| Mutual module imports | same | `module cycle at cycle_a` |
| `domain/src/BadName.rs` | same | `structure violation ... expected flat snake_case.rs` |
| Remove pre-push hook | `xtask verify-hooks` | file missing / nonzero |
| Add a new migration with an unused column | `xtask check-codegen` | live schema drift (runtime migration discovery + Cargo migration-directory watcher) |
| Change generated schema column type | `xtask check-codegen` | `codegen drift: run cargo xtask codegen ...` |
| Add unexercised core functions | `xtask coverage` | `coverage threshold failed: crates/domain/src/cat.rs lines` |
| Add deliberate failing test | `xtask check` | failing test → `coverage test command failed`, nonzero top-level |

## 8–9. Workflow, public surface and examples

`.claude/workflow.md` and role prompts preserve human behavior description →
red-spec agent → **human test gate** → implementation without approved-test edits
→ human diff/merge review. They forbid bypasses, weakened thresholds and fake
integration boundaries. This initial translation is a port of already-approved
reference scenarios, not a claim that a new human test gate occurred mid-port.

The public surface, separate Postgres and testing crates, three examples,
prerequisites, CLI recipes, architecture/OTel docs and new-use-case/fork recipe
are in README. Rust packaging replaces TS module/type outputs; there is no
additional production binary/service beyond the reference's ephemeral example.

## 10–11. Measurement scope / fairness

- Test scenarios and boundaries, not source LOC or raw test counts, define parity.
- Rust emits native binaries; TS distribution depends on Node and npm packages.
  Native executable size is **not** directly comparable to a TS JS bundle alone.
- The release artifact measured is `create_cat_axum`, the faithful **self-contained
  demo**. It includes HTTP client and Docker/testcontainer orchestration, because
  the TS Hono demo does too. It is not a minimal persistent production server.
- The default release profile is used (no custom LTO, stripping or size tricks).
- SDK-only build measurements select `frame`, `frame-postgres`, `frame-testing`,
  corresponding to the TS tsup root/Postgres/testing entrypoints. Full-workspace
  builds additionally include test, example and xtask tooling, and are labeled
  separately rather than compared directly with `pnpm build`.
- Build measurements name their complete commands and cache state. Downloads and
  benchmark harness bootstrap are not silently included in a language runtime
  throughput claim. No request-throughput benchmark was requested or invented.

Final timings and final check output are recorded in `BENCHMARK.md` and the
handoff, together with exact branch/SHA. They describe this shared developer
machine, not a statistically controlled cross-language performance result.

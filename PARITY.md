# PARITY — TypeScript `frame` → Elixir `frame-elixir`

- **Reference:** `origin/main` @ `7a097f5` (TypeScript, incl. Wave 3: Hono HTTP example + ESLint structure gate + OtelLogger tests).
- **This port:** branch `frame-elixir` (the SHA under review is the branch head; it is reported with the hand-off).
- **Canonical gate:** `mix check` (≡ `pnpm check`). Runs in `MIX_ENV=test` automatically, needs only Docker, starts and stops its own containers, and aborts on the first failing step with a non-zero exit.
- **Toolchain used:** Elixir 1.20.4 / Erlang/OTP 29, Docker (OrbStack), `postgres:16`.

Layout of this document: one table per area of the reviewer checklist (`frame-parity-checklist.md` §2–§9). Each table maps TS item → Elixir item → notes. Items in the notes column marked **Deviation** are intentional and explained; **Quirk kept** marks an inherited TS behavior that is replicated on purpose.

---

## 1. Gate (`pnpm check` → `mix check`) — checklist §7

| # | TS step | Elixir step (`mix check`) | Notes |
|---|---------|---------------------------|-------|
| 1 | `biome check .` (lint + format) | `mix lint` = `mix format --check-formatted` + `mix credo --strict` | Formatter and linter are two tools on the BEAM. Credo runs with its default checks in strict mode (Biome ran `recommended` + a few rules). |
| 2 | `eslint .` (eslint-plugin-project-structure) | `mix frame.lint_structure` (`scripts/lint_structure.ex`) | A custom task with the same tree semantics as `folder-structure.mjs`. See §3. |
| 3 | `depcruise src` | `mix frame.depcruise` (`scripts/depcruise.ex`) | **Order deviation:** runs *after* typecheck, because it reads the compiled BEAM files. `mix check` order: lint → structure → typecheck → depcruise → … |
| 4 | `tsc --noEmit` (strict) | `mix typecheck` = `mix compile --force --warnings-as-errors`, run by `mix check` in its own OS process | Elixir 1.20's built-in set-theoretic type checker reports type violations as warnings; every warning fails the gate. `--force` means a cached build can't hide warnings. A separate process is needed because Mix runs each task once per session, and loading the project's gate tasks can already have compiled the app. Without it, a cold-build type warning went unnoticed; this was a review finding on 8c1d453, now covered by a negative probe (§10). There is no Dialyzer run. That is a deliberate scope choice: it would add a second static checker that TS doesn't have. |
| 5 | `check:codegen-drift` | `mix frame.check_codegen_drift` | Testcontainers PG16 → migrate → regenerate into `tmp/` → compare trimmed contents → exit 1 on drift. A failed migration also exits 1, and the container is stopped in `after` (both verified, §10). |
| 6 | `vitest run --coverage` + per-file thresholds | `mix test.coverage` = `mix test --cover` with a custom `test_coverage` tool (`scripts/coverage_thresholds.ex`) | Thresholds on `Frame.Domain.Cat` and `Frame.UseCases.CreateCat`: lines ≥ 90 %, functions ≥ 90 %. **Deviation:** Erlang `:cover` has no branch metric, so the TS `branches ≥ 85` threshold has no equivalent. The report prints uncovered line numbers, like vitest's text reporter. |
| 7 | `tsx examples/create-cat.ts` | `MIX_ENV=test mix run examples/create_cat.exs` | Separate OS process, like `tsx`. |
| 8 | `tsx examples/create-cat.with-otel.ts` | `… examples/create_cat.with_otel.exs` | |
| 9 | `tsx examples/create-cat.hono.ts` | `… examples/create_cat.plug.exs` | |
| 10 | `node scripts/verify-hooks.js` | `mix frame.verify_hooks` | Same strength: presence + readability of `pre-commit` and `pre-push`. |
| – | `pnpm build` (tsup; **not** part of `pnpm check`) | `mix build` = `mix hex.build` (**not** part of `mix check`) | Produces `frame-0.1.0.tar` (lib, migrations, mix.exs, README). |

Coverage exclusions match the reference: generated schema (`Frame.Adapters.DbTypes.Cats` ≈ `*.generated.ts`), entry point (`Frame` ≈ `src/index.ts`) and testing helper (`Frame.Testing.*` ≈ `src/testing/**`). The test helpers (`Frame.Test.*`) and gate scripts (`Mix.Tasks.*`, `Frame.Scripts.*`) are also excluded. Those are compiled into the test build on the BEAM, while the TS coverage `include` simply never contained them (`src/**` only). No production module is excluded.

## 2. Layers and import-graph rules — checklist §2.1–2.2

| TS | Elixir | Notes |
|----|--------|-------|
| `src/domain/cat.ts` | `lib/frame/domain/cat.ex` (`Frame.Domain.Cat`) | Struct + types + boundary parsers. No I/O. |
| `src/use-cases/create-cat.ts` | `lib/frame/use_cases/create_cat.ex` (`Frame.UseCases.CreateCat.create_cat/2`) | Plain function, `(deps, input)`. |
| `src/adapters/cat-repository.ts` (interface) | `lib/frame/adapters/cat_repository.ex` (behaviour + dispatch) | **Idiomatic substitution:** a port is a behaviour whose implementations are structs. The port module dispatches on the struct (`%impl{} = repo -> impl.save(repo, cat)`), so callers depend only on the port. There's no DI container and no protocol magic. |
| `src/adapters/cat-repository.postgres.ts` | `lib/frame/adapters/cat_repository/postgres.ex` (`Frame.Adapters.CatRepository.Postgres`) | `<port>.<impl>.ts` → `<port>/<impl>.ex` (Elixir's file↔module convention). |
| `src/adapters/cat-repository.memory.ts` | `lib/frame/adapters/cat_repository/memory.ex` | State lives in an `Agent` (linked to the creator), replacing the `Map` instance field. |
| `src/adapters/database.ts` (`createDatabase(url)` → Kysely) | `lib/frame/adapters/database.ex` (`create_database(url)` → `%Database{pool}`) | An Ecto repo started per connection string (`name: nil`). Queries run through `Database.run/2` (Ecto dynamic repo, scoped and restored). The same factory is used by tests, examples and scripts. |
| `src/adapters/db-types.generated.ts` | `lib/frame/adapters/db_types.generated.ex` (Ecto schema `Frame.Adapters.DbTypes.Cats`) | Generated by `mix db.codegen` (≈ `kysely-codegen`). The adapter queries through this schema, so the typed representation is what the code uses. |
| `src/errors/*.error.ts` + `errors/index.ts` barrel | `lib/frame/errors/*_error.ex` | Exception structs (`defexception`) carrying `code`. **Deviation:** no barrel, since modules are addressed directly on the BEAM. |
| `src/observability/*` | `lib/frame/observability/*` | See §5. |
| `src/testing/observability.ts` (`frame/testing`) | `lib/frame/testing/observability.ex` (`Frame.Testing.Observability`) | Separate module. It is only compiled when the optional SDK dep is present (≈ optional peer deps). |
| `src/index.ts` + subpath exports | `lib/frame.ex` (`Frame`) | **Deviation:** Elixir has no export control, so every module is public. `Frame` documents the surface and delegates `create_cat/2`, `create_database/1` and `noop_tracer/0`. The concrete adapter (≈ `frame/adapters/postgres`) and the testing helper (≈ `frame/testing`) are reached by their own module names and are not mentioned on `Frame` as API. The "nothing internal uses the entry point" rule *is* enforced (rule 3). |
| DI by function arguments | `deps` map: `%{cat_repository:, clock:, observability:}` | No DI container, no app-env lookups for collaborators. |

**`mix frame.depcruise`, the dependency-cruiser equivalent.** For every module compiled from `lib/`, it reads the BEAM's debug info and records every module atom referenced anywhere in the code as an edge. That covers remote calls, struct literals, captures and **typespecs** (≈ `tsPreCompilationDeps: true`). Internal targets resolve to their source file; external targets resolve to their OTP application. Rules:

| TS rule | Elixir rule (same name) | Verified negative (scratch clone) |
|---------|-------------------------|-----------------------------------|
| `domain-no-external-imports` | `lib/frame/domain/` → any `lib/` file outside `domain/` | domain → `Database` call ⇒ exit 1; domain → error **struct literal only** ⇒ exit 1 |
| `use-cases-no-concrete-adapters` | `lib/frame/use_cases/` → `lib/frame/adapters/*/(postgres\|memory\|sqlite).ex` | use case → `CatRepository.Memory.new/0` ⇒ exit 1 |
| `no-internal-index-imports` | `lib/frame/**` → `lib/frame.ex` | observability → `Frame.noop_tracer/0` ⇒ exit 1 |
| `no-otel-sdk-in-production` | `lib/` except `lib/frame/testing/` → module of app `opentelemetry` / `opentelemetry_experimental` / `opentelemetry_exporter` | call to `:otel_simple_processor` ⇒ exit 1; **type-only** reference to an SDK module ⇒ exit 1; same call inside `lib/frame/testing/` ⇒ exit 0 (allowed) |
| `no-circular` | strongly connected components of the `lib/` file graph | A → B → A ⇒ exit 1 |

The SDK rule matches on the *OTP application* that owns the referenced module, not on a path regex. It is stricter than the TS path regex `@opentelemetry/sdk-`, and it can't be dodged by aliasing.

## 3. Structure / naming gate — checklist §2.3

`mix frame.lint_structure` mirrors `folder-structure.mjs`. Its scope is the same: the architectural directories only, source files only (`.ex`/`.exs`, the TS gate's `*.ts`), with `*.generated.*` ignored.

| TS rule | Elixir rule |
|---------|-------------|
| `src/{domain,use-cases,observability,testing}/{kebab}.ts`, flat | `lib/frame/{domain,use_cases,observability,testing}/{snake}.ex`, flat |
| `src/adapters/{kebab}.ts` + `{kebab}.{kebab}.ts` | `lib/frame/adapters/{snake}.ex` + `{snake}/{snake}.ex` (one level) |
| `src/errors/{kebab}.error.ts` + `index.ts` | `lib/frame/errors/{snake}_error.ex` |
| `src/index.ts` | `lib/frame.ex` |
| `tests/{unit,integration}/{kebab}.test.ts` + `{kebab}.{kebab}.test.ts` | `test/{unit,integration}/{snake}_test.exs` + `{snake}.{snake}_test.exs`, plus `test/test_helper.exs` |
| `tests/helpers/{kebab}.ts` + `{kebab}.{kebab}.ts` | `test/helpers/{snake}.ex` + `{snake}.{snake}.ex` |
| `examples/{kebab}.ts`, `.with-{kebab}.ts`, `.{kebab}.ts` | `examples/{snake}.exs`, `.with_{snake}.exs`, `.{snake}.exs` |
| `migrations/{snake_case}.ts` | `migrations/{snake_case}.exs` (e.g. `20260426_001_create_cats.exs`, the same name as TS) |
| `scripts/{kebab}.ts|js` | `scripts/{snake}.ex|exs` (the Mix tasks behind the gate) |

Verified negatives (exit 1): a CamelCase file in `domain/`, an unknown `lib/frame/services/` folder, a nested `domain/sub/`, and an error file without the `_error` suffix.

## 4. Domain contract — checklist §3

| TS | Elixir | Notes |
|----|--------|-------|
| `Cat {id, name, createdAt}` (readonly) | `%Cat{id, name, created_at}` (`@enforce_keys`, immutable data) | `createdAt` → `created_at` (Elixir naming). The HTTP JSON keeps `createdAt`. |
| `CatIdSchema = z.uuid()` | `Cat.parse_cat_id/1` | **The same regex as Zod v4's `z.uuid()`** (RFC 9562 variants + nil/max UUID). The fixed test UUID is accepted. Message: `Invalid UUID`. |
| `CatNameSchema` (trim, min 1, max 100) | `Cat.parse_cat_name/1` | Same messages (`Cat name must not be empty`, `Cat name must be 100 characters or fewer`). |
| `CreateCatInputSchema` | `Cat.parse_create_cat_input/1` | Collects issues in field order (`id`, `name`) and strips unknown keys. Type issues use Zod's wording (`Invalid input: expected string, received undefined`). |
| Zod (library) | hand-written parsers in the domain | **Deviation:** no validation library. Elixir has no Zod-equivalent in common use for plain data; Ecto changesets would pull Ecto into the domain. The parsers are pure and live in `domain/` exactly where the schemas lived. |
| **Quirk kept:** JS `String.prototype.trim` + `.length` | `Cat.trim_name/1` (exactly the ECMA-262 WhiteSpace + LineTerminator set) and `Cat.name_length/1` (UTF-16 code units) | Names are accepted and rejected identically to TS, including for astral-plane characters (counted as 2), U+FEFF (trimmed) and U+0085 (*not* trimmed). `cat.name.length` / `nameLength` report the same numbers. |
| `InvalidCatNameError` (`code` `INVALID_CAT_NAME`, `Invalid cat name: …`), also for a bad UUID | `%Frame.Errors.InvalidCatNameError{code, reason, message}` | Same code, prefix and semantics, including the historical "bad UUID ⇒ InvalidCatNameError". |
| `CatAlreadyExistsError` (`code` `CAT_ALREADY_EXISTS`) | `%Frame.Errors.CatAlreadyExistsError{code, name, message}` | **Quirk not replicated:** in TS, `this.name = 'CatAlreadyExistsError'` overwrites the `name` constructor property, so the cat's name is only in the message. In Elixir the exception *type* is the module, so `name` keeps the cat's name. |
| Errors are thrown | Typed errors are **returned**: `{:error, %InvalidCatNameError{}}` / `{:error, %CatAlreadyExistsError{}}`; `create_cat/2` → `{:ok, cat} \| {:error, error}`; `save/2` → `:ok \| {:error, …}` | **Idiomatic substitution.** Tagged tuples are the BEAM's typed-error convention. Unexpected failures (driver errors, bugs) still **raise**, after being recorded on the span (≈ TS rethrow). |
| `findById/findByName` → `Cat \| undefined` | `find_by_id/2`, `find_by_name/2` → `%Cat{} \| nil` | |
| `deleteById` → `boolean` | `delete_by_id/2` → `boolean` | |
| PG `23505` → `CatAlreadyExistsError` | `%Postgrex.Error{postgres: %{code: :unique_violation}}` (SQLSTATE 23505) → `CatAlreadyExistsError` | The driver error never reaches the caller. |
| **Quirk kept:** same-ID / different-name saves | Memory overwrites (`Map.put`, like `Map.set`). Postgres fails on the PK, and the PK violation is also 23505, so it becomes `CatAlreadyExistsError` | Not tested in either variant (the reference doesn't fix this contract). |
| Clock injected (`clock: () => Date`) | `clock: (-> DateTime.t())` | |
| Caller-provided IDs; HTTP generates one | Same (`Ecto.UUID.generate/0` in the HTTP handler only) | |

**Database and migration.** The Kysely migration `20260426_001_create_cats.ts` becomes the Ecto migration `migrations/20260426_001_create_cats.exs`, with the same table: `id uuid PK`, `name varchar(100) NOT NULL`, `created_at timestamptz NOT NULL DEFAULT now()`, and constraint `cats_name_unique UNIQUE (name)` (a constraint, not an index, as in TS). Ecto's version table (`schema_migrations`) replaces Kysely's. The DB codegen (`mix db.codegen`) introspects `information_schema` and writes the Ecto schema. Columns are sorted by name, like kysely-codegen, and nullability/default appear as comments, so changing them is also detected as drift.

## 5. Observability — checklist §4

| TS | Elixir | Notes |
|----|--------|-------|
| `@opentelemetry/api` only in `src/` | `opentelemetry_api` only in `lib/` (SDK `opentelemetry` is an `optional: true, runtime: false` dep) | No-op by default: without the SDK started, spans are no-ops. Enforced by depcruise rule 4. |
| `Observability {logger, tracer}` | `%Frame.Observability.Observability{logger, tracer}` | `tracer` is an OTel tracer (`{module, config}`). |
| Use case: `tracer.startActiveSpan('createCat', …)` | `:otel_tracer.with_span(observability.tracer, "createCat", …)` | One span per call. OK on success. On failure: `record_exception` + ERROR status (with message), then the same error is returned or re-raised. The span ends in the SDK's `after` (≈ `finally`). Attributes: `cat.id`, `cat.name.length` (no raw name). Logs `cat.created` with `catId`, `nameLength`. |
| Adapters: `trace.getTracer('frame')` at module level | `OpenTelemetry.Tracer.with_span` macros: the `:frame` *application* tracer, resolved at call time | **Idiomatic substitution:** a module attribute would freeze the no-op tracer at compile time. Resolving per call is the BEAM equivalent of the TS global proxy tracer. |
| Span names/attrs `db.cats.{save,findById,findByName,deleteById}`, `db.system` (`postgresql`/`memory`), `db.operation.name`, `db.collection.name` | identical | Status OK on success, exception event + ERROR on failure, the span always ends. |
| Parent/child via AsyncLocalStorage | Parent/child via the OTel process-local context (process dictionary) | **Deviation (runtime model):** context does not follow spawned processes automatically. All Frame spans run in the caller's process, so nesting is automatic here, as tested. |
| `ConsoleLogger` | `Frame.Observability.ConsoleLogger` | `[ISO ts] LEVEL message {json}`; INFO/DEBUG → stdout, WARN/ERROR → stderr (like Node's `console`); attrs block omitted when empty. |
| `NoopLogger` | `Frame.Observability.NoopLogger` | |
| `OtelLogger` → `@opentelemetry/api-logs` `logs.getLogger(name).emit(…)` | `Frame.Observability.OtelLogger` → OTP `:logger` events tagged with an OTel instrumentation scope (`otel_scope`) | **Idiomatic substitution:** on the BEAM, the OTel Logs *bridge API* is OTP `:logger` itself. The SDK side is `otel_log_handler` (`opentelemetry_experimental`). The consequence is that records also reach any other `:logger` handlers the app installed (e.g. the console), whereas TS records go only to the OTel provider. |
| Trace correlation (SDK reads the active context) | The trace/span IDs travel in the process logger metadata, **re-derived from the active OTel context on every call** | Found while porting: the Erlang API writes the IDs into logger metadata when a span starts but never clears them. The "outside span" test therefore emits *after* a finished span in the same process, which is the same sequencing as the TS file, and it was red before the fix. |
| `noopTracer()` = `trace.getTracer('frame-noop')` | `noop_tracer/0` = `{:otel_tracer_noop, []}` | **Deviation:** always no-op, as the TS doc promises. The TS one becomes a real tracer if a provider is registered. In Erlang a named tracer obtained before the SDK starts would also be cached as no-op forever, so the explicit no-op tracer is the predictable choice. |
| Re-exports `trace`, `SpanKind`, `SpanStatusCode`, `Span`, `Tracer` types | `Frame.Observability.Tracer` exports the `t()`/`span()` types | **Deviation:** Elixir can't re-export modules. Consumers use `OpenTelemetry.*` directly. |
| `createTestObservability()` → `{observability, getSpans, reset, shutdown}` (NodeTracerProvider + InMemorySpanExporter) | `Frame.Testing.Observability.create_test_observability/0` → handle; `get_spans/1`, `reset/1`, `shutdown/1` (SDK started with a simple processor + an in-memory exporter) | Spans are flattened to maps (`name`, `trace_id`, `span_id`, `parent_span_id`, `attributes`, `status`, `events`). **Deviation:** the Erlang SDK reads its config once at start and can't be unregistered (no `trace.disable()`), so `shutdown/1` only detaches the collector. Span-asserting test modules are `async: false` because the exporter is VM-global (vitest isolates files in workers instead). |
| `tests/helpers/observability.ts` (a duplicate of `src/testing`) | `test/helpers/observability.ex` delegates to `Frame.Testing.Observability` | Frame's own tests exercise the exported helper rather than a copy. |
| OtelLogger test: `InMemoryLogRecordExporter` + `LoggerProvider` | The real `otel_log_handler` (logs SDK) installed as a `:logger` handler, with an in-memory `otel_exporter_logs` exporter defined in the test | **Deviation:** the SDK's OTLP record conversion (`otel_otlp_logs`) needs `opentelemetry_exporter`, which this project doesn't depend on. The exporter stores what the SDK handler batched: scope, level, body and metadata. Assertions use the BEAM's severity (`:info`/`:warning`/`:error`/`:debug`) instead of OTLP `severityNumber`/`severityText`. Trace and span IDs are compared as hex against the real span. The handler exports in 5 ms batches, so the test waits for records (bounded at 2 s). |

## 6. Tests — checklist §5

The same 8 test files and **72 tests** as the reference (TS: 8 files / 72 tests).

| TS file (tests) | Elixir file (tests) | Notes |
|-----------------|---------------------|-------|
| `unit/cat-domain.test.ts` (13) | `unit/cat_domain_test.exs` (13) | Same cases. |
| `unit/cat-property.test.ts` (3, fast-check, 50/100/100 runs) | `unit/cat_property_test.exs` (3, StreamData, `max_runs` 50/100/100) | Generator: `string(:printable)`, i.e. **arbitrary printable Unicode**, wider than fast-check v4's default `string()` (printable ASCII). Filters use the same JS trim/UTF-16 semantics. Round-trip goes through the memory adapter only. |
| `unit/cat-repository.memory.test.ts` (12) | `unit/cat_repository.memory_test.exs` (12) | Shared conformance suite. |
| `unit/logger.test.ts` (6) | `unit/logger_test.exs` (6) | stdout/stderr captured with `ExUnit.CaptureIO` (≈ `vi.spyOn(console…)`). |
| `unit/otel-logger.test.ts` (8) | `unit/otel_logger_test.exs` (8) | See §5. |
| `integration/cat-repository.postgres.test.ts` (12 + 1) | `integration/cat_repository.postgres_test.exs` (12 + 1) | Same shared conformance suite, plus the real concurrency test (two simultaneous `Task`s, one ok + one `CatAlreadyExistsError`). |
| `integration/create-cat.test.ts` (16) | `integration/create_cat_test.exs` (16) | Same scenarios, including parent/child span, shared trace id, `cat.name.length == 7`, and error recording on both spans. |
| `integration/migration.test.ts` (1) | `integration/migration_test.exs` (1) | Real container: up → `cats` present → down 1 step → absent. |
| `helpers/cat-repository.conformance.ts` (`describeCatRepositoryConformance`) | `helpers/cat_repository.conformance.ex` (`use Frame.Test.CatRepositoryConformance, factory:, reset_state:, expected_db_system:`) | One definition, executed against both adapters. |
| `helpers/test-db.ts` (Testcontainers `PostgreSqlContainer('postgres:16')`) | `helpers/test_db.ex` (testcontainers-elixir `PostgresContainer` `postgres:16`, Ryuk reaper) | Uses the production `create_database/1`; migration failure → pool closed + container stopped + raise. One container per test module (`setup_all`) and truncation per test (`DELETE FROM cats`). Cleanup runs in `on_exit`, even on failure. |

There are no mocks: Postgres is real (container), HTTP is real (Bandit on a socket, `:httpc` client), and OTel is the real SDK with in-memory exporters. There are no skip tags, `--only`/`--exclude` filters or excluded tags in the check.

**Runtime deviation:** vitest runs test files in parallel workers. ExUnit runs every module that touches adapters or spans with `async: false` (one VM, one global OTel SDK), so the three integration containers start one after another. Pure unit modules (domain, logger) are `async: true`.

## 7. HTTP example — checklist §6

| TS (Hono + `@hono/node-server`) | Elixir (Plug.Router + Bandit) |
|---------------------------------|-------------------------------|
| `POST /cats` → `createCat` with a generated UUID | same; the body is parsed by `Plug.Parsers` (`JSON`); a non-string `name` becomes `""` as in TS |
| 201 + cat JSON / 409 `{error, message}` / 400 `{error, message}` | same (`{"id","name","createdAt"}`) |
| unexpected error → rethrown to the framework | not matched → raises inside the Plug pipeline → Bandit's 500 |
| `GET /cats/:id` → 200 / 404 `{error: "NOT_FOUND"}` | same (route present; like TS, the demo doesn't self-request a missing id) |
| `serve({port: 0})`, self-`fetch` | `Bandit.start_link(port: 0, ip: :loopback)` + `ThousandIsland.listener_info/1`, real requests over `:httpc` |
| `finally`: `server.close`, then `teardown()` | `after`: `Supervisor.stop(server)`, then `TestDb.teardown/1` |

Plug + Bandit, not Phoenix: the example needs only routing + JSON. Both are dev/test deps only, as Hono is a devDependency in TS.

## 8. Examples, hooks, workflow docs — checklist §8–9

| TS | Elixir |
|----|--------|
| `examples/create-cat.ts` | `examples/create_cat.exs`: create → fetch → delete → confirm `nil` |
| `examples/create-cat.with-otel.ts` (NodeTracerProvider + ConsoleSpanExporter) | `examples/create_cat.with_otel.exs`: starts the SDK with a simple processor + `otel_exporter_stdout`; prints `createCat` → child `db.cats.save` (same trace, parent id = createCat span id), `db.cats.findById`, `db.cats.deleteById`; force-flush + stop |
| `.husky/pre-commit` (`lint-staged` → `biome check --write`) | `.githooks/pre-commit`: `mix format` on staged `*.ex/*.exs` + re-stage |
| `.husky/pre-push` (`pnpm check`) | `.githooks/pre-push` (`mix check`) |
| husky install via `prepare` | `mix setup` runs `git config core.hooksPath .githooks` |
| `.claude/CLAUDE.md`, `workflow.md`, `commands/{write,implement}-spec.md` | Same documents, adapted to Elixir paths and commands. Content is unchanged: the 5-step role-separated TDD, no test edits by the implementer, no `--no-verify`, no skip tags/filters. |
| `README.md`, `CONTRIBUTING.md` | Rewritten for Elixir with the same sections |
| `docker/docker-compose.yml`, `.env.example` | unchanged (`mix db.up/down/reset/migrate/codegen` aliases) |
| `WAVE_*` hand-off docs, TS config files | removed (TS-specific history; the branch is pure Elixir) |

## 9. Extras and benchmark fairness — checklist §11

Nothing functional was added: no endpoints, use cases, business rules or adapters. Elixir-side differences that a reviewer might count:

- **The coverage report lists uncovered line numbers.** It's a reporting nicety, the same information vitest's text reporter shows.
- **The property generator is wider** (Unicode vs ASCII). The test is stricter, not easier.
- **The depcruise SDK rule is app-based** rather than a path regex. It is stricter.
- **The OtelLogger "outside span" test emits after a finished span.** That's the same sequencing as the TS file, made explicit because the BEAM runs each test in a fresh process.
- **No branch-coverage threshold** (`:cover` limitation). This makes the Elixir gate *weaker* on that one axis.
- **No Dialyzer.** The compiler's type checker with warnings-as-errors stands in for `tsc`.

## 10. Negative gate checks run (scratch clone, never on the branch)

| Violation | Command | Result |
|-----------|---------|--------|
| domain → adapter (call) | `mix frame.depcruise` | exit 1, `domain-no-external-imports` |
| domain → error (struct literal only) | `mix frame.depcruise` | exit 1 |
| use case → concrete adapter | `mix frame.depcruise` | exit 1, `use-cases-no-concrete-adapters` |
| internal → `lib/frame.ex` | `mix frame.depcruise` | exit 1, `no-internal-index-imports` |
| SDK call in production / type-only SDK ref | `mix frame.depcruise` | exit 1, `no-otel-sdk-in-production` |
| SDK call inside `lib/frame/testing/` | `mix frame.depcruise` | exit 0 (allowed, like `src/testing/`) |
| cycle A ↔ B | `mix frame.depcruise` | exit 1, `no-circular` |
| bad file name / unknown folder / nested domain dir / bad error name | `mix frame.lint_structure` | exit 1 |
| edited generated schema | `mix frame.check_codegen_drift` | exit 1, container stopped |
| broken migration | `mix frame.check_codegen_drift` | exit 1, container stopped |
| `.githooks/pre-push` removed | `mix frame.verify_hooks` | exit 1 |
| unused variable (compiler warning) | `mix typecheck` | exit 1 |
| type warning (`value <> "bad"` with an integer `value`) in a new domain module, **cold app build** (`rm -rf _build/test/lib/frame`) | **`mix check`** | exit 1 (`Compilation failed due to warnings…`); the same with a warm cache; control (cold, no bad module) exit 0 |
| unformatted file | `mix lint` | exit 1 |
| one failing test | **`mix check`** | exit 2, stops before the examples |
| coverage below threshold (during development) | `mix test.coverage` | exit 1, `Coverage thresholds not met` |

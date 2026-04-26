# Frame — Agent Operating Instructions

## Rules

1. **NEVER use `--no-verify` when committing or pushing.** The pre-push hook running `pnpm check` is the canonical and only quality gate. If it fails, fix the code. Do not bypass the gate.
2. **NEVER skip git hooks.** If hooks are broken, fix them. Do not work around them.
3. **Run `pnpm check` before considering any work complete.** All checks must pass: lint, dependency-cruiser, typecheck, codegen drift, tests with coverage, examples, hook verification.
4. **Do not export concrete adapter implementations from `src/index.ts`.** Only types, interfaces, use cases, and errors belong in the public surface. Concrete adapters use subpath exports (e.g., `frame/adapters/postgres`).
5. **Domain files (`src/domain/`) must not import from any other layer.** This is enforced by dependency-cruiser and is an architectural invariant.
6. **Use cases (`src/use-cases/`) may import from `src/domain/` and adapter interfaces, but never from concrete adapter implementations.**
7. **Pass dependencies as function arguments.** No DI containers, no decorators, no global state.
8. **Validation (Zod) happens only at external boundaries**, not inside domain or use-case logic.
9. **When adding a new migration, always run `pnpm db:codegen` afterwards** and commit the updated `src/adapters/db-types.generated.ts`.
10. **Tests must be self-contained.** Integration tests use Testcontainers — they do not depend on a running Docker Compose stack.

## Observability Instrumentation Rules

### Span Placement

- **Every use case** wraps in exactly one span named after the use case (`createCat`, `findCatById`, etc.). The span captures non-PII input attributes, records exceptions, and sets error status on failure.
- **Every adapter method** wraps in one span named `db.<table>.<method>` (e.g., `db.cats.save`, `db.cats.findById`). Set OTel semantic attributes: `db.system`, `db.operation.name`, `db.collection.name`.
- **The memory adapter is instrumented identically to the Postgres adapter.** Same span names, same attributes (`db.system` = `"memory"`). The conformance suite asserts both produce equivalent spans.
- **Errors** are recorded on the active span via `span.recordException()` and `span.setStatus({ code: SpanStatusCode.ERROR })` before being rethrown.

### What NOT to Instrument

- **Do NOT instrument:** Zod validation, domain pure functions, value object construction, any sub-millisecond deterministic operation.
- **PII discipline:** span attributes capture shapes (e.g., `cat.name.length`), not raw values. The Cat domain is placeholder data, but the pattern hardens here for real domains later.

### Adapters Do Not Log

- **Adapters emit spans only.** Adapters do not call the Logger. Spans already carry operation name, attributes, and exceptions via `recordException` — logging the same information separately is noise.
- **Logs come from use cases**, where they describe meaningful business events (e.g., `cat.created`).

### Adapter Tracing Pattern

- Adapters use `trace.getTracer('frame')` at **module level** (not in constructors).
- Adapter methods call `tracer.startActiveSpan(...)` directly.
- Spans automatically nest under the active parent span via OTel's AsyncLocalStorage-backed context propagation. No manual threading.
- The `CatRepository` interface has no observability dependency. Adapters import `trace` from `@opentelemetry/api` directly.

### API vs. SDK Boundary

- **Production code (`src/`) only imports the OTel API** (`@opentelemetry/api`, `@opentelemetry/api-logs`). The API is no-op safe — without an SDK registered, all operations silently do nothing.
- **The OTel SDK is used only in:** `tests/helpers/observability.ts`, `src/testing/observability.ts` (exported for consumers), and `examples/create-cat.with-otel.ts`.
- **This boundary is enforced by dependency-cruiser** (`no-otel-sdk-in-production` rule). If you add an SDK import inside `src/` (outside `src/testing/`), the build will fail.

### Observability in Use Case Dependencies

- Use cases receive `observability: Observability` (Logger + Tracer) via the deps argument.
- Adapters do NOT receive Observability — they use the OTel context API directly.
- This keeps one DI style (functional argument passing) across the codebase.

## Project Structure

```
src/domain/         — Types, entities, value objects. No I/O.
src/use-cases/      — One file per use case. Pure functions taking deps as args.
src/adapters/       — Infrastructure: interfaces + implementations.
src/errors/         — Typed error classes.
src/observability/  — Logger interface, implementations, tracer re-exports, Observability type.
src/testing/        — Exported test helpers (frame/testing subpath). Uses OTel SDK.
src/index.ts        — Public API surface.
tests/unit/         — Unit + property-based tests.
tests/integration/  — Tests against real Postgres via Testcontainers.
tests/helpers/      — Shared test utilities (test DB, test observability, conformance suites).
examples/           — Runnable examples (executed in CI).
migrations/         — Kysely migration files.
scripts/            — Build/check scripts.
```

## Adding a New Use Case

1. Define types in `src/domain/`.
2. Define the repository interface in `src/adapters/`.
3. Write the use case in `src/use-cases/` as a pure function taking deps as args.
   - Include `observability: Observability` and `clock: () => Date` in deps.
   - Wrap the use case body in `tracer.startActiveSpan('useCaseName', ...)`.
   - Log meaningful business events via `logger.info(...)`.
4. Add typed errors in `src/errors/`.
5. Instrument adapter methods with `trace.getTracer('frame')` at module level.
   - Span name: `db.<table>.<method>`.
   - Set `db.system`, `db.operation.name`, `db.collection.name` attributes.
   - Adapters do NOT log — spans only.
6. Export public types and use case from `src/index.ts`.
7. Write unit tests in `tests/unit/`.
8. Write integration tests in `tests/integration/`.
9. Add span assertions to the conformance test suite.
10. Run `pnpm check` — all green before committing.

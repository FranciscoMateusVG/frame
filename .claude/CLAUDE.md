# Frame (Elixir) — Agent Operating Instructions

## Rules

1. **NEVER use `--no-verify` when committing or pushing.** The pre-push hook running `mix check` is the canonical and only quality gate. If it fails, fix the code. Do not bypass the gate.
2. **NEVER skip git hooks.** If hooks are broken, fix them. Do not work around them.
3. **Run `mix check` before considering any work complete.** All checks must pass: lint, structure, typecheck, depcruise, codegen drift, tests with coverage, examples, hook verification.
4. **Do not surface concrete adapter implementations from `lib/frame.ex`.** Only types, ports, use cases, and errors belong in the public surface. Concrete adapters live in their own modules (e.g., `Frame.Adapters.CatRepository.Postgres`).
5. **Domain files (`lib/frame/domain/`) must not depend on any other layer.** This is enforced by `mix frame.depcruise` and is an architectural invariant.
6. **Use cases (`lib/frame/use_cases/`) may depend on `lib/frame/domain/` and adapter ports, but never on concrete adapter implementations.**
7. **Pass dependencies as function arguments.** No DI containers, no application-env lookups for collaborators, no global state.
8. **Validation (the domain `parse_*` functions) happens only at external boundaries**, not deeper inside domain or use-case logic.
9. **When adding a new migration, always run `mix db.codegen` afterwards** and commit the updated `lib/frame/adapters/db_types.generated.ex`.
10. **Tests must be self-contained.** Integration tests use Testcontainers — they do not depend on a running Docker Compose stack.

## Observability Instrumentation Rules

### Span Placement

- **Every use case** wraps in exactly one span named after the use case (`createCat`, `findCatById`, etc.), via `:otel_tracer.with_span(observability.tracer, ...)`. The span captures non-PII input attributes, records exceptions, and sets error status on failure.
- **Every adapter function** wraps in one span named `db.<table>.<method>` (e.g., `db.cats.save`, `db.cats.findById`). Set OTel semantic attributes: `db.system`, `db.operation.name`, `db.collection.name`.
- **The memory adapter is instrumented identically to the Postgres adapter.** Same span names, same attributes (`db.system` = `"memory"`). The conformance suite asserts both produce equivalent spans.
- **Errors** (returned `{:error, exception}` or raised) are recorded on the active span via `OpenTelemetry.Span.record_exception/3` and `set_status(span, OpenTelemetry.status(:error, ...))` before being returned or re-raised.

### What NOT to Instrument

- **Do NOT instrument:** boundary parsing/validation, domain pure functions, value construction, any sub-millisecond deterministic operation.
- **PII discipline:** span attributes capture shapes (e.g., `cat.name.length`), not raw values. The Cat domain is placeholder data, but the pattern hardens here for real domains later.

### Adapters Do Not Log

- **Adapters emit spans only.** Adapters do not call the Logger. Spans already carry operation name, attributes, and exceptions via `record_exception` — logging the same information separately is noise.
- **Logs come from use cases**, where they describe meaningful business events (e.g., `cat.created`).

### Adapter Tracing Pattern

- Adapters use the `OpenTelemetry.Tracer` macros (`require OpenTelemetry.Tracer, as: Tracer`), which resolve the tracer of the `:frame` application at call time — the equivalent of a module-level `trace.getTracer('frame')`.
- Adapter functions call `Tracer.with_span(...)` directly.
- Spans automatically nest under the active parent span via OTel's process-local context. No manual threading. (Context does not cross process boundaries by itself — pass it explicitly if you spawn.)
- The `CatRepository` port has no observability dependency. Adapters use `opentelemetry_api` directly.

### API vs. SDK Boundary

- **Production code (`lib/`) only uses the OTel API** (`opentelemetry_api`, and OTP `:logger` for logs). The API is no-op safe — without the SDK started, all operations silently do nothing.
- **The OTel SDK is used only in:** `lib/frame/testing/observability.ex` (exported for consumers, compiled only when the optional SDK dep is present), the tests, and `examples/create_cat.with_otel.exs`.
- **This boundary is enforced by `mix frame.depcruise`** (`no-otel-sdk-in-production` rule). If you reference an SDK module inside `lib/` (outside `lib/frame/testing/`), the build will fail.

### Observability in Use Case Dependencies

- Use cases receive `observability: %Observability{logger, tracer}` via the deps argument.
- Adapters do NOT receive Observability — they use the OTel context API directly.
- This keeps one DI style (functional argument passing) across the codebase.

## Project Structure

```
lib/frame/domain/         — Structs, value types, boundary parsers. No I/O.
lib/frame/use_cases/      — One file per use case. Plain functions taking deps as args.
lib/frame/adapters/       — Infrastructure: ports (behaviours) + implementations (<port>/<impl>.ex).
lib/frame/errors/         — Typed errors (exception structs, *_error.ex).
lib/frame/observability/  — Logger port, implementations, tracer helpers, Observability struct.
lib/frame/testing/        — Exported test helpers (Frame.Testing). Uses the OTel SDK.
lib/frame.ex              — Public API surface.
test/unit/                — Unit + property-based tests.
test/integration/         — Tests against real Postgres via Testcontainers.
test/helpers/             — Shared test utilities (test DB, test observability, conformance suites).
examples/                 — Runnable examples (executed by mix check).
migrations/               — Ecto migration files.
scripts/                  — Mix tasks behind the gate (build/check scripts).
```

## Adding a New Use Case

1. Define types and boundary parsers in `lib/frame/domain/`.
2. Define the repository port (behaviour + dispatch functions) in `lib/frame/adapters/`.
3. Write the use case in `lib/frame/use_cases/` as a plain function taking deps as args.
   - Include `observability` and `clock` in deps.
   - Wrap the use case body in `:otel_tracer.with_span(tracer, "useCaseName", %{}, fn span -> ... end)`.
   - Log meaningful business events via `Frame.Observability.Logger.info(...)`.
4. Add typed errors in `lib/frame/errors/`.
5. Instrument adapter functions with `OpenTelemetry.Tracer.with_span`.
   - Span name: `db.<table>.<method>`.
   - Set `db.system`, `db.operation.name`, `db.collection.name` attributes.
   - Adapters do NOT log — spans only.
6. Document the public modules and delegate the use case from `lib/frame.ex`.
7. Write unit tests in `test/unit/`.
8. Write integration tests in `test/integration/`.
9. Add span assertions to the conformance test suite.
10. Run `mix check` — all green before committing.

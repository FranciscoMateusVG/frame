# Print portal (Elixir, on Frame) — Agent Operating Instructions

## Rules

1. **NEVER use `--no-verify` when committing or pushing.** The pre-push hook running `mix check` is the canonical and only quality gate. If it fails, fix the code. Do not bypass the gate.
2. **NEVER skip git hooks.** If hooks are broken, fix them. Do not work around them.
3. **Run `mix check` before considering any work complete.** All checks must pass: lint, structure, typecheck, depcruise, tests with coverage, examples, hook verification.
4. **Do not surface concrete adapter implementations from `lib/frame.ex`.** Only types, ports, use cases, and errors belong in the public surface. Concrete adapters live in their own modules (e.g., `Frame.Adapters.PrintApi.Http`) and are named only by the composition root `lib/frame/application.ex` — never by `lib/frame/web/` (enforced by `mix frame.depcruise`).
5. **Domain files (`lib/frame/domain/`) must not depend on any other layer.** This is enforced by `mix frame.depcruise` and is an architectural invariant.
6. **Use cases (`lib/frame/use_cases/`) may depend on `lib/frame/domain/` and adapter ports, but never on concrete adapter implementations.**
7. **Pass dependencies as function arguments.** No DI containers, no application-env lookups for collaborators, no global state.
8. **Validation (the domain `parse_*` functions) happens only at external boundaries**, not deeper inside domain or use-case logic.
9. **No database, no object storage.** The portal talks only to the Incluir Hono API (`Frame.Adapters.PrintApi`) with the server-only service token. Sessions and login limits are in memory (single replica).
10. **Tests must be self-contained and go through real boundaries.** The HTTP adapter is tested over real sockets against `Frame.Test.FakeHono`; the portal through its endpoint (ConnTest/LiveViewTest) with the real HTTP adapter talking to FakeHono over a real socket; the in-memory fake is for pure logic and examples. Every PrintApi behaviour goes in the shared conformance suite (`test/helpers/print_api.conformance.ex`).
11. **Never log or trace content or secrets:** passwords, tokens, CSRF tokens, session ids, instructions, file names, document bytes, amounts. `test/integration/confidentiality_test.exs` guards this.

## Observability Instrumentation Rules

### Span Placement

- **Every use case** wraps in exactly one span named after the use case (`listOrders`, `collectFiles`, etc.), via `:otel_tracer.with_span(observability.tracer, ...)`. The span captures non-PII input attributes, records the error type, and sets error status on failure.
- **Every adapter function** wraps in one span: `http.print_api.<operation>` (PrintApi), `session.<op>`, `login_limiter.<op>`. HTTP client spans carry method, `url.template` and status — never URLs with ids, bodies or headers.
- **The memory PrintApi is instrumented like the HTTP one** (same span names, `peer.service` = `"memory"`).
- **Errors** (returned `{:error, exception}` or raised) are recorded on the active span as **type only**: `error.type` (the exception module or the contract code) + `set_status(span, OpenTelemetry.status(:error, <fixed text>))`. **Never `record_exception`** and never the message or stack trace — they may carry request data (§5 confidentiality; guarded by `test/integration/confidentiality_test.exs`, which re-reads the exported spans).

### What NOT to Instrument

- **Do NOT instrument:** boundary parsing/validation, domain pure functions, value construction, any sub-millisecond deterministic operation.
- **PII discipline:** span attributes capture shapes (ids, statuses, byte counts), not raw values.

### Adapters Do Not Log

- **Adapters emit spans only.** Adapters do not call the Logger. Spans already carry operation name, attributes, and exceptions via `record_exception` — logging the same information separately is noise.
- **Logs come from use cases** (business events such as `order.files_collected`) **and the web edge** (`Frame.Web.Edge`: one `http.request` access line with the route template). Phoenix's and LiveView's own loggers are off (they print params); LiveView callbacks get spans from `Frame.Web.LiveTelemetry`; crash reports are reduced to the exception type by `Frame.Observability.CrashReports`.

### Adapter Tracing Pattern

- Adapters use the `OpenTelemetry.Tracer` macros (`require OpenTelemetry.Tracer, as: Tracer`), which resolve the tracer of the `:frame` application at call time — the equivalent of a module-level `trace.getTracer('frame')`.
- Adapter functions call `Tracer.with_span(...)` directly.
- Spans automatically nest under the active parent span via OTel's process-local context. No manual threading. (Context does not cross process boundaries by itself — pass it explicitly if you spawn.)
- Ports have no observability dependency. Adapters use `opentelemetry_api` directly.

### API vs. SDK Boundary

- **Production code (`lib/`) only uses the OTel API** (`opentelemetry_api`, and OTP `:logger` for logs). The API is no-op safe — without the SDK started, all operations silently do nothing.
- **The OTel SDK is used only in:** `lib/frame/testing/observability.ex` (compiled only when the optional SDK dep is present), the tests, and `examples/portal_journey.with_otel.exs`.
- **This boundary is enforced by `mix frame.depcruise`** (`no-otel-sdk-in-production` rule). If you reference an SDK module inside `lib/` (outside `lib/frame/testing/`), the build will fail.

### Observability in Use Case Dependencies

- Use cases receive `observability: %Observability{logger, tracer}` via the deps argument.
- Adapters do NOT receive Observability — they use the OTel context API directly.
- This keeps one DI style (functional argument passing) across the codebase.

## Project Structure

```
lib/frame/application.ex  — Composition root (the only place naming concrete adapters).
lib/frame/config.ex       — Env → Config, fail closed.
lib/frame/domain/         — Pure: Order, Batch, Close, Contract, Competence, Money, Document, Requests, Session, LoginThrottle.
lib/frame/use_cases/      — One file per use case. Plain functions taking deps as args.
lib/frame/adapters/       — Ports (behaviours) + implementations (<port>/<impl>.ex).
lib/frame/web.ex          — `use Frame.Web, :controller | :live_view | :html`.
lib/frame/web/            — Phoenix edge: Endpoint, Edge, Router, controllers/, live/, LiveAuth, SessionCookieStore, Security, Multipart, Reply, Intent, Components, Layouts.
lib/frame/errors/         — PortalError.
lib/frame/observability/  — Logger port, implementations, tracer helpers, Observability struct.
lib/frame/testing/        — Exported test helpers (Frame.Testing). Uses the OTel SDK.
lib/frame.ex              — Public API surface.
test/unit/                — Unit + property tests (domain, memory adapters, contract).
test/integration/         — HTTP adapter vs FakeHono (real sockets), the portal via ConnTest/LiveViewTest (async, one world per test), the release children on a real port, confidentiality.
test/helpers/             — FakeHono, Portal harness, conformance suite, test observability.
test/fixtures/            — Frozen upstream schema + fixtures (copied from monorepo-incluir).
examples/                 — Runnable examples (executed by mix check).
scripts/                  — Mix tasks behind the gate.
```

## Adding a New Use Case

1. Types and boundary parsers in `lib/frame/domain/`.
2. A port function (behaviour callback + dispatch) in `lib/frame/adapters/<port>.ex`, implemented in every adapter, and a case in the conformance suite.
3. The use case in `lib/frame/use_cases/`: deps as the first argument, exactly one span named after the use case (`UpstreamCall.run/4` for upstream calls), business log on success.
4. The route in `lib/frame/web/` — a controller action for the JSON API, a LiveView event for the pages (parse at the edge with `Frame.Domain.Requests`).
5. Tests: `Phoenix.ConnTest` / `Phoenix.LiveViewTest` via `use Frame.Test.PortalCase, async: true`, each test in its own `Frame.Test.Portal.start/1` world.
6. Unit tests, a black-box test through the portal, and a confidentiality check if it handles content.
7. `mix check` — all green before committing.

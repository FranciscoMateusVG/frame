# Wave 2 Plan: Observability

## Open Questions — Decisions

### Q1: OTel Semantic Conventions — Partial Adoption

**Decision: Adopt the stable subset, skip the verbose rest.**

Use these semantic convention attributes on DB spans:
- `db.system` → `"postgresql"` or `"memory"`
- `db.operation.name` → `"INSERT"`, `"SELECT"`, `"DELETE"`
- `db.collection.name` → `"cats"` (the table name)

Skip `db.statement` — it's a PII vector and adds complexity for a skeleton. Skip `db.namespace` (schema name) — overkill for a single-schema project. Skip `server.address`/`server.port` — the connection string is the consumer's concern.

**Why partial:** The three attributes above give enough data to filter and group spans in any backend (Jaeger, Honeycomb, Datadog). Full semantic conventions add 15+ attributes that make the instrumentation code harder to read than the business logic it wraps. Frame is a *template* — readability matters more than exhaustiveness. Consumers can extend with more attributes when they fork.

### Q2: OTel SDK Version Pinning — Exact Pins for SDK, Caret for API

**Decision: Split strategy.**

- `@opentelemetry/api` and `@opentelemetry/api-logs` (runtime deps): **caret ranges** (`^1.x.x`). The API is stable, backward-compatible by design, and no-op safe. Caret lets consumers' SDK versions satisfy the peer dep range naturally.
- `@opentelemetry/sdk-trace-base` and `@opentelemetry/sdk-trace-node` (devDeps): **exact pins**. These are test/example-only. OTel SDK packages break on minor versions often enough to matter. Exact pins prevent Dependabot from silently introducing breaking changes into the test suite. Update them manually when needed.

### Q3: `createTestObservability()` — Export Under `frame/testing` Subpath

**Decision: Export it.**

Consumers writing their own use cases on Frame will need span assertions in their tests. Keeping this internal forces them to reinvent it — poorly. Export under `frame/testing` subpath so it stays out of the production bundle. Same pattern as `frame/adapters/postgres`.

This means adding a third subpath export and a new tsup entry point for `testing`. The helper only pulls in the OTel SDK, which is already a devDep for consumers via peer deps.

### Q4: Auto-Instrumentation — Document as Optional

**Decision: Mention, don't prescribe or discourage.**

Frame's manual instrumentation is deliberate — spans at architectural boundaries, not at every pg query. Auto-instrumentation (`@opentelemetry/instrumentation-pg`) adds query-level spans automatically. These are complementary, not competing.

In the README observability section, add one paragraph: *"Consumers may additionally install `@opentelemetry/instrumentation-pg` for automatic query-level Postgres tracing. Frame's manual spans remain valuable for use-case-level and repository-level visibility."* Don't actively discourage it — that's opinionated in the wrong direction for a library.

### Q5: Span Naming — `db.<table>.<operation>`

**Decision: `db.<table_name>.<method_name>` where table is the SQL table name (plural, lowercase).**

- `db.cats.save`, `db.cats.findById`, `db.cats.findByName`, `db.cats.deleteById`
- When forked for EuNeném: `db.registries.save`, `db.gifts.findById`, `db.guests.deleteById`

The table name IS the namespace. No aggregate prefix needed because in Frame's architecture, each repository maps to one table. The method name maps to the CatRepository interface method, not the SQL operation — this gives use-case-level context at the span name level while `db.operation.name` carries the SQL verb.

For use-case spans: just the function name. `createCat`, `findCatById`, etc. When forked: `createRegistry`, `findGift`. Clean, predictable, grep-able.

---

## Execution Plan

### Phase 0: Dependencies & Scaffolding
1. Add runtime deps: `@opentelemetry/api`, `@opentelemetry/api-logs`
2. Add dev deps: `@opentelemetry/sdk-trace-base`, `@opentelemetry/sdk-trace-node`, `@opentelemetry/sdk-logs`
3. Create `src/observability/` directory with the 6 files
4. Add `frame/testing` subpath export to package.json and tsup config

### Phase 1: Core Observability Types
5. `src/observability/logger.ts` — Logger interface
6. `src/observability/noop-logger.ts` — NoopLogger
7. `src/observability/console-logger.ts` — ConsoleLogger (timestamp + level + pretty output)
8. `src/observability/otel-logger.ts` — OtelLogger (forwards to `@opentelemetry/api-logs`, attaches trace context)
9. `src/observability/tracer.ts` — Re-exports `Tracer`, `Span`, `SpanStatusCode`, `SpanKind` from `@opentelemetry/api` + `noopTracer` factory
10. `src/observability/observability.ts` — `Observability` interface bundling logger + tracer

### Phase 2: Instrument createCat + Adapters
11. Update `CreateCatDeps` to include `observability: Observability` and `clock: () => Date`
12. Refactor `createCat` to wrap in a span, log success/failure, use clock for timestamp
13. Refactor `CatRepositoryPostgres` — constructor takes `Observability`, every method wraps in a span with semantic attributes
14. Refactor `CatRepositoryMemory` — identical instrumentation to Postgres adapter (same span names, same attributes)
15. Update `CatRepository` interface — constructor-level observability is an adapter concern, not a port concern. The interface stays clean; adapters accept observability in their constructors.

### Phase 3: Test Infrastructure
16. Create `tests/helpers/observability.ts` — `createTestObservability()` returning `{ observability, getSpans(), reset() }`
17. Also create `src/testing/observability.ts` as the exported version for consumers
18. Refactor all existing tests to pass observability dep (integration tests, conformance suite)

### Phase 4: Observability Tests
19. Add span assertions to conformance suite — every repo method must produce a span with correct name and attributes
20. Add integration test asserting createCat parent-child span relationship
21. Add integration test asserting error path records exception on span

### Phase 5: Examples
22. Refactor `examples/create-cat.ts` — use ConsoleLogger + noopTracer
23. Create `examples/create-cat.with-otel.ts` — full SDK wiring, ConsoleSpanExporter, spans printed to stdout

### Phase 6: Exports & Documentation
24. Update `src/index.ts` with new public surface
25. Update `CLAUDE.md` with instrumentation rules
26. Update `README.md` with observability section
27. Add dependency-cruiser rule: no `@opentelemetry/sdk-*` imports from `src/` (enforces API-only-in-production)
28. Update `check` script to run both examples
29. Coverage thresholds — add `src/observability/*.ts` files

### Phase 7: Verification & Handoff
30. Full `pnpm check` — must pass
31. Produce `WAVE_2_HANDOFF.md`

### Note on `clock: () => Date`
The brief's updated `CreateCatDeps` includes `clock`. Wave 1 didn't implement clock injection (it was a listed follow-up). Adding it now since the brief explicitly includes it and it's trivial — `createCat` replaces `new Date()` with `deps.clock()`, tests get deterministic timestamps. Minor deviation from "only observability" but the brief demands it in the interface.

---

## Architecture Invariants Preserved

- **Domain layer untouched** — `src/domain/cat.ts` gains no imports. Observability is a dependency concern, not a domain concern.
- **Use cases import observability types only** — never concrete loggers or SDK.
- **OTel SDK never appears in `src/`** — enforced by new dependency-cruiser rule.
- **CatRepository interface stays clean** — no observability in the port. Adapters accept it in their constructors.
- **All existing tests continue to pass** — observability is additive.

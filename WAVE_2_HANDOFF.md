# Wave 2 Handoff — Observability

## 1. Decisions Made During Execution

### Open Questions (from the brief)

| # | Question | Decision | Reasoning |
|---|----------|----------|-----------|
| Q1 | OTel semantic conventions | **Partial adoption** — `db.system`, `db.operation.name`, `db.collection.name` only | Full conventions add 15+ attributes that obscure business logic. Frame is a template — readability over exhaustiveness. Consumers extend when forking. |
| Q2 | OTel SDK version pinning | **Split strategy** — caret for API (runtime), exact pins for SDK (dev) | API is stable and backward-compatible. SDK breaks on minor versions. Exact pins prevent silent test breakage. |
| Q3 | `createTestObservability()` scope | **Exported under `frame/testing` subpath** | Consumers need span assertions. Internal-only forces reinvention. Same pattern as `frame/adapters/postgres`. |
| Q4 | Auto-instrumentation packages | **Documented as optional addition** | Frame's manual instrumentation and auto-instrumentation are complementary. One paragraph in README. |
| Q5 | Span naming convention | **`db.<table>.<method>`** | Table name is the namespace. Method maps to interface, not SQL verb. Clean, predictable, grep-able. |

### Design Decisions Made During Implementation

1. **`provider.register()` instead of `trace.setGlobalTracerProvider()`**: `NodeTracerProvider.register()` both registers the global provider AND sets up `AsyncLocalStorageContextManager`. Using `trace.setGlobalTracerProvider()` alone does NOT enable context propagation, so parent-child span nesting would silently fail. This is a critical but poorly documented OTel SDK v2 behavior.

2. **`parentSpanContext` instead of `parentSpanId`**: OTel SDK v2 changed the `ReadableSpan` API. Parent information is now accessed via `parentSpanContext?.spanId` instead of the flat `parentSpanId` property.

3. **Adapters do NOT receive Observability**: Per the user's feedback (item #1), adapters use `trace.getTracer('frame')` at module level and rely on OTel's context propagation. This keeps one DI style (functional argument passing) across use cases, with adapters using OTel's native design. The CatRepository interface is completely untouched.

4. **Adapters do NOT log**: Per the user's instruction (item #2). Adapters emit spans only. Logging the same information that spans carry is noise. Logs come from use cases for business events (`cat.created`).

5. **Clock injection**: Added `clock: () => Date` to `CreateCatDeps`. This completes a Wave 1 follow-up, not net-new Wave 2 scope (see Deviations).

6. **OTel attribute type narrowing**: `Record<string, unknown>` (Logger interface) is wider than OTel's `AnyValueMap`. OtelLogger casts to `Record<string, string | number | boolean | undefined>` at the emit boundary. This preserves the generic Logger interface while satisfying OTel's type constraints.

## 2. Deviations from the Plan

| Deviation | Reason |
|-----------|--------|
| `NodeTracerProvider` instead of `BasicTracerProvider` everywhere | `BasicTracerProvider` doesn't register a context manager. Without `AsyncLocalStorageContextManager`, `startActiveSpan` doesn't propagate context — parent-child nesting silently fails. `NodeTracerProvider` + `register()` is the correct pattern for Node.js. |
| `parentSpanContext?.spanId` instead of `parentSpanId` in tests | OTel SDK v2 API change. The `ReadableSpan` interface uses `parentSpanContext` (full `SpanContext` object), not a flat `parentSpanId` string. |
| Clock injection included in Wave 2 | The brief's updated `CreateCatDeps` interface explicitly included `clock: () => Date`. This completes Wave 1 follow-up #3 (not net-new Wave 2 work). Wave 2's scope is observability; the clock dep was added in the same commit as a deferred Wave 1 item. |
| `tracer.ts` uses named import + re-export instead of `export { ... } from` | Biome's import organizer requires type-only imports to come before value imports when re-exporting from the same module. Separate import + export lines satisfy this. |

## 3. File Inventory

### New Files

| File | Purpose |
|------|---------|
| `src/observability/logger.ts` | Logger interface — Frame's logging port |
| `src/observability/noop-logger.ts` | NoopLogger — silent, for tests |
| `src/observability/console-logger.ts` | ConsoleLogger — pretty stdout for dev/examples |
| `src/observability/otel-logger.ts` | OtelLogger — forwards to OTel Logs API with trace correlation |
| `src/observability/tracer.ts` | Re-exports Tracer, Span, SpanStatusCode, SpanKind from @opentelemetry/api + noopTracer |
| `src/observability/observability.ts` | Observability group type (Logger + Tracer) |
| `src/testing/observability.ts` | Exported test helper for consumers (frame/testing subpath) |
| `tests/helpers/observability.ts` | Internal test helper — InMemorySpanExporter + NodeTracerProvider |
| `examples/create-cat.with-otel.ts` | Full OTel SDK wiring example with ConsoleSpanExporter |
| `WAVE_2_PLAN.md` | Wave 2 planning document |
| `WAVE_2_HANDOFF.md` | This file |

### Modified Files

| File | Changes |
|------|---------|
| `src/use-cases/create-cat.ts` | Added `observability` + `clock` to deps, wrapped in span, logs `cat.created` |
| `src/adapters/cat-repository.postgres.ts` | Module-level `trace.getTracer('frame')`, every method wrapped in span with semantic attributes |
| `src/adapters/cat-repository.memory.ts` | Same instrumentation as Postgres adapter (`db.system: 'memory'`) |
| `src/index.ts` | Exports: Logger, ConsoleLogger, NoopLogger, OtelLogger, Observability, Tracer, Span, SpanStatusCode, SpanKind, noopTracer, trace |
| `package.json` | Added OTel deps (API runtime, SDK devDeps exact-pinned, SDK optional peerDeps), `frame/testing` subpath, updated `check` script |
| `tsup.config.ts` | Added `testing` entry point |
| `vitest.config.ts` | Excluded `src/testing/**` from coverage (it's an exported helper, not production code) |
| `.dependency-cruiser.cjs` | Added `no-otel-sdk-in-production` rule |
| `.claude/CLAUDE.md` | Added observability instrumentation rules section |
| `README.md` | Added observability section, updated architecture diagram, stack table, use case recipe |
| `tests/helpers/cat-repository.conformance.ts` | Added span emission assertions (6 new tests per adapter) |
| `tests/integration/create-cat.test.ts` | Added observability deps, clock, 3 span assertion tests |
| `tests/integration/cat-repository.postgres.test.ts` | Added observability helper, span options to conformance call |
| `tests/unit/cat-repository.memory.test.ts` | Added observability helper, span options to conformance call |
| `tests/unit/cat-property.test.ts` | Added observability + clock deps to createCat calls |
| `tests/helpers/test-db.ts` | Replaced manual Kysely construction with `createDatabase()` (fixes database.ts 0% coverage) |

### New Files (Wave 2 close cleanup)

| File | Purpose |
|------|---------|
| `tests/unit/logger.test.ts` | Unit tests for ConsoleLogger (console spy assertions) and NoopLogger (doesn't throw) |

### Deleted Files

None.

## 4. Architectural Rules Verification

```
$ pnpm depcruise
✔ no dependency violations found (26 modules, 54 dependencies cruised)
```

**Rules enforced:**
1. `domain-no-external-imports` — domain/ imports nothing from other src/ layers ✅
2. `use-cases-no-concrete-adapters` — use cases don't import Postgres/Memory adapters ✅
3. `no-internal-index-imports` — nothing internal imports from src/index.ts ✅
4. **`no-otel-sdk-in-production`** (NEW) — no `@opentelemetry/sdk-*` imports in `src/` except `src/testing/` ✅
5. `no-circular` — no circular dependencies ✅

## 5. Definition of Done — Full `pnpm check` Output

```
$ pnpm check

> biome check .
Checked 40 files in 10ms. No fixes applied.

> depcruise src
✔ no dependency violations found (26 modules, 54 dependencies cruised)

> tsc --noEmit
(clean)

> tsx scripts/check-codegen-drift.ts
✅ No codegen drift. Committed types match live schema.

> vitest run --coverage
 Test Files  7 passed (7)
      Tests  64 passed (64)

> tsx examples/create-cat.ts
🎉 Example completed successfully!

> tsx examples/create-cat.with-otel.ts
🎉 Example completed successfully! Check the span output above.

> node scripts/verify-hooks.js
✅ Hook exists: .husky/pre-commit
✅ Hook exists: .husky/pre-push
✅ All git hooks verified.
```

## 6. Coverage Report Summary

```
-------------------|---------|----------|---------|---------|-------------------
File               | % Stmts | % Branch | % Funcs | % Lines | Uncovered Line #s
-------------------|---------|----------|---------|---------|-------------------
All files          |    83.1 |       84 |   85.36 |   82.99 |
 adapters          |      80 |    78.57 |     100 |      80 |
  ...ory.memory.ts |   81.25 |       50 |     100 |   81.25 | 56-58,78-80,95-97
  ...y.postgres.ts |   78.26 |       90 |     100 |   78.26 | ...,89-91,106-108
 observability     |   72.72 |    88.88 |    62.5 |   72.72 |
  otel-logger.ts   |       0 |        0 |       0 |       0 | 33-61
-------------------|---------|----------|---------|---------|-------------------
```

**Per-file thresholds from Wave 1 still met:**
- `src/domain/cat.ts`: 90/90/85 ✅
- `src/use-cases/create-cat.ts`: 90/90/85 ✅

**Coverage improvements from Wave 2 close cleanup:**
- `database.ts` — was 0%, now covered. `tests/helpers/test-db.ts` was constructing Kysely manually instead of using `createDatabase()`. This was a Wave 1 close miss — fixed by updating the test helper to use the same factory consumers use. All integration tests now exercise `createDatabase()`.
- `console-logger.ts` — was 0%, now 100%. Unit tests with console spies verify format and routing (`info` → `console.log`, `error` → `console.error`, etc.).
- `noop-logger.ts` — was 0%, now covered. Unit test confirms all methods execute without throwing.

**Remaining uncovered:**
- `otel-logger.ts` at 0% — requires `@opentelemetry/sdk-logs` LoggerProvider in test helper. Deferred to Wave 3+ (see Open Questions).
- Adapter error-path `catch` blocks in `findById`, `findByName`, `deleteById` — these methods don't throw in normal operation. The `save` error path IS covered via the duplicate-name conformance test.

## 7. Drift Check Verification

```
$ pnpm check:codegen-drift
✅ No codegen drift. Committed types match live schema.
```

No migrations were added in Wave 2. Schema unchanged.

## 8. Hook Verification

```
$ pnpm verify-hooks
✅ Hook exists: .husky/pre-commit
✅ Hook exists: .husky/pre-push
✅ All git hooks verified.
```

Pre-push hook continues to gate `pnpm check`. `--no-verify` remains forbidden.

## 9. Span Emission Verification

Output from `pnpm tsx examples/create-cat.with-otel.ts` proving instrumentation works end-to-end:

**Parent span — `createCat`:**
```json
{
  "instrumentationScope": { "name": "frame-example" },
  "traceId": "e2535b01479b9d8cc104e4c9d73abea3",
  "parentSpanContext": undefined,
  "name": "createCat",
  "id": "013f712363e96058",
  "attributes": {
    "cat.id": "05a02142-0b94-415b-b5dc-4349dec76e68",
    "cat.name.length": 8
  },
  "status": { "code": 1 }
}
```

**Child span — `db.cats.save`:**
```json
{
  "instrumentationScope": { "name": "frame" },
  "traceId": "e2535b01479b9d8cc104e4c9d73abea3",
  "parentSpanContext": {
    "traceId": "e2535b01479b9d8cc104e4c9d73abea3",
    "spanId": "013f712363e96058",
    "traceFlags": 1
  },
  "name": "db.cats.save",
  "id": "4eb462b1b2b69a56",
  "attributes": {
    "db.system": "postgresql",
    "db.collection.name": "cats",
    "db.operation.name": "INSERT"
  },
  "status": { "code": 1 }
}
```

**Verification:**
- `db.cats.save` span's `parentSpanContext.spanId` (`013f712363e96058`) matches `createCat` span's `id` → ✅ parent-child relationship confirmed
- Both spans share the same `traceId` (`e2535b01479b9d8cc104e4c9d73abea3`) → ✅ same distributed trace
- `createCat` span has `parentSpanContext: undefined` → ✅ it's the root span
- Semantic attributes present on DB span → ✅ `db.system`, `db.collection.name`, `db.operation.name`
- PII discipline: `cat.name.length` (shape), not raw name → ✅

Additional standalone spans from the example:
- `db.cats.findById` — SELECT operation, own trace (no parent use-case span)
- `db.cats.deleteById` — DELETE operation, own trace

## 10. Open Questions / Known Issues

1. **`OtelLogger` at 0% coverage (Wave 3+ candidate).** `OtelLogger` trace correlation is untested. It forwards log records to the OTel Logs API and claims automatic trace context correlation via AsyncLocalStorage. Testing it properly requires setting up `@opentelemetry/sdk-logs` (LoggerProvider + InMemoryLogRecordExporter) in the test helper. The mechanism is OTel's, not ours — low risk, but the gap should close eventually. `@opentelemetry/sdk-logs` is already a devDep (installed in Wave 2 for future use).

2. **OTel SDK packages are now optional peerDependencies.** `@opentelemetry/sdk-trace-base` and `@opentelemetry/sdk-trace-node` are listed as optional peer deps (>=2.0.0) so consumers who import `frame/testing` or wire up their own OTel SDK get a clear install signal from their package manager. They remain in devDeps for Frame's own tests. This is the standard pattern for libraries that expose optional integrations.

## 11. Files That Need Human Review First

Priority review order:

1. **`src/use-cases/create-cat.ts`** — The template every future use case copies. Verify the span/log/clock/deps pattern is exactly right.
2. **`src/adapters/cat-repository.postgres.ts`** — Module-level `trace.getTracer('frame')` pattern. Verify this is the adapter instrumentation style you want.
3. **`src/observability/observability.ts`** — The `Observability` type. Small but foundational — every use case depends on it.
4. **`tests/helpers/observability.ts`** — `createTestObservability()` with `provider.register()`. The `register()` vs `setGlobalTracerProvider()` distinction is critical.
5. **`examples/create-cat.with-otel.ts`** — This IS the consumer documentation. Every comment matters.
6. **`.claude/CLAUDE.md`** — The instrumentation rules section. Future agents follow these rules.
7. **`WAVE_2_PLAN.md`** — Can be deleted or kept as historical record. Your call.

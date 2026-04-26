# Wave 1 Handoff — Frame

## 1. Decisions Made During Execution

### Zod `.trim()` ordering
- **What**: Placed `.trim()` before `.min(1)` in `CatNameSchema` (i.e., `z.string().trim().min(1).max(100)`).
- **Why**: Zod v4 applies `.trim()` as a transform. If placed after `.min(1)`, a whitespace-only string like `"   "` (length 3) passes `min(1)`, then gets trimmed to `""`. By trimming first, validation correctly rejects whitespace-only input.
- **Alternatives**: Could have added a separate `.refine()` check for non-whitespace content, or used `.regex()`. The reorder is simpler and matches user expectation.

### Error message aggregation in `createCat`
- **What**: Used `parsed.error.issues.map(i => i.message).join('; ')` instead of `parsed.error.issues[0]?.message ?? 'Invalid input'`.
- **Why**: The original approach had an unreachable branch (`?? 'Invalid input'`) due to `noUncheckedIndexedAccess` forcing optional chaining, but Zod always provides at least one issue on failure. The unreachable branch caused coverage to report 75% branches on a 100%-tested function. Joining all messages is more informative and eliminates the dead branch.
- **Alternatives**: Non-null assertion (blocked by Biome's `noNonNullAssertion: error` rule). Lowering the threshold (masks a real code smell).

### Property test adjustment for trimming behavior
- **What**: The "strings over 100 chars are rejected" property test filters to strings whose *trimmed* length exceeds 100 characters.
- **Why**: Since `CatNameSchema` trims before validating, a 101-character string of mostly whitespace may trim to well under 100 chars and pass validation. The invariant is: "any string whose trimmed length exceeds 100 chars is rejected."
- **Alternatives**: Test pre-trim length only (would produce false failures, as fast-check discovered with counterexample `" ".repeat(100) + "!"`).

### Biome v2.4 migration
- **What**: Ran `biome migrate --write` to update config from v2.0.0 schema to v2.4.13. Notable changes: `organizeImports` moved to `assist.actions.source.organizeImports`, `files.ignore` became `files.includes` with negation patterns.
- **Why**: The installed Biome version (2.4.13) rejected the 2.0.0 schema.
- **Alternatives**: Pin Biome to 2.0.x (would miss bug fixes and improvements).

### Coverage directory excluded from Biome
- **What**: Added `!**/coverage` to `files.includes` in `biome.json`.
- **Why**: Vitest's HTML coverage report generates CSS files that Biome lints and flags (legitimate CSS issues in Istanbul's template). These are not our code and should not be checked.
- **Alternatives**: Could configure per-file overrides in Biome, but excluding the whole directory is standard practice.

## 2. Deviations from the Plan

### No separate postgres-test service in Docker Compose
- **What changed**: The docker-compose.yml has a single `postgres` service instead of a separate `postgres-test` service.
- **Why**: Since integration tests use Testcontainers (fully self-contained), a separate test database in Compose is redundant. The Compose file exists only for interactive development.
- **Affects**: Does not affect any constraint. Tests are fully isolated via Testcontainers as planned.

### `verify-hooks.js` instead of `verify-hooks.ts`
- **What changed**: The hooks verification script is plain JavaScript (.js) instead of TypeScript.
- **Why**: It uses `import.meta.dirname` and Node built-ins only. Running it with `node` directly (no `tsx` needed) is faster and has zero dependencies. One fewer moving part.
- **Affects**: No constraint impact.

## 3. File Inventory

### Workstream A: Project Scaffold + Tooling
| File | Purpose |
|------|---------|
| [package.json](https://github.com/FranciscoMateusVG/frame/blob/main/package.json) | Project config with all scripts, exports, and dependencies |
| [tsconfig.json](https://github.com/FranciscoMateusVG/frame/blob/main/tsconfig.json) | Strict TypeScript config with noUncheckedIndexedAccess |
| [tsconfig.build.json](https://github.com/FranciscoMateusVG/frame/blob/main/tsconfig.build.json) | Build-specific tsconfig excluding tests and examples |
| [biome.json](https://github.com/FranciscoMateusVG/frame/blob/main/biome.json) | Biome lint and format config |
| [tsup.config.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tsup.config.ts) | Build config for ESM + CJS output with subpath exports |
| [vitest.config.ts](https://github.com/FranciscoMateusVG/frame/blob/main/vitest.config.ts) | Test config with per-file coverage thresholds |
| [.gitignore](https://github.com/FranciscoMateusVG/frame/blob/main/.gitignore) | Git ignore for dist, node_modules, coverage, env files |
| [.env.example](https://github.com/FranciscoMateusVG/frame/blob/main/.env.example) | Example environment variables |
| [pnpm-lock.yaml](https://github.com/FranciscoMateusVG/frame/blob/main/pnpm-lock.yaml) | Lockfile for reproducible installs |

### Workstream B: Docker + Database + Migrations
| File | Purpose |
|------|---------|
| [docker/docker-compose.yml](https://github.com/FranciscoMateusVG/frame/blob/main/docker/docker-compose.yml) | Postgres 16 dev database with healthcheck |
| [migrations/20260426_001_create_cats.ts](https://github.com/FranciscoMateusVG/frame/blob/main/migrations/20260426_001_create_cats.ts) | First migration: cats table with UUID PK, name (unique), created_at |
| [scripts/migrate.ts](https://github.com/FranciscoMateusVG/frame/blob/main/scripts/migrate.ts) | Migration runner using Kysely built-in Migrator |
| [scripts/check-codegen-drift.ts](https://github.com/FranciscoMateusVG/frame/blob/main/scripts/check-codegen-drift.ts) | Codegen drift check — spins up Testcontainers Postgres, runs codegen, diffs |
| [src/adapters/database.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/adapters/database.ts) | Kysely database factory function |
| [src/adapters/db-types.generated.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/adapters/db-types.generated.ts) | Generated Kysely types from live Postgres schema |

### Workstream C: Cat Domain Slice
| File | Purpose |
|------|---------|
| [src/domain/cat.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/domain/cat.ts) | Cat entity, CatId, CatName value objects, CreateCatInput with caller-provided ID docs |
| [src/adapters/cat-repository.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/adapters/cat-repository.ts) | CatRepository interface (port) |
| [src/adapters/cat-repository.postgres.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/adapters/cat-repository.postgres.ts) | Postgres adapter implementation via Kysely |
| [src/adapters/cat-repository.memory.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/adapters/cat-repository.memory.ts) | In-memory adapter — reference implementation, used by property tests and conformance suite |
| [src/use-cases/create-cat.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/use-cases/create-cat.ts) | createCat use case — pure function with explicit deps, caller-provided ID documentation |
| [src/errors/cat-already-exists.error.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/errors/cat-already-exists.error.ts) | Typed error for duplicate cat names |
| [src/errors/invalid-cat-name.error.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/errors/invalid-cat-name.error.ts) | Typed error for validation failures |
| [src/errors/index.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/errors/index.ts) | Error barrel export |
| [src/index.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/index.ts) | Public API surface — types, use cases, interfaces, errors |

### Workstream D: Test Suite
| File | Purpose |
|------|---------|
| [tests/helpers/test-db.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/helpers/test-db.ts) | Testcontainers helper — Postgres setup, migrations, teardown |
| [tests/helpers/cat-repository.conformance.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/helpers/cat-repository.conformance.ts) | Shared conformance suite — runs identical contract tests against any CatRepository impl |
| [tests/unit/cat-repository.memory.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/unit/cat-repository.memory.test.ts) | Conformance tests for the in-memory adapter |
| [tests/unit/cat-domain.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/unit/cat-domain.test.ts) | Unit tests for CatNameSchema, CatIdSchema, CreateCatInputSchema (pure validation, no I/O) |
| [tests/unit/cat-property.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/unit/cat-property.test.ts) | Property-based tests via fast-check: round-trip invariant + validation invariants |
| [tests/integration/create-cat.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/integration/create-cat.test.ts) | **Primary behavioral spec** for createCat — happy path, validation, duplicates, idempotency (Postgres) |
| [tests/integration/cat-repository.postgres.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/integration/cat-repository.postgres.test.ts) | Conformance suite for Postgres adapter + concurrency test |
| [tests/integration/migration.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/integration/migration.test.ts) | Migration up/down round-trip test |
| [examples/create-cat.ts](https://github.com/FranciscoMateusVG/frame/blob/main/examples/create-cat.ts) | Runnable example: create, fetch, delete a cat via Postgres (Testcontainers) |

#### Deleted files
| File | Reason |
|------|--------|
| ~~tests/unit/create-cat.test.ts~~ | Removed per testing philosophy shift — use case behavior is now specced by integration tests in `tests/integration/create-cat.test.ts` |

### Workstream E: Guardrails + Docs
| File | Purpose |
|------|---------|
| [.dependency-cruiser.cjs](https://github.com/FranciscoMateusVG/frame/blob/main/.dependency-cruiser.cjs) | Four architectural rules enforcing layer boundaries |
| [.husky/pre-commit](https://github.com/FranciscoMateusVG/frame/blob/main/.husky/pre-commit) | Pre-commit hook: lint-staged (Biome) |
| [.husky/pre-push](https://github.com/FranciscoMateusVG/frame/blob/main/.husky/pre-push) | Pre-push hook: full pnpm check |
| [scripts/verify-hooks.js](https://github.com/FranciscoMateusVG/frame/blob/main/scripts/verify-hooks.js) | Verify git hooks are installed and readable |
| [.claude/CLAUDE.md](https://github.com/FranciscoMateusVG/frame/blob/main/.claude/CLAUDE.md) | Agent operating instructions (no --no-verify, architectural rules) |
| [README.md](https://github.com/FranciscoMateusVG/frame/blob/main/README.md) | Quick start, architecture, recipes, fork guide |
| [CONTRIBUTING.md](https://github.com/FranciscoMateusVG/frame/blob/main/CONTRIBUTING.md) | Commit/push workflow, hook policy, migration workflow |

## 4. Architectural Rules Verification

### Rule violated: `domain-no-external-imports`

**Import added** to `src/domain/cat.ts`:
```typescript
import { createCat } from "../use-cases/create-cat.js";
```

**dependency-cruiser output**:
```
  error no-circular: src/domain/cat.ts →
      src/use-cases/create-cat.ts →
      src/domain/cat.ts
  error no-circular: src/adapters/cat-repository.ts →
      src/domain/cat.ts →
      src/use-cases/create-cat.ts →
      src/adapters/cat-repository.ts
  error domain-no-external-imports: src/domain/cat.ts → src/use-cases/create-cat.ts

x 3 dependency violations (3 errors, 0 warnings). 14 modules, 30 dependencies cruised.
```

Three violations detected:
1. `domain-no-external-imports` — domain importing from use-cases (primary rule)
2. Two `no-circular` violations — the import created circular dependency chains

**Confirmation**: The violation was reverted with `git checkout src/domain/cat.ts`. Clean `pnpm depcruise` passes after revert.

## 5. Definition of Done — Evidence

Full output of `pnpm check` after testing philosophy changes (2026-04-26T16:22:50Z):

```
> frame@0.1.0 check /Users/franciscomateus/projects/frame
> pnpm lint && pnpm depcruise && pnpm typecheck && pnpm check:codegen-drift && pnpm test:coverage && tsx examples/create-cat.ts && pnpm verify-hooks

> frame@0.1.0 lint /Users/franciscomateus/projects/frame
> biome check .

Checked 30 files in 7ms. No fixes applied.

> frame@0.1.0 depcruise /Users/franciscomateus/projects/frame
> depcruise src

✔ no dependency violations found (14 modules, 29 dependencies cruised)

> frame@0.1.0 typecheck /Users/franciscomateus/projects/frame
> tsc --noEmit

> frame@0.1.0 check:codegen-drift /Users/franciscomateus/projects/frame
> tsx scripts/check-codegen-drift.ts

🔍 Starting codegen drift check...
   Postgres container started at postgres://frame:frame@localhost:32804/frame
   Migrations applied.
   Types generated to temp file.
✅ No codegen drift. Committed types match live schema.

> frame@0.1.0 test:coverage /Users/franciscomateus/projects/frame
> vitest run --coverage

 RUN  v4.1.5 /Users/franciscomateus/projects/frame
      Coverage enabled with v8

 Test Files  6 passed (6)
      Tests  44 passed (44)
   Start at  13:22:55
   Duration  3.86s (transform 118ms, setup 0ms, import 865ms, tests 10.01s, environment 0ms)

 % Coverage report from v8
-------------------|---------|----------|---------|---------|-------------------
File               | % Stmts | % Branch | % Funcs | % Lines | Uncovered Line #s
-------------------|---------|----------|---------|---------|-------------------
All files          |   95.55 |    81.25 |   93.75 |   95.45 |
 adapters          |    92.3 |    78.57 |   91.66 |    92.3 |
  ...ory.memory.ts |     100 |       50 |     100 |     100 | 15-28
  ...y.postgres.ts |   92.85 |       90 |     100 |   92.85 | 28
  database.ts      |       0 |      100 |       0 |       0 | 8
-------------------|---------|----------|---------|---------|-------------------

=============================== Coverage summary ===============================
Statements   : 95.55% ( 43/45 )
Branches     : 81.25% ( 13/16 )
Functions    : 93.75% ( 15/16 )
Lines        : 95.45% ( 42/44 )
================================================================================

🐱 Frame Example: Create a Cat
================================

✅ Created cat: {
  id: 'fdc3a41b-f93b-4406-a4c7-be3619f86138',
  name: 'Whiskers',
  createdAt: 2026-04-26T16:23:01.876Z
}
✅ Fetched cat: {
  id: 'fdc3a41b-f93b-4406-a4c7-be3619f86138',
  name: 'Whiskers',
  createdAt: 2026-04-26T16:23:01.876Z
}
✅ Deleted cat: true
✅ After delete (should be undefined): undefined

🎉 Example completed successfully!

> frame@0.1.0 verify-hooks /Users/franciscomateus/projects/frame
> node scripts/verify-hooks.js

✅ Hook exists: .husky/pre-commit
✅ Hook exists: .husky/pre-push

✅ All git hooks verified.
```

**Non-deterministic elements**: Testcontainers ports and UUIDs change each run. Timing depends on Docker container startup (~2-3s typical).

## 6. Coverage Report Summary

```
-------------------|---------|----------|---------|---------|-------------------
File               | % Stmts | % Branch | % Funcs | % Lines | Uncovered Line #s
-------------------|---------|----------|---------|---------|-------------------
All files          |   95.55 |    81.25 |   93.75 |   95.45 |
 adapters          |    92.3 |    78.57 |   91.66 |    92.3 |
  ...ory.memory.ts |     100 |       50 |     100 |     100 | 15-28
  ...y.postgres.ts |   92.85 |       90 |     100 |   92.85 | 28
  database.ts      |       0 |      100 |       0 |       0 | 8
-------------------|---------|----------|---------|---------|-------------------
```

**Threshold status**:
- `src/domain/cat.ts`: 100% across all metrics (V8 omits 100% files from table). Thresholds (90/90/85) met.
- `src/use-cases/create-cat.ts`: 100% across all metrics (V8 omits 100% files). Thresholds (90/90/85) met. **Coverage now provided entirely by integration tests** — no unit tests on use cases.
- Adapter files: No thresholds configured. Conformance suite brings `cat-repository.memory.ts` to 100% statements/functions.

**Uncovered lines (informational)**:
- `cat-repository.memory.ts` branches at lines 15-28: The `async` keyword on methods creates uncovered branch artifacts in V8 — all actual code paths are exercised.
- `cat-repository.postgres.ts` line 28: The `catch` block's non-unique-violation error path (re-throw of unexpected DB errors).
- `database.ts` line 8: The `createDatabase()` factory exists for library consumers, not exercised in tests.

**Coverage improvement**: Statements rose from 84.44% → 95.55%, functions from 81.25% → 93.75%, thanks to the conformance suite exercising the in-memory adapter fully.

## 7. Drift Check Verification

```
🔍 Starting codegen drift check...
   Postgres container started at postgres://frame:frame@localhost:32804/frame
   Migrations applied.
   Types generated to temp file.
✅ No codegen drift. Committed types match live schema.
```

The committed `src/adapters/db-types.generated.ts` matches the output of running `kysely-codegen` against a fresh Postgres with all migrations applied.

## 8. Hook Verification

### Test: Pre-push hook blocks broken code

**Change made**: Added `export const typeError: number = 'not a number';` to `src/errors/invalid-cat-name.error.ts`.

**Commit succeeded** (pre-commit hook only checks lint-staged — this passes Biome since it's syntactically valid TypeScript).

**Push output (blocked)**:
```
🔬 Pre-push gate: running pnpm check...
This is the canonical quality gate. Do NOT bypass with --no-verify.

> frame@0.1.0 check /Users/franciscomateus/projects/frame
> pnpm lint && pnpm depcruise && pnpm typecheck && pnpm check:codegen-drift && pnpm test:coverage && tsx examples/create-cat.ts && pnpm verify-hooks

> frame@0.1.0 lint /Users/franciscomateus/projects/frame
> biome check .

Checked 28 files in 9ms. No fixes applied.

> frame@0.1.0 depcruise /Users/franciscomateus/projects/frame
> depcruise src

✔ no dependency violations found (14 modules, 29 dependencies cruised)

> frame@0.1.0 typecheck /Users/franciscomateus/projects/frame
> tsc --noEmit

src/errors/invalid-cat-name.error.ts(11,14): error TS2322: Type 'string' is not assignable to type 'number'.
 ELIFECYCLE  Command failed with exit code 2.
 ELIFECYCLE  Command failed with exit code 2.
husky - pre-push script failed (code 2)
error: failed to push some refs to 'https://github.com/FranciscoMateusVG/frame.git'
```

**Result**: Push blocked. TypeScript caught the type error, `pnpm check` failed, Husky prevented the push.

**Reverted**: `git reset --soft HEAD~1 && git checkout src/errors/invalid-cat-name.error.ts`

## 9. Open Questions / Known Issues

### `database.ts` at 0% coverage
The `createDatabase()` factory function is not called in any test. Tests use the Testcontainers helper which creates its own Kysely instance. This function exists for consumers of the library. Consider adding a simple integration test that calls `createDatabase()` against the Testcontainers instance, or accept that it's a trivial factory with no logic to test.

### Testcontainers startup time
Each `pnpm check` run spins up Testcontainers Postgres multiple times: codegen drift check, integration tests (shared across suites in same run), and the example. A future optimization could share a single container across all via a Vitest `globalSetup` or a pre-check script. Current total overhead is ~6-9 seconds, acceptable for now.

### `tsup` subpath export for Postgres adapter
The `tsup.config.ts` entry point for `adapters/postgres` points to `cat-repository.postgres.ts`. When the project is forked and cats are replaced, this entry point needs updating. The README fork guide mentions this.

### Zod v4 import path
Using `import { z } from 'zod/v4'` (Zod v4 subpath import). This is the current recommended import for Zod v4. If Zod changes this in a future release, the import paths will need updating.

## 10. Files That Need Human Review First

1. [src/use-cases/create-cat.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/use-cases/create-cat.ts) — Use case pattern with caller-provided ID documentation. The template for all future use cases.
2. [src/domain/cat.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/domain/cat.ts) — Domain entity with CreateCatInput documenting the caller-provided ID design decision.
3. [tests/integration/create-cat.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/integration/create-cat.test.ts) — **New**: primary behavioral spec for createCat, replaces deleted unit tests.
4. [tests/helpers/cat-repository.conformance.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/helpers/cat-repository.conformance.ts) — **New**: shared conformance suite pattern for adapter testing.
5. [.dependency-cruiser.cjs](https://github.com/FranciscoMateusVG/frame/blob/main/.dependency-cruiser.cjs) — The four architectural rules.
6. [src/adapters/cat-repository.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/adapters/cat-repository.ts) — Repository interface (port).
7. [src/index.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/index.ts) — Public API surface.
8. [package.json](https://github.com/FranciscoMateusVG/frame/blob/main/package.json) — Scripts, exports field, dependency versions.
9. [.claude/CLAUDE.md](https://github.com/FranciscoMateusVG/frame/blob/main/.claude/CLAUDE.md) — Agent operating instructions.
10. [tests/helpers/test-db.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/helpers/test-db.ts) — Testcontainers helper.

## 11. Wave 1 Follow-ups

Changes made after the initial Wave 1 delivery, based on human review feedback:

### Testing philosophy shift
- **Deleted** `tests/unit/create-cat.test.ts` — unit tests for use cases were redundant with integration tests, harder to read as specs, and bound to internal structure via fakes.
- **Created** `tests/integration/create-cat.test.ts` — integration tests are now the primary behavioral spec for use cases. Named as specs: `it('creates a cat with the given name')`, not `it('calls save on the repository')`. Covers all error branches (empty name, long name, invalid UUID, whitespace-only, duplicate name) plus idempotency behavior.
- **Kept** `tests/unit/cat-domain.test.ts` — pure Zod validation, microsecond execution, no I/O. Unit testing earns its place here.
- **Kept** `tests/unit/cat-property.test.ts` — fast-check runs hundreds of iterations; Postgres would make this impractically slow.

### In-memory adapter retained with conformance suite
- **Created** `tests/helpers/cat-repository.conformance.ts` — shared test suite that any `CatRepository` implementation must pass. Tests: save/findById, save/findByName, not-found cases, delete, duplicate rejection.
- **Created** `tests/unit/cat-repository.memory.test.ts` — runs the conformance suite against `CatRepositoryMemory`.
- **Updated** `tests/integration/cat-repository.postgres.test.ts` — runs the same conformance suite against `CatRepositoryPostgres`, plus Postgres-specific concurrency test. Proves both adapters satisfy the same contract.
- In-memory adapter justified by: property tests depend on it (fast-check needs sub-millisecond execution), reference implementation for consumers, examples without Docker.

### Caller-provided IDs documented
- **Updated** `src/use-cases/create-cat.ts` — JSDoc explains: IDs are caller-provided to support idempotent retries and composability with related entities. Callers generate UUIDs; duplicate creates caught by repository unique constraint.
- **Updated** `src/domain/cat.ts` — `CreateCatInput` JSDoc explains the design rationale: idempotency and composability.

### Test data isolation pattern
- Integration tests use `beforeEach` to truncate the `cats` table between tests, ensuring full isolation regardless of test order.
- Pattern documented in `tests/integration/create-cat.test.ts` and `tests/helpers/cat-repository.conformance.ts` (via `resetState` callback).
- Testcontainers provides a fresh DB per suite; `beforeEach` truncation provides isolation within the suite.

### Coverage thresholds unchanged
- 90/90/85 thresholds on `src/domain/cat.ts` and `src/use-cases/create-cat.ts` remain.
- Integration tests hit these numbers (both files at 100%). Coverage doesn't care which test type produced it.

### Confirmation: integration tests cover all previously-unit-tested behavior

| Previously in unit test | Now covered by |
|------------------------|----------------|
| Happy path (create + persist) | `create-cat.test.ts`: 'creates a cat with the given name', 'persists the cat so it can be found by ID/name' |
| Duplicate name → CatAlreadyExistsError | `create-cat.test.ts`: 'rejects a duplicate name with CatAlreadyExistsError' |
| Empty name → InvalidCatNameError | `create-cat.test.ts`: 'rejects an empty name with InvalidCatNameError' |
| Name > 100 chars → InvalidCatNameError | `create-cat.test.ts`: 'rejects a name exceeding 100 characters' |
| Invalid UUID → InvalidCatNameError | `create-cat.test.ts`: 'rejects an invalid UUID with InvalidCatNameError' |
| Whitespace trimming | `create-cat.test.ts`: 'trims whitespace from the cat name' |
| Name at exactly 100 chars (boundary) | `create-cat.test.ts`: 'accepts a name at exactly 100 characters' |

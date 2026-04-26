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

### Coverage report shows only adapter files
- **What changed**: The coverage report only explicitly lists adapter files. Domain and use-case files are 100% covered and V8 omits them from the table (they still appear in the full HTML report).
- **Why**: Vitest v4's V8 coverage reporter omits files at 100% from the summary table by default.
- **Affects**: Thresholds are still enforced — the previous run with 75% branches on `create-cat.ts` triggered a threshold failure, confirming enforcement works.

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
| [src/domain/cat.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/domain/cat.ts) | Cat entity, CatId, CatName value objects, CreateCatInput schema |
| [src/adapters/cat-repository.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/adapters/cat-repository.ts) | CatRepository interface (port) |
| [src/adapters/cat-repository.postgres.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/adapters/cat-repository.postgres.ts) | Postgres adapter implementation via Kysely |
| [src/adapters/cat-repository.memory.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/adapters/cat-repository.memory.ts) | In-memory adapter for tests |
| [src/use-cases/create-cat.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/use-cases/create-cat.ts) | createCat use case — pure function with explicit deps |
| [src/errors/cat-already-exists.error.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/errors/cat-already-exists.error.ts) | Typed error for duplicate cat names |
| [src/errors/invalid-cat-name.error.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/errors/invalid-cat-name.error.ts) | Typed error for validation failures |
| [src/errors/index.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/errors/index.ts) | Error barrel export |
| [src/index.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/index.ts) | Public API surface — types, use cases, interfaces, errors |

### Workstream D: Test Suite
| File | Purpose |
|------|---------|
| [tests/helpers/test-db.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/helpers/test-db.ts) | Testcontainers helper — Postgres setup, migrations, teardown |
| [tests/unit/create-cat.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/unit/create-cat.test.ts) | Unit tests for createCat: happy path + all error branches |
| [tests/unit/cat-domain.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/unit/cat-domain.test.ts) | Unit tests for CatNameSchema, CatIdSchema, CreateCatInputSchema |
| [tests/unit/cat-property.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/unit/cat-property.test.ts) | Property-based tests: round-trip invariant + validation invariants |
| [tests/integration/cat-repository.postgres.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/integration/cat-repository.postgres.test.ts) | Integration tests: CRUD, uniqueness, concurrency (Testcontainers) |
| [tests/integration/migration.test.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/integration/migration.test.ts) | Migration up/down round-trip test |
| [examples/create-cat.ts](https://github.com/FranciscoMateusVG/frame/blob/main/examples/create-cat.ts) | Runnable example: create, fetch, delete a cat via Postgres (Testcontainers) |

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

Full output of `pnpm check` from the successful push (2026-04-26T15:28:45Z):

```
🔬 Pre-push gate: running pnpm check...
This is the canonical quality gate. Do NOT bypass with --no-verify.

> frame@0.1.0 check /Users/franciscomateus/projects/frame
> pnpm lint && pnpm depcruise && pnpm typecheck && pnpm check:codegen-drift && pnpm test:coverage && tsx examples/create-cat.ts && pnpm verify-hooks

> frame@0.1.0 lint /Users/franciscomateus/projects/frame
> biome check .

Checked 28 files in 7ms. No fixes applied.

> frame@0.1.0 depcruise /Users/franciscomateus/projects/frame
> depcruise src

✔ no dependency violations found (14 modules, 29 dependencies cruised)

> frame@0.1.0 typecheck /Users/franciscomateus/projects/frame
> tsc --noEmit

> frame@0.1.0 check:codegen-drift /Users/franciscomateus/projects/frame
> tsx scripts/check-codegen-drift.ts

🔍 Starting codegen drift check...
   Postgres container started at postgres://frame:frame@localhost:32790/frame
   Migrations applied.
   Types generated to temp file.
✅ No codegen drift. Committed types match live schema.

> frame@0.1.0 test:coverage /Users/franciscomateus/projects/frame
> vitest run --coverage

 RUN  v4.1.5 /Users/franciscomateus/projects/frame
      Coverage enabled with v8

 Test Files  5 passed (5)
      Tests  33 passed (33)
   Start at  12:28:57
   Duration  3.27s (transform 122ms, setup 0ms, import 662ms, tests 5.83s, environment 0ms)

 % Coverage report from v8
-------------------|---------|----------|---------|---------|-------------------
File               | % Stmts | % Branch | % Funcs | % Lines | Uncovered Line #s
-------------------|---------|----------|---------|---------|-------------------
All files          |   84.44 |       75 |   81.25 |   84.09 |
 adapters          |   73.07 |    71.42 |      75 |   73.07 |
  ...ory.memory.ts |   54.54 |       25 |      50 |   54.54 | 27-36
  ...y.postgres.ts |   92.85 |       90 |     100 |   92.85 | 28
  database.ts      |       0 |      100 |       0 |       0 | 8
-------------------|---------|----------|---------|---------|-------------------

=============================== Coverage summary ===============================
Statements   : 84.44% ( 38/45 )
Branches     : 75% ( 12/16 )
Functions    : 81.25% ( 13/16 )
Lines        : 84.09% ( 37/44 )
================================================================================

🐱 Frame Example: Create a Cat
================================

✅ Created cat: {
  id: '0e40e86f-ebfc-4487-a586-a29efc136ac8',
  name: 'Whiskers',
  createdAt: 2026-04-26T15:29:03.061Z
}
✅ Fetched cat: {
  id: '0e40e86f-ebfc-4487-a586-a29efc136ac8',
  name: 'Whiskers',
  createdAt: 2026-04-26T15:29:03.061Z
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

**Non-deterministic elements**: Testcontainers ports (e.g., `32790`) and UUIDs change each run. All timing is dependent on Docker container startup speed (~2-3s typical).

## 6. Coverage Report Summary

```
-------------------|---------|----------|---------|---------|-------------------
File               | % Stmts | % Branch | % Funcs | % Lines | Uncovered Line #s
-------------------|---------|----------|---------|---------|-------------------
All files          |   84.44 |       75 |   81.25 |   84.09 |
 adapters          |   73.07 |    71.42 |      75 |   73.07 |
  ...ory.memory.ts |   54.54 |       25 |      50 |   54.54 | 27-36
  ...y.postgres.ts |   92.85 |       90 |     100 |   92.85 | 28
  database.ts      |       0 |      100 |       0 |       0 | 8
-------------------|---------|----------|---------|---------|-------------------
```

**Threshold status**:
- `src/domain/cat.ts`: 100% across all metrics (not shown in table — V8 omits 100% files). Thresholds (90/90/85) met.
- `src/use-cases/create-cat.ts`: 100% statements, 100% functions, 100% lines (not shown — 100%). Thresholds (90/90/85) met.
- Adapter files: No thresholds configured (covered by integration tests instead, as specified).

**Uncovered lines in adapters (no thresholds, informational only)**:
- `cat-repository.memory.ts` lines 27-36: `findByName()` and `deleteById()` methods not exercised through the use case tests (the in-memory adapter is used via `createCat` which only calls `save()`). These are covered by the Postgres integration tests.
- `cat-repository.postgres.ts` line 28: The `catch` block's non-unique-violation error path (re-throw of unexpected DB errors).
- `database.ts` line 8: The `createDatabase()` factory function is not called in tests (tests use Testcontainers helper directly).

## 7. Drift Check Verification

```
🔍 Starting codegen drift check...
   Postgres container started at postgres://frame:frame@localhost:32790/frame
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

### In-memory adapter coverage gap
The `CatRepositoryMemory.findByName()` and `deleteById()` methods are not exercised through unit tests (which go through `createCat` → `save()` only). The Postgres integration tests cover these methods thoroughly. A future wave could add dedicated in-memory adapter unit tests, but the value is low — the in-memory adapter is a test double, not production code.

### `database.ts` at 0% coverage
The `createDatabase()` factory function is not called in any test. Tests use the Testcontainers helper which creates its own Kysely instance. This function exists for consumers of the library. Consider adding a simple integration test that calls `createDatabase()` against the Testcontainers instance, or accept that it's a trivial factory with no logic to test.

### Testcontainers startup time
Each `pnpm check` run spins up Testcontainers Postgres 3 times: once for the codegen drift check, once for integration tests, once for the example. A future optimization could share a single container across all three via a Vitest `globalSetup` or a pre-check script. Current total overhead is ~6-9 seconds, acceptable for now.

### `tsup` subpath export for Postgres adapter
The `tsup.config.ts` entry point for `adapters/postgres` points to `cat-repository.postgres.ts`. When the project is forked and cats are replaced, this entry point needs updating. The README fork guide mentions this.

### Zod v4 import path
Using `import { z } from 'zod/v4'` (Zod v4 subpath import). This is the current recommended import for Zod v4. If Zod changes this in a future release, the import paths will need updating.

## 10. Files That Need Human Review First

1. [src/domain/cat.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/domain/cat.ts) — Domain entity and value objects. The pattern every future domain type will copy.
2. [src/use-cases/create-cat.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/use-cases/create-cat.ts) — Use case pattern: deps-as-args, boundary validation, pure function. The template for all future use cases.
3. [src/index.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/index.ts) — Public API surface. Verify the export strategy (types + interfaces from root, concrete adapters from subpaths).
4. [.dependency-cruiser.cjs](https://github.com/FranciscoMateusVG/frame/blob/main/.dependency-cruiser.cjs) — The four architectural rules. Verify they match your intent.
5. [src/adapters/cat-repository.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/adapters/cat-repository.ts) — Repository interface (port). The contract every adapter must implement.
6. [src/adapters/cat-repository.postgres.ts](https://github.com/FranciscoMateusVG/frame/blob/main/src/adapters/cat-repository.postgres.ts) — Postgres adapter. Verify the Kysely usage pattern and error mapping.
7. [package.json](https://github.com/FranciscoMateusVG/frame/blob/main/package.json) — Scripts, exports field, dependency versions.
8. [.claude/CLAUDE.md](https://github.com/FranciscoMateusVG/frame/blob/main/.claude/CLAUDE.md) — Agent operating instructions. Verify the rules match your expectations.
9. [vitest.config.ts](https://github.com/FranciscoMateusVG/frame/blob/main/vitest.config.ts) — Per-file coverage thresholds. Verify they're scoped correctly.
10. [tests/helpers/test-db.ts](https://github.com/FranciscoMateusVG/frame/blob/main/tests/helpers/test-db.ts) — Testcontainers helper. Every integration test and example depends on this.

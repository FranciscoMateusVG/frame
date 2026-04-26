# Contributing to Frame

## Commit & Push Workflow

Frame uses Husky git hooks as the canonical quality gate. There is no server-side CI — the hooks are the only thing standing between your code and the repository.

### Pre-commit hook (fast)

Runs `lint-staged` on staged files:
- Biome check + auto-fix on `*.{ts,tsx,js,json}` files

This is fast and non-disruptive. It catches formatting and simple lint issues before they're committed.

### Pre-push hook (full verification)

Runs `pnpm check` — the complete Definition of Done:

```bash
pnpm lint              # Biome lint
pnpm depcruise         # Architectural rules
pnpm typecheck         # TypeScript strict
pnpm check:codegen-drift  # Generated types match schema
pnpm test:coverage     # All tests + coverage thresholds
tsx examples/*.ts      # Examples run cleanly
pnpm verify-hooks      # Hooks are installed
```

If **any** of these fail, the push is blocked. Fix the code, don't bypass the gate.

## ⚠️ --no-verify is Forbidden

**Do not use `git push --no-verify` or `git commit --no-verify`.**

There is no server-side CI fallback. The pre-push hook is the only quality gate. Bypassing it means broken code reaches the repository with no safety net.

This is not a suggestion — it's a rule. For human contributors and AI agents alike.

If you believe a hook is producing a false positive:
1. Investigate the failure
2. Fix the root cause (in the code or in the hook configuration)
3. Push normally

If you're stuck and need to push a WIP branch for backup or collaboration, create a draft PR and note in the description that checks are not passing.

## How the Hooks Work

- **Husky** manages git hooks in `.husky/`
- **lint-staged** (configured in `package.json`) runs Biome on staged files during pre-commit
- The pre-push hook calls `pnpm check` which runs the full pipeline
- `pnpm verify-hooks` (part of `pnpm check`) confirms hooks are installed and readable

Hooks are installed automatically via the `prepare` script when you run `pnpm install`.

## Working with Migrations

1. Create a new migration file in `migrations/` following the naming convention: `YYYYMMDD_NNN_description.ts`
2. Start your dev database: `pnpm db:up`
3. Run the migration: `pnpm db:migrate`
4. Regenerate types: `pnpm db:codegen`
5. Commit the updated `src/adapters/db-types.generated.ts`

The codegen drift check in `pnpm check` will catch if you forget step 4-5.

## Test Organization

```
tests/
├── unit/           # Fast tests using in-memory adapters
├── integration/    # Tests against real Postgres via Testcontainers
└── helpers/        # Shared test utilities (e.g., Testcontainers setup)
```

- **Unit tests**: Use the in-memory adapter. Fast, no Docker needed.
- **Integration tests**: Spin up Postgres via Testcontainers. Docker must be running.
- **Property-based tests**: Use fast-check in `tests/unit/`. Good for invariants.
- **Examples**: `examples/*.ts` run as smoke tests during `pnpm check`.

## Architectural Rules

Enforced by dependency-cruiser (see `.dependency-cruiser.cjs`):

1. `domain/` → can only import from `domain/`
2. `use-cases/` → can import from `domain/` and adapter interfaces, not concrete implementations
3. Nothing imports from `index.ts` internally
4. No circular dependencies

Run `pnpm depcruise` to check manually.

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

## Project Structure

```
src/domain/       — Types, entities, value objects. No I/O.
src/use-cases/    — One file per use case. Pure functions taking deps as args.
src/adapters/     — Infrastructure: interfaces + implementations.
src/errors/       — Typed error classes.
src/index.ts      — Public API surface.
tests/unit/       — Unit + property-based tests.
tests/integration/ — Tests against real Postgres via Testcontainers.
examples/         — Runnable examples (executed in CI).
migrations/       — Kysely migration files.
scripts/          — Build/check scripts.
```

## Adding a New Use Case

1. Define types in `src/domain/`.
2. Define the repository interface in `src/adapters/`.
3. Write the use case in `src/use-cases/` as a pure function taking deps as args.
4. Add typed errors in `src/errors/`.
5. Export public types and use case from `src/index.ts`.
6. Write unit tests in `tests/unit/`.
7. Write integration tests in `tests/integration/`.
8. Run `pnpm check` — all green before committing.

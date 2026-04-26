# Frame

AI-native TypeScript SDK skeleton — a reusable, domain-agnostic project structure and tooling baseline designed for autonomous AI development.

Frame contains no real business logic. It's a reference implementation with a placeholder domain (**Cats**) that demonstrates the full pattern end-to-end. Fork it, replace the placeholder domain with your own, and start building.

## Prerequisites

- **Node.js** ≥ 20
- **pnpm** (any recent version)
- **Docker** (for Postgres — used by integration tests, examples, and the codegen drift check)

## Quick Start

```bash
git clone https://github.com/FranciscoMateusVG/frame.git
cd frame
pnpm install
pnpm check   # runs lint, depcruise, typecheck, codegen drift, tests, examples, hook verification
```

That's it. `pnpm check` is fully self-contained — it spins up Postgres via Testcontainers, runs migrations, and tears everything down. No manual Docker Compose setup required.

### Development Database (Optional)

For interactive development, you can run a persistent Postgres:

```bash
pnpm db:up       # start Postgres via Docker Compose (port 54320)
pnpm db:migrate  # run migrations
pnpm db:codegen  # regenerate Kysely types from live schema
pnpm db:down     # stop Postgres
pnpm db:reset    # drop volume, restart, re-run migrations
```

## Available Scripts

| Script | What it does |
|--------|-------------|
| `pnpm lint` | Biome lint + format check |
| `pnpm lint:fix` | Auto-fix lint issues |
| `pnpm typecheck` | TypeScript strict type check |
| `pnpm test` | Run all tests (Vitest) |
| `pnpm test:watch` | Run tests in watch mode |
| `pnpm test:coverage` | Run tests with coverage thresholds |
| `pnpm depcruise` | Check architectural rules |
| `pnpm check:codegen-drift` | Verify generated types match live schema |
| `pnpm verify-hooks` | Verify git hooks are installed |
| `pnpm build` | Build ESM + CJS with types (tsup) |
| `pnpm check` | **Run all checks** — the Definition of Done |

## Architecture

Hexagonal-ish, by hand. No framework, no DI container, no decorators.

```
src/
├── domain/         # Types, entities, value objects. No I/O.
├── use-cases/      # One file per use case. Pure functions taking deps as args.
├── adapters/       # Infrastructure: interfaces + implementations.
├── errors/         # Typed error classes.
└── index.ts        # Public API surface.
```

### Architectural Rules (enforced by dependency-cruiser)

1. **`domain/` cannot import from anywhere except other `domain/` files.** The domain layer is pure — no infrastructure, no I/O.
2. **`use-cases/` can import from `domain/` and adapter interfaces**, but never from concrete adapter implementations.
3. **Nothing internal imports from `index.ts`.** The barrel is for consumers only.
4. **No circular dependencies, anywhere.**

Violations are caught by `pnpm depcruise` and blocked by the pre-push hook.

## How to Add a New Use Case

Step-by-step recipe:

### 1. Define the domain types

Create or extend files in `src/domain/`:

```typescript
// src/domain/dog.ts
import { z } from 'zod/v4';

export const DogNameSchema = z.string().trim().min(1).max(100);
export type DogName = string;

export interface Dog {
  readonly id: string;
  readonly name: DogName;
  readonly breed: string;
  readonly createdAt: Date;
}
```

### 2. Define the repository interface

```typescript
// src/adapters/dog-repository.ts
import type { Dog } from '../domain/dog.js';

export interface DogRepository {
  save(dog: Dog): Promise<void>;
  findById(id: string): Promise<Dog | undefined>;
}
```

### 3. Implement the adapters

- `src/adapters/dog-repository.memory.ts` — for tests
- `src/adapters/dog-repository.postgres.ts` — for production

### 4. Write the use case

```typescript
// src/use-cases/create-dog.ts
import type { Dog } from '../domain/dog.js';
import type { DogRepository } from '../adapters/dog-repository.js';

export interface CreateDogDeps {
  readonly dogRepository: DogRepository;
}

export async function createDog(deps: CreateDogDeps, input: { id: string; name: string; breed: string }): Promise<Dog> {
  // validate, create, persist
}
```

### 5. Add errors

```typescript
// src/errors/dog-already-exists.error.ts
export class DogAlreadyExistsError extends Error {
  public readonly code = 'DOG_ALREADY_EXISTS' as const;
  constructor(public readonly name: string) {
    super(`A dog named "${name}" already exists.`);
  }
}
```

### 6. Export from index.ts

Add types, use case, and adapter interface to `src/index.ts`. Do **not** export concrete adapters from here.

### 7. Add migration

Create a new migration in `migrations/`, run `pnpm db:codegen`, and commit the updated generated types.

### 8. Write tests

- Unit tests in `tests/unit/`
- Integration tests in `tests/integration/`
- Property-based tests using fast-check

### 9. Verify

```bash
pnpm check  # must be green
```

## How to Fork Frame for a New Project

1. **Fork or clone** this repo
2. **Rename** `frame` → your project name in `package.json`
3. **Delete** everything in `src/domain/`, `src/use-cases/`, `src/adapters/` (except `database.ts` and the generated types), `src/errors/`, and `tests/`
4. **Delete** `migrations/` contents and create your own
5. **Update** `src/index.ts` to export your domain
6. **Update** `tsup.config.ts` entry points
7. **Run** `pnpm db:codegen` after creating your first migration
8. **Replace** the Cat examples with your own in `examples/`
9. **Run** `pnpm check` to verify everything is clean

## Stack

| Concern | Tool |
|---------|------|
| Language | TypeScript (strict) |
| Database | PostgreSQL 16 |
| DB access | Kysely + kysely-codegen |
| Migrations | Kysely built-in Migrator |
| Validation | Zod (external boundaries only) |
| Testing | Vitest + fast-check |
| Lint/format | Biome |
| Arch rules | dependency-cruiser |
| Git hooks | Husky + lint-staged |
| Build | tsup (ESM + CJS) |
| Package manager | pnpm |

## License

MIT

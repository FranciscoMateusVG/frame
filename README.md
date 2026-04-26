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
├── observability/  # Logger interface, implementations, tracer re-exports.
├── testing/        # Exported test helpers (frame/testing subpath).
└── index.ts        # Public API surface.
```

## Observability

Frame ships structured logging and distributed tracing via OpenTelemetry as first-class concerns. The design is **no-op by default**: without an OTel SDK registered, all tracing and logging operations silently do nothing. Zero overhead, zero crashes.

### How It Works

- **Use cases** receive an `Observability` object (Logger + Tracer) via deps. Each use case wraps in a span and logs meaningful business events.
- **Adapters** use `trace.getTracer('frame')` at module level. Span nesting (e.g., `createCat` → `db.cats.save`) happens automatically via OTel's AsyncLocalStorage-backed context propagation.
- **Logger** has three implementations: `ConsoleLogger` (dev/examples), `NoopLogger` (tests), and `OtelLogger` (production — forwards to OTel Logs API with automatic trace correlation).

### Wiring Up OTel (Consumer's Responsibility)

Frame deliberately does NOT provide a `setupObservability()` helper. Consumers own SDK configuration — sampling, exporter choice, and resource attributes are your decisions, not Frame's.

Install the OTel SDK packages (listed as optional peer dependencies):

```bash
pnpm add @opentelemetry/sdk-trace-base @opentelemetry/sdk-trace-node
```

See [`examples/create-cat.with-otel.ts`](examples/create-cat.with-otel.ts) for the complete, copy-pasteable setup:

```typescript
import { trace } from '@opentelemetry/api';
import { ConsoleSpanExporter, SimpleSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';

const provider = new NodeTracerProvider({
  spanProcessors: [new SimpleSpanProcessor(new ConsoleSpanExporter())],
});
provider.register(); // Sets global provider + enables AsyncLocalStorage context propagation

// Now all Frame spans are live — createCat, db.cats.save, etc.
```

For production, replace `ConsoleSpanExporter` with your backend's exporter:
- **OTLP (Jaeger, Grafana Tempo):** `@opentelemetry/exporter-trace-otlp-http`
- **Honeycomb:** `@honeycombio/opentelemetry-node`
- **Datadog:** `dd-trace` with OTel compatibility

Consumers may additionally install `@opentelemetry/instrumentation-pg` for automatic query-level Postgres tracing. Frame's manual spans remain valuable for use-case-level and repository-level visibility.

### Testing Spans

Frame exports `createTestObservability()` under the `frame/testing` subpath for consumers to assert on span emission:

```typescript
import { createTestObservability } from 'frame/testing';

const { observability, getSpans, reset, shutdown } = createTestObservability();

// ... run your use case ...
const spans = getSpans();
expect(spans.find(s => s.name === 'myUseCase')).toBeDefined();
```

### Instrumentation Rules

- **Instrument:** use case entry points, adapter I/O methods (DB, HTTP, external services).
- **Do NOT instrument:** Zod validation, domain pure functions, value object construction.
- **PII discipline:** span attributes capture shapes (`cat.name.length`), not raw values.
- **Adapters emit spans only** — they do not log. Logs come from use cases for meaningful business events.

### Architectural Rules (enforced by dependency-cruiser)

1. **`domain/` cannot import from anywhere except other `domain/` files.** The domain layer is pure — no infrastructure, no I/O.
2. **`use-cases/` can import from `domain/` and adapter interfaces**, but never from concrete adapter implementations.
3. **Nothing internal imports from `index.ts`.** The barrel is for consumers only.
4. **No OTel SDK imports in production code.** `src/` (except `src/testing/`) only uses the OTel API. The SDK is for tests, examples, and consumer setup.
5. **No circular dependencies, anywhere.**

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
  readonly clock: () => Date;
  readonly observability: Observability;
}

export async function createDog(deps: CreateDogDeps, input: { id: string; name: string; breed: string }): Promise<Dog> {
  const { dogRepository, clock, observability } = deps;
  return observability.tracer.startActiveSpan('createDog', async (span) => {
    // validate, create, persist — see createCat for the full pattern
  });
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
| Tracing | OpenTelemetry API (SDK in tests/examples only) |
| Logging | OTel Logs API (ConsoleLogger for dev) |
| Testing | Vitest + fast-check |
| Lint/format | Biome |
| Arch rules | dependency-cruiser |
| Git hooks | Husky + lint-staged |
| Build | tsup (ESM + CJS) |
| Package manager | pnpm |

## License

MIT

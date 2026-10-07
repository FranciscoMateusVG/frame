# Frame (Elixir)

AI-native Elixir SDK skeleton — a reusable, domain-agnostic project structure and tooling baseline designed for autonomous AI development.

Frame contains no real business logic. It's a reference implementation with a placeholder domain (**Cats**) that demonstrates the full pattern end-to-end. Fork it, replace the placeholder domain with your own, and start building.

This branch is the Elixir port of the TypeScript reference (`main`). Every TypeScript item and its Elixir counterpart — including every deviation — is listed in [`PARITY.md`](PARITY.md).

## Prerequisites

- **Elixir** ≥ 1.18 (built-in `JSON`; developed on 1.20 / OTP 29)
- **Docker** (for Postgres — used by integration tests, examples, and the codegen drift check)

## Quick Start

```bash
git clone https://github.com/FranciscoMateusVG/frame.git
cd frame
git checkout frame-elixir
mix setup    # deps.get + install the git hooks (core.hooksPath = .githooks)
mix check    # runs lint, structure, typecheck, depcruise, codegen drift, tests, examples, hook verification
```

That's it. `mix check` is fully self-contained — it spins up Postgres via Testcontainers, runs migrations, and tears everything down. No manual Docker Compose setup required.

### Development Database (Optional)

For interactive development, you can run a persistent Postgres:

```bash
mix db.up       # start Postgres via Docker Compose (port 54320)
mix db.migrate  # run migrations
mix db.codegen  # regenerate the Ecto schema module from the live schema
mix db.down     # stop Postgres
mix db.reset    # drop volume, restart, re-run migrations
```

## Available Commands

| Command | What it does |
|--------|-------------|
| `mix lint` | `mix format --check-formatted` + `mix credo --strict` |
| `mix lint.fix` | Auto-format (`mix format`) |
| `mix frame.lint_structure` | Enforce folder/file layout |
| `mix typecheck` | `mix compile --warnings-as-errors` (Elixir's built-in type checker + all compiler warnings) |
| `mix test` | Run all tests (ExUnit) |
| `mix test.coverage` | Run tests with coverage thresholds |
| `mix frame.depcruise` | Check architectural (import-graph) rules |
| `mix frame.check_codegen_drift` | Verify the generated schema module matches the live schema |
| `mix frame.verify_hooks` | Verify git hooks are installed |
| `mix build` | Build the Hex package tarball (`mix hex.build`) |
| `mix check` | **Run all checks** — the Definition of Done |

`mix check` and `mix test.coverage` run in the `test` environment automatically.

## Architecture

Hexagonal-ish, by hand. No framework, no DI container, no macros-as-DI.

```
lib/
├── frame.ex            # Public API surface.
└── frame/
    ├── domain/         # Structs, value types, boundary parsers. No I/O.
    ├── use_cases/      # One file per use case. Plain functions taking deps as args.
    ├── adapters/       # Infrastructure: ports (behaviours) + implementations.
    ├── errors/         # Typed errors (exception structs).
    ├── observability/  # Logger port + implementations, tracer helpers, Observability struct.
    └── testing/        # Exported test helpers (Frame.Testing). Uses the OTel SDK.
```

Ports are behaviours whose implementations are structs: `Frame.Adapters.CatRepository` (the port) dispatches on the struct it is given (`%CatRepository.Postgres{}`, `%CatRepository.Memory{}`), so use cases depend only on the port.

Typed errors are returned, not raised: `create_cat/2` returns `{:ok, cat}` or `{:error, %InvalidCatNameError{}}` / `{:error, %CatAlreadyExistsError{}}`. Unexpected failures (database down, bugs) raise.

## Observability

Frame ships structured logging and distributed tracing via OpenTelemetry as first-class concerns. The design is **no-op by default**: without the OTel SDK started, all tracing operations silently do nothing. Zero overhead, zero crashes.

### How It Works

- **Use cases** receive an `%Observability{logger, tracer}` struct via deps. Each use case wraps in a span and logs meaningful business events.
- **Adapters** use their application's tracer through the `OpenTelemetry.Tracer` macros (the BEAM equivalent of `trace.getTracer('frame')`). Span nesting (e.g. `createCat` → `db.cats.save`) happens automatically via OTel's process-local context propagation.
- **Logger** has three implementations: `ConsoleLogger` (dev/examples), `NoopLogger` (tests), and `OtelLogger` (production — emits through OTP `:logger`, the OTel logs bridge on the BEAM, with automatic trace correlation).

### Wiring Up OTel (Consumer's Responsibility)

Frame deliberately does NOT provide a `setup_observability()` helper. Consumers own SDK configuration — sampling, exporter choice, and resource attributes are your decisions, not Frame's.

Add the SDK (Frame lists it as an optional dependency):

```elixir
{:opentelemetry, "~> 1.7"}
```

See [`examples/create_cat.with_otel.exs`](examples/create_cat.with_otel.exs) for the complete, copy-pasteable setup:

```elixir
Application.put_env(:opentelemetry, :span_processor, :simple)
Application.put_env(:opentelemetry, :traces_exporter, {:otel_exporter_stdout, []})
{:ok, _} = Application.ensure_all_started(:opentelemetry)

# Now all Frame spans are live — createCat, db.cats.save, etc.
```

For production, configure an exporter instead of stdout:
- **OTLP (Jaeger, Grafana Tempo):** `opentelemetry_exporter` with `traces_exporter: :otlp`
- **Honeycomb / Datadog:** their OTLP endpoints via `opentelemetry_exporter`

For logs, install the SDK log handler (`otel_log_handler` from `opentelemetry_experimental`) as a `:logger` handler; `OtelLogger` records then flow to it with trace IDs attached.

### Testing Spans

Frame exports `Frame.Testing.Observability.create_test_observability/0` (compiled when the optional SDK dependency is present) for consumers to assert on span emission:

```elixir
alias Frame.Testing.Observability, as: TestObs

test_obs = TestObs.create_test_observability()
on_exit(fn -> TestObs.shutdown(test_obs) end)

# ... run your use case with observability: test_obs.observability ...
assert Enum.find(TestObs.get_spans(test_obs), &(&1.name == "myUseCase"))
```

### Instrumentation Rules

- **Instrument:** use case entry points, adapter I/O functions (DB, HTTP, external services).
- **Do NOT instrument:** boundary parsing/validation, domain pure functions, value construction.
- **PII discipline:** span attributes capture shapes (`cat.name.length`), not raw values.
- **Adapters emit spans only** — they do not log. Logs come from use cases for meaningful business events.

### Architectural Rules (enforced by `mix frame.depcruise`)

1. **`domain/` cannot depend on anything in `lib/` except other `domain/` files.** The domain layer is pure — no infrastructure, no I/O.
2. **`use_cases/` can depend on `domain/` and adapter ports**, but never on concrete adapter implementations.
3. **Nothing internal depends on `lib/frame.ex`.** The entry point is for consumers only.
4. **No OTel SDK in production code.** `lib/` (except `lib/frame/testing/`) only uses the OTel API. The SDK is for tests, examples, and consumer setup.
5. **No circular dependencies, anywhere.**

The gate reads the compiled BEAM debug info, so calls, struct literals, typespecs and captures all count as dependencies. Violations fail `mix check` and therefore the pre-push hook.

### Folder Layout Rules (enforced by `mix frame.lint_structure`)

The import-graph rules above are paired with a structural gate on file and folder layout (rules live in `scripts/lint_structure.ex`):

- **`lib/frame/domain/`, `use_cases/`, `observability/`, `testing/`** — flat folders of snake_case `*.ex` files. No nested subdirectories.
- **`lib/frame/adapters/`** — `<port>.ex` (the behaviour) and `<port>/<impl>.ex` (concrete adapters, e.g. `cat_repository/postgres.ex`).
- **`lib/frame/errors/`** — `<entity>_<thing>_error.ex`.
- **`test/{unit,integration}/`** — `*_test.exs` and `*.<flavor>_test.exs` (e.g. `cat_repository.memory_test.exs`).
- **`test/helpers/`** — flat snake_case `*.ex`, optionally with one dotted qualifier (`cat_repository.conformance.ex`).
- **`examples/`** — `<use_case>.exs`, `<use_case>.with_<integration>.exs`, `<use_case>.<flavor>.exs` (e.g. `create_cat.plug.exs`).
- **`migrations/`** — `<YYYYMMDD>_<NNN>_<snake_name>.exs` (snake_case shape enforced).
- **`scripts/`** — flat snake_case `*.ex`/`*.exs` (the Mix tasks behind the gate).

To allow a new file shape, extend `structure/0` in `scripts/lint_structure.ex`. To make a one-off exception, add it to `@ignore_patterns`.

## Examples

The `examples/` directory holds runnable demonstrations of Frame's patterns. Each example is fully self-contained — Testcontainers spins up Postgres on demand — and is executed as part of `mix check` (`MIX_ENV=test mix run examples/<file>`).

| File | What it shows |
|------|--------------|
| `examples/create_cat.exs` | Bare SDK usage — wire up `CatRepository.Postgres`, call `create_cat`, fetch + delete |
| `examples/create_cat.with_otel.exs` | Same flow with the full OTel SDK started. Spans printed by the stdout exporter |
| `examples/create_cat.plug.exs` | Use case exposed as an HTTP API via [Plug](https://hexdocs.pm/plug) + [Bandit](https://hexdocs.pm/bandit). Demonstrates how a transport adapter stays a thin shell — parse → invoke use case → translate domain errors to HTTP status codes (201 / 200 / 404 / 409 / 400) |

The Plug example is the template for any transport layer (Plug, Phoenix, gRPC). Frame stays transport-agnostic: the use case takes `(deps, input)`, returns `{:ok, entity}` or a typed `{:error, error}`. The route handler is the only place HTTP exists.

## How to Add a New Use Case

### 1. Define the domain types

```elixir
# lib/frame/domain/dog.ex
defmodule Frame.Domain.Dog do
  @enforce_keys [:id, :name, :breed, :created_at]
  defstruct [:id, :name, :breed, :created_at]

  @type t :: %__MODULE__{id: String.t(), name: String.t(), breed: String.t(), created_at: DateTime.t()}

  @spec parse_dog_name(term()) :: {:ok, String.t()} | {:error, [String.t()]}
  def parse_dog_name(value), do: ...
end
```

### 2. Define the repository port

```elixir
# lib/frame/adapters/dog_repository.ex
defmodule Frame.Adapters.DogRepository do
  alias Frame.Domain.Dog

  @callback save(struct(), Dog.t()) :: :ok | {:error, Exception.t()}
  @callback find_by_id(struct(), String.t()) :: Dog.t() | nil

  def save(%impl{} = repo, dog), do: impl.save(repo, dog)
  def find_by_id(%impl{} = repo, id), do: impl.find_by_id(repo, id)
end
```

### 3. Implement the adapters

- `lib/frame/adapters/dog_repository/memory.ex` — for tests
- `lib/frame/adapters/dog_repository/postgres.ex` — for production

### 4. Write the use case

```elixir
# lib/frame/use_cases/create_dog.ex
defmodule Frame.UseCases.CreateDog do
  @type deps :: %{dog_repository: struct(), clock: (-> DateTime.t()), observability: Observability.t()}

  def create_dog(%{dog_repository: repo, clock: clock, observability: obs}, input) do
    :otel_tracer.with_span(obs.tracer, "createDog", %{}, fn span ->
      # validate, create, persist — see Frame.UseCases.CreateCat for the full pattern
    end)
  end
end
```

### 5. Add errors

```elixir
# lib/frame/errors/dog_already_exists_error.ex
defmodule Frame.Errors.DogAlreadyExistsError do
  defexception [:name, :message, code: "DOG_ALREADY_EXISTS"]

  @impl true
  def exception(name), do: %__MODULE__{name: name, message: ~s(A dog named "#{name}" already exists.)}
end
```

### 6. Expose from `Frame`

Document the new modules in `lib/frame.ex` and add a `defdelegate` for the use case. Do **not** surface concrete adapters there.

### 7. Add migration

Create a new migration in `migrations/`, run `mix db.codegen`, and commit the updated `lib/frame/adapters/db_types.generated.ex`.

### 8. Write tests

- Unit tests in `test/unit/`
- Integration tests in `test/integration/`
- Property-based tests using StreamData

### 9. Verify

```bash
mix check  # must be green
```

## How to Fork Frame for a New Project

1. **Fork or clone** this repo
2. **Rename** `:frame` / `Frame` → your project name in `mix.exs` and module names
3. **Delete** everything in `lib/frame/domain/`, `lib/frame/use_cases/`, `lib/frame/adapters/` (except `database.ex` and the generated schema), `lib/frame/errors/`, and the tests
4. **Delete** `migrations/` contents and create your own
5. **Update** `lib/frame.ex` to expose your domain
6. **Run** `mix db.codegen` after creating your first migration
7. **Replace** the Cat examples with your own in `examples/`
8. **Run** `mix check` to verify everything is clean

## Stack

| Concern | Tool |
|---------|------|
| Language | Elixir (compiler type checker, warnings as errors) |
| Database | PostgreSQL 16 |
| DB access | Ecto (`Ecto.Query`) + Postgrex |
| Migrations | `Ecto.Migrator` |
| Schema codegen | `mix frame.db_codegen` (Ecto schema from the live schema) |
| Validation | Hand-written boundary parsers in the domain (Zod-compatible semantics) |
| Tracing | OpenTelemetry API (`opentelemetry_api`; SDK in tests/examples only) |
| Logging | OTP `:logger` as the OTel logs bridge (ConsoleLogger for dev) |
| Testing | ExUnit + StreamData + testcontainers-elixir |
| Lint/format | `mix format` + Credo |
| Arch rules (imports) | `mix frame.depcruise` (BEAM debug-info dependency graph) |
| Arch rules (layout) | `mix frame.lint_structure` |
| Git hooks | `.githooks/` via `core.hooksPath` |
| HTTP example | Plug + Bandit |
| Build | `mix hex.build` |

## License

MIT

defmodule Frame do
  @moduledoc """
  Frame — public API surface.

  Elixir has no per-module export control, so the "public surface" is a
  convention, documented here and enforced by `mix frame.depcruise`:

    * **Domain:** `Frame.Domain.Cat` (entity, value-object types, boundary parsers)
    * **Adapter interfaces:** `Frame.Adapters.CatRepository` (port — implement your own)
    * **Database utilities:** `Frame.Adapters.Database` (`create_database/1`)
    * **Errors:** `Frame.Errors.CatAlreadyExistsError`, `Frame.Errors.InvalidCatNameError`
    * **Observability:** `Frame.Observability.{Logger, ConsoleLogger, NoopLogger,
      OtelLogger, Observability, Tracer}`
    * **Use cases:** `create_cat/2` (below) / `Frame.UseCases.CreateCat`

  Concrete adapters are deliberately NOT surfaced here. They live in their
  own modules (the equivalent of the TypeScript subpath exports):

    * `Frame.Adapters.CatRepository.Postgres` (≈ `frame/adapters/postgres`)
    * `Frame.Testing.Observability` (≈ `frame/testing`)

  Nothing inside `lib/frame/` may depend on this module.
  """

  alias Frame.UseCases.CreateCat

  @doc "See `Frame.UseCases.CreateCat.create_cat/2`."
  @spec create_cat(CreateCat.deps(), term()) ::
          {:ok, Frame.Domain.Cat.t()} | {:error, CreateCat.error()}
  defdelegate create_cat(deps, input), to: CreateCat

  @doc "See `Frame.Adapters.Database.create_database/1`."
  @spec create_database(String.t()) :: Frame.Adapters.Database.t()
  defdelegate create_database(connection_string), to: Frame.Adapters.Database

  @doc "See `Frame.Observability.Tracer.noop_tracer/0`."
  @spec noop_tracer() :: Frame.Observability.Tracer.t()
  defdelegate noop_tracer(), to: Frame.Observability.Tracer
end

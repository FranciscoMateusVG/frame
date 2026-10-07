defmodule Frame.Adapters.CatRepository.Postgres do
  @moduledoc """
  PostgreSQL CatRepository implementation using Ecto queries over the
  generated schema (`Frame.Adapters.DbTypes.Cats`). Concrete adapter — not
  exposed from the public `Frame` module.

  Instrumented: every function wraps in a span named `db.cats.<method>` with
  OTel semantic convention attributes. Spans nest automatically under the
  active parent (e.g. a `createCat` use-case span) via OTel's process-local
  context propagation.

  Adapters emit spans only — they do not log. Spans carry operation name,
  attributes, and exceptions via `record_exception`. Logging is a use-case
  concern.
  """

  @behaviour Frame.Adapters.CatRepository

  import Ecto.Query, only: [from: 2]

  require OpenTelemetry.Tracer, as: Tracer

  alias Frame.Adapters.Database
  alias Frame.Adapters.DbTypes.Cats
  alias Frame.Domain.Cat
  alias Frame.Errors.CatAlreadyExistsError
  alias OpenTelemetry.Span

  @enforce_keys [:db]
  defstruct [:db]

  @type t :: %__MODULE__{db: Database.t()}

  # Shared span attributes for all Postgres cat repository operations.
  @db_attrs %{"db.system": "postgresql", "db.collection.name": "cats"}

  @spec new(Database.t()) :: t()
  def new(%Database{} = db), do: %__MODULE__{db: db}

  @impl true
  def save(%__MODULE__{db: db}, %Cat{} = cat) do
    traced("db.cats.save", "INSERT", fn ->
      row = %{id: cat.id, name: cat.name, created_at: cat.created_at}

      try do
        Database.run(db, & &1.insert_all(Cats, [row]))
        :ok
      rescue
        error in Postgrex.Error ->
          if unique_violation?(error),
            do: {:error, CatAlreadyExistsError.exception(cat.name)},
            else: reraise(error, __STACKTRACE__)
      end
    end)
  end

  @impl true
  def find_by_id(%__MODULE__{db: db}, id) do
    traced("db.cats.findById", "SELECT", fn ->
      db |> Database.run(& &1.one(from(c in Cats, where: c.id == ^id))) |> to_cat()
    end)
  end

  @impl true
  def find_by_name(%__MODULE__{db: db}, name) do
    traced("db.cats.findByName", "SELECT", fn ->
      db |> Database.run(& &1.one(from(c in Cats, where: c.name == ^name))) |> to_cat()
    end)
  end

  @impl true
  def delete_by_id(%__MODULE__{db: db}, id) do
    traced("db.cats.deleteById", "DELETE", fn ->
      {deleted, _} = Database.run(db, & &1.delete_all(from(c in Cats, where: c.id == ^id)))
      deleted > 0
    end)
  end

  defp traced(span_name, operation, fun) do
    attributes = Map.put(@db_attrs, :"db.operation.name", operation)

    Tracer.with_span span_name, %{attributes: attributes} do
      span = Tracer.current_span_ctx()

      try do
        case fun.() do
          {:error, error} = result ->
            Span.record_exception(span, error)
            Span.set_status(span, OpenTelemetry.status(:error))
            result

          result ->
            Span.set_status(span, OpenTelemetry.status(:ok))
            result
        end
      rescue
        error ->
          Span.record_exception(span, error, __STACKTRACE__)
          Span.set_status(span, OpenTelemetry.status(:error))
          reraise error, __STACKTRACE__
      end
    end
  end

  defp to_cat(nil), do: nil
  defp to_cat(%Cats{} = row), do: %Cat{id: row.id, name: row.name, created_at: row.created_at}

  # SQLSTATE 23505 — same check as the reference `isUniqueViolation`.
  defp unique_violation?(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: true
  defp unique_violation?(_error), do: false
end

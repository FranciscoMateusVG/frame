defmodule Frame.Adapters.CatRepository.Memory do
  @moduledoc """
  In-memory CatRepository implementation, backed by an `Agent`.
  Used for unit tests and examples that don't need a real database.

  Instrumented identically to the Postgres adapter: same span names, same
  attributes (`db.system` is `"memory"` instead of `"postgresql"`). The
  conformance suite asserts both produce equivalent spans.

  Adapters emit spans only — they do not log.
  """

  @behaviour Frame.Adapters.CatRepository

  require OpenTelemetry.Tracer, as: Tracer

  alias Frame.Domain.Cat
  alias Frame.Errors.CatAlreadyExistsError
  alias OpenTelemetry.Span

  @enforce_keys [:agent]
  defstruct [:agent]

  @type t :: %__MODULE__{agent: pid()}

  # Shared span attributes for all in-memory cat repository operations.
  @db_attrs %{"db.system": "memory", "db.collection.name": "cats"}

  @doc "Creates an empty repository (the Agent is linked to the caller)."
  @spec new() :: t()
  def new do
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    %__MODULE__{agent: agent}
  end

  @impl true
  def save(%__MODULE__{agent: agent}, %Cat{} = cat) do
    traced("db.cats.save", "INSERT", fn ->
      Agent.get_and_update(agent, &insert_unique(&1, cat))
    end)
  end

  @impl true
  def find_by_id(%__MODULE__{agent: agent}, id) do
    traced("db.cats.findById", "SELECT", fn -> Agent.get(agent, &Map.get(&1, id)) end)
  end

  @impl true
  def find_by_name(%__MODULE__{agent: agent}, name) do
    traced("db.cats.findByName", "SELECT", fn -> Agent.get(agent, &find_named(&1, name)) end)
  end

  @impl true
  def delete_by_id(%__MODULE__{agent: agent}, id) do
    traced("db.cats.deleteById", "DELETE", fn ->
      Agent.get_and_update(agent, fn cats -> {Map.has_key?(cats, id), Map.delete(cats, id)} end)
    end)
  end

  # Same-ID saves overwrite (Map semantics); only names are unique — as in the reference.
  defp insert_unique(cats, %Cat{} = cat) do
    case find_named(cats, cat.name) do
      nil -> {:ok, Map.put(cats, cat.id, cat)}
      _existing -> {{:error, CatAlreadyExistsError.exception(cat.name)}, cats}
    end
  end

  defp find_named(cats, name) do
    Enum.find_value(cats, fn {_id, cat} -> if cat.name == name, do: cat end)
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
end

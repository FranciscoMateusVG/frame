defmodule Frame.UseCases.CreateCat do
  @moduledoc """
  The `createCat` use case — the template every future use case copies.
  """

  alias Frame.Adapters.CatRepository
  alias Frame.Domain.Cat
  alias Frame.Errors.CatAlreadyExistsError
  alias Frame.Errors.InvalidCatNameError
  alias Frame.Observability.Logger
  alias Frame.Observability.Observability
  alias OpenTelemetry.Span

  @typedoc """
  Dependencies required by `create_cat/2`. Passed explicitly as the first
  argument — no DI container, no magic.
  """
  @type deps :: %{
          required(:cat_repository) => CatRepository.t(),
          required(:clock) => (-> DateTime.t()),
          required(:observability) => Observability.t()
        }

  @type error :: InvalidCatNameError.t() | CatAlreadyExistsError.t()

  @doc """
  Create a new Cat.

  Pure function: takes dependencies and input, returns the created Cat.
  Validates input at the boundary, delegates persistence to the repository.

  **IDs are caller-provided** to support idempotent retries and composability
  with related entities. Callers should generate UUIDs (e.g.
  `Ecto.UUID.generate/0`) and may safely retry with the same ID — duplicate
  creates are caught by the repository's unique constraint on name and
  surfaced as `CatAlreadyExistsError`. Malformed IDs are caught by input
  validation and surfaced as `InvalidCatNameError`.

  **Instrumented:** wraps in a `createCat` span. On success, logs
  `cat.created`. On failure, records the exception on the span and sets
  ERROR status.

  Returns `{:error, %InvalidCatNameError{}}` if the input fails validation
  (including malformed IDs) and `{:error, %CatAlreadyExistsError{}}` if a cat
  with the same name already exists (from the repository).
  """
  @spec create_cat(deps(), term()) :: {:ok, Cat.t()} | {:error, error()}
  def create_cat(deps, input) do
    %{cat_repository: cat_repository, clock: clock, observability: observability} = deps
    %Observability{logger: logger, tracer: tracer} = observability

    :otel_tracer.with_span(tracer, "createCat", %{}, fn span ->
      try do
        with {:ok, parsed} <- parse_input(input),
             # Non-PII span attributes — capture shapes, not raw values
             _ = Span.set_attribute(span, :"cat.id", parsed.id),
             _ = Span.set_attribute(span, :"cat.name.length", Cat.name_length(parsed.name)),
             cat = %Cat{id: parsed.id, name: parsed.name, created_at: clock.()},
             :ok <- CatRepository.save(cat_repository, cat) do
          Logger.info(logger, "cat.created", %{
            catId: cat.id,
            nameLength: Cat.name_length(cat.name)
          })

          Span.set_status(span, OpenTelemetry.status(:ok))
          {:ok, cat}
        else
          {:error, error} -> {:error, record_failure(span, error)}
        end
      rescue
        error -> reraise record_failure(span, error, __STACKTRACE__), __STACKTRACE__
      end
    end)
  end

  # Typed failures are returned, unexpected ones re-raised — both are recorded
  # on the span first.
  defp record_failure(span, error, stacktrace \\ nil) do
    Span.record_exception(span, error, stacktrace)
    Span.set_status(span, OpenTelemetry.status(:error, Exception.message(error)))
    error
  end

  # Validate at the boundary
  defp parse_input(input) do
    case Cat.parse_create_cat_input(input) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, issues} -> {:error, InvalidCatNameError.exception(Enum.join(issues, "; "))}
    end
  end
end

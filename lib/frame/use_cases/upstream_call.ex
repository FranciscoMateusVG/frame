defmodule Frame.UseCases.UpstreamCall do
  @moduledoc """
  The shared shape of every use case that talks to the Incluir print API:
  one span named after the use case, upstream contract answers relayed,
  and every "the upstream cannot serve us" case collapsed into
  `UPSTREAM_UNAVAILABLE` (spec §4.5):

    * transport failure, timeout, off-contract body (`{:error, :unavailable}`);
    * 401/403 — the service token was refused (configuration problem: the
      supplier must not be asked for the password again);
    * 5xx (`NOT_CONFIGURED`, `INTERNAL`, …).

  Logs only the operation and status — never bodies, ids of files, names
  or amounts.
  """

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Errors.PortalError
  alias Frame.Observability.Logger
  alias Frame.Observability.Observability
  alias OpenTelemetry.Span

  @type deps :: %{required(:observability) => Observability.t(), optional(atom()) => term()}

  @doc """
  Runs `call` (a port call returning `{:ok, Response.t()}` or
  `{:error, :unavailable}`) inside a span named `name` with `attributes`.
  `call` may also return `{:error, %PortalError{}}` for a failure found
  before reaching the upstream (e.g. document validation).
  """
  @spec run(
          deps(),
          String.t(),
          map(),
          (-> {:ok, Response.t()} | {:error, :unavailable} | {:error, PortalError.t()})
        ) ::
          {:ok, Response.t()} | {:error, PortalError.t()}
  def run(deps, name, attributes, call) do
    %Observability{logger: logger, tracer: tracer} = deps.observability

    :otel_tracer.with_span(tracer, name, %{attributes: attributes}, fn span ->
      case call.() do
        {:ok, %Response{status: status}} when status in [401, 403] or status >= 500 ->
          Logger.error(logger, "upstream.refused", %{operation: name, status: status})
          unavailable(span, status)

        {:ok, %Response{} = response} ->
          relayed(span, response)

        {:error, :unavailable} ->
          Logger.warn(logger, "upstream.unavailable", %{operation: name})
          unavailable(span, nil)

        {:error, %PortalError{} = error} ->
          fail(span, error)
      end
    end)
  end

  defp relayed(span, %Response{status: status} = response) do
    Span.set_attribute(span, :"upstream.status_code", status)

    if status < 400,
      do: Span.set_status(span, OpenTelemetry.status(:ok)),
      else: Span.set_attribute(span, :"upstream.error_code", response.body["error"]["code"])

    {:ok, response}
  end

  @doc """
  Records a typed failure on `span` (its contract code as `error.type` and
  status — never an exception message) and returns `{:error, error}`.
  """
  @spec fail(:opentelemetry.span_ctx(), PortalError.t()) :: {:error, PortalError.t()}
  def fail(span, %PortalError{} = error) do
    Span.set_attribute(span, :"error.type", error.code)
    Span.set_status(span, OpenTelemetry.status(:error, error.code))
    {:error, error}
  end

  defp unavailable(span, status) do
    if status, do: Span.set_attribute(span, :"upstream.status_code", status)
    fail(span, PortalError.exception(:upstream_unavailable))
  end
end

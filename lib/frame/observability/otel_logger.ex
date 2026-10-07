defmodule Frame.Observability.OtelLogger do
  @moduledoc """
  OtelLogger — forwards log records to the OTel logs bridge.

  On the BEAM, the OpenTelemetry Logs *API* is OTP's `:logger`: the SDK side
  (`otel_log_handler` from `opentelemetry_experimental`) is a `:logger`
  handler that turns events into OTel log records. This module only emits
  `:logger` events tagged with an OTel instrumentation scope — it never
  touches the SDK.

  Trace correlation is automatic: the active span's `otel_trace_id` /
  `otel_span_id` travel in the process's logger metadata (re-derived from the
  active OTel context on every call), so every record emitted inside an
  active span carries that span's IDs, and records outside a span carry
  none. No manual threading required.

  Without an OTel log handler installed, records only reach whatever other
  `:logger` handlers the application configured (no OTel export).

  ## Example

      # Consumer sets up the SDK (Frame never does this):
      :logger.add_handler(:otel, :otel_log_handler, %{config: %{exporter: {MyExporter, []}}})

      logger = Frame.Observability.OtelLogger.new()
      Frame.Observability.Logger.info(logger, "cat.created", %{catId: "..."})
  """

  @behaviour Frame.Observability.Logger

  @enforce_keys [:scope]
  defstruct [:scope]

  @type t :: %__MODULE__{scope: :opentelemetry.instrumentation_scope()}

  @spec new(String.t()) :: t()
  def new(name \\ "frame") when is_binary(name) do
    %__MODULE__{scope: :opentelemetry.instrumentation_scope(name, "", "")}
  end

  @impl true
  def info(logger, message, attrs), do: emit(logger, :info, message, attrs)

  @impl true
  def warn(logger, message, attrs), do: emit(logger, :warning, message, attrs)

  @impl true
  def error(logger, message, attrs), do: emit(logger, :error, message, attrs)

  @impl true
  def debug(logger, message, attrs), do: emit(logger, :debug, message, attrs)

  @trace_metadata_keys [:otel_trace_id, :otel_span_id, :otel_trace_flags]

  defp emit(%__MODULE__{scope: scope}, level, message, attrs) do
    sync_trace_metadata()
    :logger.log(level, message, Map.put(attrs, :otel_scope, scope))
  end

  # The OTel API writes the active span's IDs into the process logger
  # metadata when a span becomes current, but does not remove them when the
  # span ends. Re-derive them from the active context so records carry the
  # current span's IDs — and none outside a span.
  defp sync_trace_metadata do
    span_metadata = :otel_span.hex_span_ctx(OpenTelemetry.Tracer.current_span_ctx())

    case :logger.get_process_metadata() do
      :undefined when span_metadata == %{} ->
        :ok

      :undefined ->
        :logger.set_process_metadata(span_metadata)

      metadata ->
        metadata
        |> Map.drop(@trace_metadata_keys)
        |> Map.merge(span_metadata)
        |> :logger.set_process_metadata()
    end
  end
end

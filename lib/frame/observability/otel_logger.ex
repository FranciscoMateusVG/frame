defmodule Frame.Observability.OtelLogger do
  @moduledoc """
  OtelLogger — forwards log records to the OTel logs bridge.

  On the BEAM, the OpenTelemetry Logs *API* is OTP's `:logger`: the SDK side
  (`otel_log_handler` from `opentelemetry_experimental`) is a `:logger`
  handler that turns events into OTel log records. This module only emits
  `:logger` events tagged with an OTel instrumentation scope — it never
  touches the SDK.

  Trace correlation is automatic: the OTel API keeps the active span's
  `otel_trace_id` / `otel_span_id` in the process's logger metadata, so every
  record emitted inside an active span carries that span's IDs. No manual
  threading required.

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

  defp emit(%__MODULE__{scope: scope}, level, message, attrs) do
    # The active span context already lives in the process logger metadata
    # (maintained by the OTel API), so correlation needs no explicit context.
    :logger.log(level, message, Map.put(attrs, :otel_scope, scope))
  end
end

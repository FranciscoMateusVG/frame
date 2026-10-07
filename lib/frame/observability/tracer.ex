defmodule Frame.Observability.Tracer do
  @moduledoc """
  Tracer types re-exported from `opentelemetry_api`, plus a `noop_tracer/0`
  convenience for contexts where tracing is not desired (e.g. simple examples).

  Production tracing requires an OTel SDK (the `opentelemetry` application)
  to be started by the consumer. Without one, all tracer operations are
  no-ops (safe by design).
  """

  @typedoc "An OpenTelemetry tracer (`{module, config}`)."
  @type t :: :opentelemetry.tracer()

  @typedoc "An OpenTelemetry span context."
  @type span :: :opentelemetry.span_ctx()

  @doc """
  Returns a no-op tracer. All span operations on it are silent no-ops —
  zero overhead — even if an SDK is running.
  """
  @spec noop_tracer() :: t()
  def noop_tracer, do: {:otel_tracer_noop, []}
end

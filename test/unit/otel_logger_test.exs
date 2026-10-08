defmodule Frame.Unit.OtelLoggerTest do
  @moduledoc """
  OtelLogger tests.

  Verifies that OtelLogger forwards log records through the OTel logs bridge
  and that records emitted inside an active span are automatically correlated
  with that span's trace context (the whole point of OtelLogger over the
  simpler ConsoleLogger — trace-aware structured logs without manual threading).

  Uses the real logs SDK (`otel_log_handler` from `opentelemetry_experimental`)
  with an in-memory log exporter that converts batches with the SDK's own
  OTLP record conversion. This is the only place Frame's tests touch the logs SDK.
  """
  use ExUnit.Case, async: true

  require OpenTelemetry.Tracer, as: Tracer

  alias Frame.Observability.Logger
  alias Frame.Observability.OtelLogger
  alias Frame.Test.Observability, as: TestObs

  defmodule InMemoryLogExporter do
    @moduledoc false
    # In-memory log exporter (the InMemoryLogRecordExporter equivalent): stores
    # every record the SDK handler batches, keyed by instrumentation scope.
    @behaviour :otel_exporter_logs

    @impl true
    def init(table), do: {:ok, table}

    @impl true
    def export({batch, _config}, _resource, table) do
      for {{:instrumentation_scope, scope_name, _vsn, _url}, events} <- batch,
          %{level: level, msg: msg, meta: meta} <- Enum.reverse(events) do
        record = %{scope_name: scope_name, severity: level, body: body(msg), meta: meta}
        :ets.insert(table, {System.unique_integer([:monotonic]), record})
      end

      :ok
    end

    @impl true
    def shutdown(_table), do: :ok

    defp body({:string, chardata}), do: IO.chardata_to_string(chardata)
    defp body(other), do: other
  end

  setup do
    # --- Tracer SDK wiring (for the trace-correlation test) ---
    test_obs = TestObs.create_test_observability()

    # --- Logs SDK wiring (once per suite) ---
    {:ok, _} = Application.ensure_all_started(:opentelemetry_experimental)
    table = :ets.new(:otel_log_records, [:ordered_set, :public])
    :ets.give_away(table, test_obs.owner, nil)
    handler = :"frame_otel_test_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(handler, :otel_log_handler, %{
        filters: [only_owner: {&__MODULE__.only_owner/2, self()}],
        exporter: {InMemoryLogExporter, table},
        scheduled_delay_ms: 5
      })

    on_exit(fn ->
      :logger.remove_handler(handler)
      TestObs.shutdown(test_obs)
    end)

    %{table: table, logger: OtelLogger.new("frame-test")}
  end

  @doc false
  def only_owner(%{meta: %{pid: pid}} = event, pid), do: event
  def only_owner(_event, _pid), do: :stop

  # The handler exports in batches; wait until the expected records arrive.
  defp finished_log_records(table, expected, deadline \\ 2_000) do
    records = table |> :ets.tab2list() |> Enum.sort() |> Enum.map(&elem(&1, 1))

    cond do
      length(records) >= expected -> Process.sleep(20) && finished_log_records!(table)
      deadline <= 0 -> records
      true -> Process.sleep(5) && finished_log_records(table, expected, deadline - 5)
    end
  end

  defp finished_log_records!(table),
    do: table |> :ets.tab2list() |> Enum.sort() |> Enum.map(&elem(&1, 1))

  test "info emits a log record with INFO severity", %{logger: logger, table: table} do
    Logger.info(logger, "cat.created", %{catId: "abc-123", nameLength: 7})

    assert [record] = finished_log_records(table, 1)
    assert record.severity == :info
    assert record.body == "cat.created"
    assert %{catId: "abc-123", nameLength: 7} = record.meta
  end

  test "warn emits a log record with WARN severity", %{logger: logger, table: table} do
    Logger.warn(logger, "cat.suspicious")

    assert [record] = finished_log_records(table, 1)
    assert record.severity == :warning
    assert record.body == "cat.suspicious"
  end

  test "error emits a log record with ERROR severity", %{logger: logger, table: table} do
    Logger.error(logger, "cat.lost")

    assert [record] = finished_log_records(table, 1)
    assert record.severity == :error
    assert record.body == "cat.lost"
  end

  test "debug emits a log record with DEBUG severity", %{logger: logger, table: table} do
    Logger.debug(logger, "cat.napping")

    assert [record] = finished_log_records(table, 1)
    assert record.severity == :debug
  end

  test "emits without user attrs when none provided", %{logger: logger, table: table} do
    Logger.info(logger, "no.attrs")

    assert [record] = finished_log_records(table, 1)
    # Only the bridge's own metadata (pid, time, scope, ...) — no user attributes.
    assert record.meta |> Map.drop([:pid, :gl, :time, :otel_scope]) == %{}
  end

  test "log records emitted inside an active span carry that span trace context",
       %{logger: logger, table: table} do
    span_ctx =
      Tracer.with_span "parent.op" do
        Logger.info(logger, "inside.span", %{phase: "mid"})
        Tracer.current_span_ctx()
      end

    assert [record] = finished_log_records(table, 1)
    assert record.meta.otel_trace_id == OpenTelemetry.Span.hex_trace_id(span_ctx)
    assert record.meta.otel_span_id == OpenTelemetry.Span.hex_span_id(span_ctx)
  end

  test "log records emitted outside any span have no span context",
       %{logger: logger, table: table} do
    # As in the reference (same thread, after the in-span test): a span that
    # has already ended must not leak its context into later records.
    Tracer.with_span("earlier.op", do: :ok)
    Logger.info(logger, "outside.span")

    assert [record] = finished_log_records(table, 1)
    refute Map.has_key?(record.meta, :otel_trace_id)
    refute Map.has_key?(record.meta, :otel_span_id)
  end

  test "respects the custom logger name passed to new/1", %{table: table} do
    Logger.info(OtelLogger.new("my-app"), "hello")

    assert [record] = finished_log_records(table, 1)
    assert record.scope_name == "my-app"
  end
end

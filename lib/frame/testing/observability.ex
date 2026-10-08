if Code.ensure_loaded?(:otel_simple_processor) do
  defmodule Frame.Testing.Observability do
    @moduledoc """
    Test helper for consumers — provides an Observability backed by an
    in-memory span exporter for asserting on emitted spans.

    Lives in its own module (the equivalent of the TypeScript `frame/testing`
    subpath) and is only compiled when the optional `opentelemetry` SDK
    dependency is present, so it stays out of production code.

    `create_test_observability/0` registers the SDK globally (starting the
    `opentelemetry` application with a simple span processor feeding the
    in-memory exporter), so adapter spans — which use the application tracer —
    are captured and nest under use-case spans through the SDK's
    process-local context propagation.

    This is the ONLY place Frame uses the OTel SDK. Production code only sees
    the API, which is no-op safe by default.

        test_obs = Frame.Testing.Observability.create_test_observability()
        on_exit(fn -> Frame.Testing.Observability.shutdown(test_obs) end)

        Frame.Testing.Observability.reset(test_obs)
        {:ok, _} = MyApp.my_use_case(%{observability: test_obs.observability, ...}, input)
        [%{name: "myUseCase"}] = Frame.Testing.Observability.get_spans(test_obs)

    One SDK is shared, but each handle owns a separate export table. Process-local
    OTel context routes adapter spans; the injected tracer carries the same scope
    into server processes. Handles may be used by concurrent tests.
    """

    require Record

    alias Frame.Observability.NoopLogger
    alias Frame.Observability.Observability

    Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

    Record.defrecordp(
      :event,
      Record.extract(:event, from_lib: "opentelemetry/include/otel_span.hrl")
    )

    Record.defrecordp(
      :status,
      Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
    )

    @table_key {__MODULE__, :table}

    @enforce_keys [:observability, :table, :owner]
    defstruct [:observability, :table, :owner]

    @type t :: %__MODULE__{observability: Observability.t(), table: :ets.tid(), owner: pid()}

    @typedoc "A finished span, flattened for assertions."
    @type finished_span :: %{
            name: String.t(),
            trace_id: non_neg_integer(),
            span_id: non_neg_integer(),
            parent_span_id: non_neg_integer() | :undefined,
            attributes: map(),
            status: %{code: :unset | :ok | :error, message: String.t()},
            events: [%{name: String.t(), attributes: map()}]
          }

    @doc "Registers the SDK with an in-memory exporter and returns the handle."
    @spec create_test_observability() :: t()
    def create_test_observability do
      {owner, table} = start_table_owner()
      register_sdk!()
      :otel_ctx.set_value(@table_key, table)

      observability = %Observability{
        logger: NoopLogger.new(),
        tracer: {__MODULE__.ScopedTracer, {:opentelemetry.get_tracer(:"frame-test"), table}}
      }

      %__MODULE__{observability: observability, table: table, owner: owner}
    end

    @doc "Returns all finished spans since the last reset, in end order."
    @spec get_spans(t()) :: [finished_span()]
    def get_spans(%__MODULE__{table: table}) do
      table |> :ets.tab2list() |> Enum.sort() |> Enum.map(fn {_seq, record} -> to_map(record) end)
    end

    @doc "Clears all finished spans. Call in `setup` for test isolation."
    @spec reset(t()) :: :ok
    def reset(%__MODULE__{table: table}) do
      :ets.delete_all_objects(table)
      :otel_ctx.set_value(@table_key, table)
      :ok
    end

    @doc "Stops collecting spans. Call in `on_exit`."
    @spec shutdown(t()) :: :ok
    def shutdown(%__MODULE__{owner: owner, table: table}) do
      if :otel_ctx.get_value(@table_key) == table, do: :otel_ctx.set_value(@table_key, nil)
      send(owner, :stop)
      :ok
    end

    # --- helpers ---

    @exporter {__MODULE__.Exporter, @table_key}

    # Starts the SDK with a simple (synchronous) span processor feeding the
    # in-memory exporter. The SDK reads its configuration once, at start, so
    # an SDK already started with a different exporter cannot be captured.
    defp register_sdk! do
      :global.trans({{__MODULE__, :sdk}, self()}, &start_sdk!/0)
    end

    defp start_sdk! do
      started? = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :opentelemetry))

      cond do
        not started? ->
          Application.delete_env(:opentelemetry, :span_processor)

          Application.put_env(:opentelemetry, :processors, [
            {__MODULE__.RoutingProcessor, %{}},
            {:otel_simple_processor, %{}}
          ])

          Application.put_env(:opentelemetry, :traces_exporter, @exporter)
          {:ok, _} = Application.ensure_all_started(:opentelemetry)

        Application.get_env(:opentelemetry, :traces_exporter) == @exporter ->
          :ok

        true ->
          raise "the :opentelemetry SDK is already running with another exporter; " <>
                  "call create_test_observability/0 before anything starts the SDK"
      end
    end

    # The table must outlive the calling (test) process, so a dedicated
    # process owns it until shutdown/1.
    defp start_table_owner do
      parent = self()

      owner =
        spawn(fn ->
          table = :ets.new(__MODULE__, [:ordered_set, :public])
          send(parent, {:table, self(), table})

          receive do
            :stop -> :ok
          end
        end)

      receive do
        {:table, ^owner, table} -> {owner, table}
      end
    end

    defp to_map(record) do
      status =
        case span(record, :status) do
          status(code: code, message: message) -> %{code: code, message: message}
          _ -> %{code: :unset, message: ""}
        end

      %{
        name: to_string(span(record, :name)),
        trace_id: span(record, :trace_id),
        span_id: span(record, :span_id),
        parent_span_id: span(record, :parent_span_id),
        attributes: :otel_attributes.map(span(record, :attributes)),
        status: status,
        events:
          record
          |> span(:events)
          |> :otel_events.list()
          |> Enum.map(fn e ->
            %{
              name: to_string(event(e, :name)),
              attributes: :otel_attributes.map(event(e, :attributes))
            }
          end)
      }
    end
  end

  defmodule Frame.Testing.Observability.Exporter do
    @moduledoc false
    # The in-memory span exporter (equivalent of InMemorySpanExporter): copies
    # every finished span into the table registered by the current handle.

    @behaviour :otel_exporter_traces
    require Record
    Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

    @impl true
    def init(table_key), do: {:ok, table_key}

    @impl true
    def export(spans_tid, _resource, _table_key) do
      :ets.foldl(fn record, _ -> route(record) end, :ok, spans_tid)
      :ok
    end

    defp route(record) do
      span_id = span(record, :span_id)

      case :ets.take(Frame.Testing.Observability.RoutingProcessor, span_id) do
        [{^span_id, table}] ->
          :ets.insert(table, {System.unique_integer([:monotonic]), record})

        [] ->
          :ok
      end
    rescue
      # The owning test has finished; never redirect its spans to another test.
      ArgumentError -> :ok
    end

    @impl true
    def shutdown(_table_key), do: :ok
  end

  defmodule Frame.Testing.Observability.RoutingProcessor do
    @moduledoc false
    @behaviour :otel_span_processor
    require Record
    Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))
    @key {Frame.Testing.Observability, :table}

    def start_link(_config) do
      Agent.start_link(fn -> :ets.new(__MODULE__, [:named_table, :public, :set]) end)
    end

    @impl true
    def on_start(ctx, record, _config) do
      case :otel_ctx.get_value(ctx, @key, nil) do
        nil -> :ok
        table -> :ets.insert(__MODULE__, {span(record, :span_id), table})
      end

      record
    end

    @impl true
    def on_end(_span, _config), do: true
    @impl true
    def force_flush(_config), do: :ok
  end

  defmodule Frame.Testing.Observability.ScopedTracer do
    @moduledoc false
    @behaviour :otel_tracer
    @key {Frame.Testing.Observability, :table}

    @impl true
    def start_span(ctx, {__MODULE__, {{module, _} = tracer, table}}, name, opts) do
      module.start_span(:otel_ctx.set_value(ctx, @key, table), tracer, name, opts)
    end

    @impl true
    def with_span(ctx, {__MODULE__, {{module, _} = tracer, table}}, name, opts, fun) do
      module.with_span(:otel_ctx.set_value(ctx, @key, table), tracer, name, opts, fun)
    end
  end
end

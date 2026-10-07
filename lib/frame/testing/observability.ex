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

    The exporter is global (one SDK per VM), so tests asserting on spans must
    not run concurrently with other span-emitting tests (`async: false`).
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
      :persistent_term.put(@table_key, table)

      register_sdk!()

      observability = %Observability{
        logger: NoopLogger.new(),
        tracer: :opentelemetry.get_tracer(:"frame-test")
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
      :ok
    end

    @doc "Stops collecting spans. Call in `on_exit`."
    @spec shutdown(t()) :: :ok
    def shutdown(%__MODULE__{owner: owner, table: table}) do
      if :persistent_term.get(@table_key, nil) == table, do: :persistent_term.erase(@table_key)
      send(owner, :stop)
      :ok
    end

    # --- helpers ---

    @exporter {__MODULE__.Exporter, @table_key}

    # Starts the SDK with a simple (synchronous) span processor feeding the
    # in-memory exporter. The SDK reads its configuration once, at start, so
    # an SDK already started with a different exporter cannot be captured.
    defp register_sdk! do
      started? = Enum.any?(Application.started_applications(), &(elem(&1, 0) == :opentelemetry))

      cond do
        not started? ->
          Application.put_env(:opentelemetry, :span_processor, :simple)
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

    @impl true
    def init(table_key), do: {:ok, table_key}

    @impl true
    def export(spans_tid, _resource, table_key) do
      case :persistent_term.get(table_key, nil) do
        nil ->
          :ok

        table ->
          :ets.foldl(
            fn record, _ -> :ets.insert(table, {System.unique_integer([:monotonic]), record}) end,
            :ok,
            spans_tid
          )

          :ok
      end
    rescue
      # The table was deleted by a concurrent shutdown/1.
      ArgumentError -> :ok
    end

    @impl true
    def shutdown(_table_key), do: :ok
  end
end

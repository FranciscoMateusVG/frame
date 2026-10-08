defmodule Frame.Adapters.SessionStore.Memory do
  @moduledoc """
  In-memory SessionStore on a public ETS table, owned by a small GenServer
  that also sweeps expired records every minute.

  Bounded: at most `:max_sessions` records (default 10,000). When full, the
  least recently used record is evicted before inserting — anonymous
  pre-sessions cannot exhaust memory. Lookups and writes go straight to ETS
  (no GenServer round trip on the request path).

  Instrumented with one `session.<operation>` span per call; spans carry
  the outcome only, never ids or tokens.
  """

  @behaviour Frame.Adapters.SessionStore

  use GenServer

  require OpenTelemetry.Tracer, as: Tracer

  alias Frame.Domain.Session

  @enforce_keys [:table, :policy, :clock, :max_sessions]
  defstruct [:table, :policy, :clock, :max_sessions]

  @type t :: %__MODULE__{
          table: atom(),
          policy: Session.policy(),
          clock: (-> DateTime.t()),
          max_sessions: pos_integer()
        }

  @sweep_ms 60_000

  @doc """
  The store handle for the given options, without starting anything.
  Options: `:table` (ETS table name — required when supervised),
  `:policy` (`Frame.Domain.Session.policy/0` shape), `:clock`,
  `:max_sessions`.
  """
  @spec store(keyword()) :: t()
  def store(opts) do
    %__MODULE__{
      table: Keyword.fetch!(opts, :table),
      policy: Keyword.get(opts, :policy, Session.default_policy()),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      max_sessions: Keyword.get(opts, :max_sessions, 10_000)
    }
  end

  @doc "Starts the table owner (supervision); use `store/1` with the same options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, store(opts))

  @doc "Starts a store with a private table, linked to the caller (tests, examples)."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    table = :"frame_sessions_#{System.unique_integer([:positive])}"
    store = store(Keyword.put(opts, :table, table))
    {:ok, _pid} = GenServer.start_link(__MODULE__, store)
    store
  end

  @impl Frame.Adapters.SessionStore
  def create(%__MODULE__{} = store, kind) do
    traced("session.create", kind, fn ->
      now = store.clock.()

      session = %Session{
        id: token(),
        csrf_token: token(),
        authenticated: kind == :authenticated,
        created_at: now,
        last_seen_at: now
      }

      make_room(store)
      :ets.insert(store.table, {session.id, session})
      session
    end)
  end

  @impl Frame.Adapters.SessionStore
  def fetch(%__MODULE__{} = store, id, kind) when is_binary(id) do
    traced("session.fetch", kind, fn -> lookup(store, id, kind == :authenticated) end)
  end

  def fetch(_store, _id, _kind), do: :error

  defp lookup(store, id, authenticated) do
    case :ets.lookup(store.table, id) do
      [{^id, %Session{authenticated: ^authenticated} = session}] ->
        keep_alive(store, session, store.clock.())

      _ ->
        :error
    end
  end

  # Expired records are deleted; live authenticated ones are touched.
  defp keep_alive(store, session, now) do
    if Session.expired?(session, store.policy, now) do
      :ets.delete(store.table, session.id)
      :error
    else
      touched = if session.authenticated, do: Session.touch(session, now), else: session
      :ets.insert(store.table, {session.id, touched})
      {:ok, touched}
    end
  end

  @impl Frame.Adapters.SessionStore
  def revoke(%__MODULE__{} = store, id) when is_binary(id) do
    traced("session.revoke", :any, fn ->
      :ets.delete(store.table, id)
      :ok
    end)
  end

  @impl Frame.Adapters.SessionStore
  def policy(%__MODULE__{policy: policy}), do: policy

  # --- GenServer (table owner + sweeper) ---

  @impl GenServer
  def init(%__MODULE__{} = store) do
    :ets.new(store.table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, store}
  end

  @impl GenServer
  def handle_info(:sweep, store) do
    sweep(store)
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, store}
  end

  @doc false
  @spec sweep(t()) :: non_neg_integer()
  def sweep(%__MODULE__{} = store) do
    now = store.clock.()

    store.table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, s} -> Session.expired?(s, store.policy, now) end)
    |> Enum.each(fn {id, _s} -> :ets.delete(store.table, id) end)
    |> then(fn _ -> :ets.info(store.table, :size) end)
  end

  defp make_room(store) do
    if :ets.info(store.table, :size) >= store.max_sessions do
      sweep(store)
      evict_lru(store)
    end
  end

  defp evict_lru(store) do
    if :ets.info(store.table, :size) >= store.max_sessions do
      {id, _} = :ets.foldl(&least_recent/2, nil, store.table)
      :ets.delete(store.table, id)
      evict_lru(store)
    end
  end

  defp least_recent({id, s}, nil), do: {id, s.last_seen_at}

  defp least_recent({id, s}, {_, oldest} = acc) do
    if DateTime.compare(s.last_seen_at, oldest) == :lt, do: {id, s.last_seen_at}, else: acc
  end

  # 256 bits, URL-safe, no padding.
  defp token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp traced(name, kind, fun) do
    Tracer.with_span name, %{attributes: %{"session.kind": Atom.to_string(kind)}} do
      result = fun.()
      found = result != :error
      OpenTelemetry.Span.set_attribute(Tracer.current_span_ctx(), :"session.found", found)
      result
    end
  end
end

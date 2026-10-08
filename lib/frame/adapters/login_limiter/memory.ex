defmodule Frame.Adapters.LoginLimiter.Memory do
  @moduledoc """
  In-memory LoginLimiter: an `Agent` holding a `Frame.Domain.LoginThrottle`
  (bounded per-IP map + instance counter). Single replica by design; a
  shared limiter for several replicas would be another decision (spec §5).

  Instrumented with one `login_limiter.<operation>` span per call; the
  client address never appears in spans.
  """

  @behaviour Frame.Adapters.LoginLimiter

  require OpenTelemetry.Tracer, as: Tracer

  alias Frame.Domain.LoginThrottle

  @enforce_keys [:agent, :now_ms]
  defstruct [:agent, :now_ms]

  @type t :: %__MODULE__{agent: pid() | atom(), now_ms: (-> integer())}

  @doc """
  Starts the limiter linked to the caller. Options: `:limits` (see
  `LoginThrottle.new/1`), `:now_ms` (millisecond clock, default monotonic),
  `:name` (registers the Agent; the handle then refers to the name).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    {:ok, pid} = start_link(opts)
    handle(Keyword.put_new(opts, :name, pid))
  end

  @doc "The handle for a limiter started with `start_link/1` under `:name`."
  @spec handle(keyword()) :: t()
  def handle(opts) do
    %__MODULE__{
      agent: Keyword.fetch!(opts, :name),
      now_ms: Keyword.get(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    }
  end

  @doc "Starts the state holder (supervision)."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    throttle = LoginThrottle.new(Keyword.get(opts, :limits, %{}))

    case Keyword.get(opts, :name) do
      name when is_atom(name) and name != nil -> Agent.start_link(fn -> throttle end, name: name)
      _ -> Agent.start_link(fn -> throttle end)
    end
  end

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def check(%__MODULE__{} = limiter, ip) do
    Tracer.with_span "login_limiter.check" do
      now = limiter.now_ms.()

      result =
        Agent.get_and_update(limiter.agent, fn t ->
          t = LoginThrottle.prune(t, now)
          {LoginThrottle.check(t, ip, now), t}
        end)

      OpenTelemetry.Span.set_attribute(
        Tracer.current_span_ctx(),
        :"login.blocked",
        result != :ok
      )

      result
    end
  end

  @impl true
  def record_failure(%__MODULE__{} = limiter, ip) do
    Tracer.with_span "login_limiter.recordFailure" do
      now = limiter.now_ms.()
      Agent.update(limiter.agent, &LoginThrottle.record_failure(&1, ip, now))
    end
  end

  @impl true
  def record_success(%__MODULE__{} = limiter, ip) do
    Tracer.with_span "login_limiter.recordSuccess" do
      Agent.update(limiter.agent, &LoginThrottle.record_success(&1, ip))
    end
  end
end

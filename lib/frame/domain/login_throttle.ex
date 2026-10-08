defmodule Frame.Domain.LoginThrottle do
  @moduledoc """
  Login attempt limits (spec §5): at most 5 invalid passwords per client IP
  and 100 per instance in any 15-minute window. Once a limit is reached,
  every attempt (right or wrong password) is refused until the window
  frees a slot.

  Memory is bounded: at most `max_tracked_ips` addresses are tracked; when
  full, the address with the oldest last failure is forgotten (the global
  counter still applies, so eviction never lifts the instance limit).

  Pure state transitions over monotonic-ish millisecond timestamps; the
  `LoginLimiter` adapter owns the state.
  """

  @window_ms 15 * 60 * 1000

  defstruct per_ip: %{}, global: [], limits: nil

  @type ip :: String.t()
  @type limits :: %{per_ip: pos_integer(), global: pos_integer(), max_tracked_ips: pos_integer()}
  @type t :: %__MODULE__{per_ip: %{ip() => [integer()]}, global: [integer()], limits: limits()}

  @default_limits %{per_ip: 5, global: 100, max_tracked_ips: 10_000}

  @doc "A fresh throttle with the spec limits (overridable for tests)."
  @spec new(map()) :: t()
  def new(limits \\ %{}), do: %__MODULE__{limits: Map.merge(@default_limits, limits)}

  @doc "The window length in milliseconds."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc """
  May `ip` attempt a login at `now_ms`? Returns `{:blocked, retry_after_s}`
  (whole seconds, at least 1) when either limit is exhausted.
  """
  @spec check(t(), ip(), integer()) :: :ok | {:blocked, pos_integer()}
  def check(%__MODULE__{} = t, ip, now_ms) do
    ip_failures = recent(Map.get(t.per_ip, ip, []), now_ms)
    global = recent(t.global, now_ms)

    cond do
      length(ip_failures) >= t.limits.per_ip -> {:blocked, retry_after(ip_failures, now_ms)}
      length(global) >= t.limits.global -> {:blocked, retry_after(global, now_ms)}
      true -> :ok
    end
  end

  @doc "Records an invalid password from `ip`."
  @spec record_failure(t(), ip(), integer()) :: t()
  def record_failure(%__MODULE__{} = t, ip, now_ms) do
    per_ip =
      t.per_ip
      |> Map.update(ip, [now_ms], &[now_ms | recent(&1, now_ms)])
      |> bound(t.limits.max_tracked_ips, now_ms)

    %{t | per_ip: per_ip, global: [now_ms | recent(t.global, now_ms)]}
  end

  @doc "Forgets the failures of `ip` after a successful login."
  @spec record_success(t(), ip()) :: t()
  def record_success(%__MODULE__{} = t, ip), do: %{t | per_ip: Map.delete(t.per_ip, ip)}

  @doc "Drops everything outside the window (periodic cleanup)."
  @spec prune(t(), integer()) :: t()
  def prune(%__MODULE__{} = t, now_ms) do
    per_ip =
      for {ip, stamps} <- t.per_ip, kept = recent(stamps, now_ms), kept != [], into: %{} do
        {ip, kept}
      end

    %{t | per_ip: per_ip, global: recent(t.global, now_ms)}
  end

  # Timestamps are kept newest first.
  defp recent(stamps, now_ms), do: Enum.filter(stamps, &(&1 > now_ms - @window_ms))

  defp retry_after(stamps, now_ms) do
    oldest = Enum.min(stamps)
    max(1, ceil((oldest + @window_ms - now_ms) / 1000))
  end

  defp bound(per_ip, max, _now_ms) when map_size(per_ip) <= max, do: per_ip

  defp bound(per_ip, max, now_ms) do
    {evict, _} =
      Enum.min_by(per_ip, fn {_ip, stamps} -> List.first(recent(stamps, now_ms), 0) end)

    bound(Map.delete(per_ip, evict), max, now_ms)
  end
end

defmodule Frame.Adapters.LoginLimiter do
  @moduledoc """
  LoginLimiter — the port holding login-attempt state (spec §5: 5 invalid
  attempts / 15 min per IP, 100 / 15 min per instance). The policy itself
  is the pure `Frame.Domain.LoginThrottle`; implementations only own state.

  The only implementation is `Frame.Adapters.LoginLimiter.Memory`.
  """

  @typedoc "Any struct whose module implements this behaviour."
  @type t :: struct()

  @doc "May this client attempt a login now?"
  @callback check(t(), String.t()) :: :ok | {:blocked, pos_integer()}

  @doc "Records an invalid password."
  @callback record_failure(t(), String.t()) :: :ok

  @doc "Records a successful login (clears that client's failures)."
  @callback record_success(t(), String.t()) :: :ok

  @spec check(t(), String.t()) :: :ok | {:blocked, pos_integer()}
  def check(%impl{} = limiter, ip), do: impl.check(limiter, ip)

  @spec record_failure(t(), String.t()) :: :ok
  def record_failure(%impl{} = limiter, ip), do: impl.record_failure(limiter, ip)

  @spec record_success(t(), String.t()) :: :ok
  def record_success(%impl{} = limiter, ip), do: impl.record_success(limiter, ip)
end

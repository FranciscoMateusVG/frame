defmodule Frame.Domain.Session do
  @moduledoc """
  Portal sessions (spec §5): server-side records behind an opaque cookie.

    * A **pre-session** exists before login only to bind the login CSRF
      token; it never grants access.
    * An **authenticated** session lasts at most 8 h from login (absolute)
      and 30 min without use (idle). Login always creates a brand-new
      session (rotation) — a pre-session is never promoted.

  Pure data and expiry rules; storage and randomness live in the
  `SessionStore` adapter.
  """

  @enforce_keys [:id, :csrf_token, :authenticated, :created_at, :last_seen_at]
  defstruct [:id, :csrf_token, :authenticated, :created_at, :last_seen_at]

  @type t :: %__MODULE__{
          id: String.t(),
          csrf_token: String.t(),
          authenticated: boolean(),
          created_at: DateTime.t(),
          last_seen_at: DateTime.t()
        }

  @typedoc "Lifetimes in seconds."
  @type policy :: %{
          idle_seconds: pos_integer(),
          absolute_seconds: pos_integer(),
          pre_session_seconds: pos_integer()
        }

  @default_policy %{idle_seconds: 30 * 60, absolute_seconds: 8 * 3600, pre_session_seconds: 3600}

  @doc "Spec defaults: 30 min idle, 8 h absolute; pre-sessions live 1 h."
  @spec default_policy() :: policy()
  def default_policy, do: @default_policy

  @doc """
  Builds a policy from optional overrides, which may only *shorten* the
  defaults (isolated test configurations); anything else is ignored.
  """
  @spec policy(keyword()) :: policy()
  def policy(overrides) do
    Enum.reduce(overrides, @default_policy, fn {key, value}, acc ->
      default = Map.fetch!(@default_policy, key)
      if is_integer(value) and value in 1..default, do: Map.put(acc, key, value), else: acc
    end)
  end

  @doc "When this session stops being valid, absent further use."
  @spec expires_at(t(), policy()) :: DateTime.t()
  def expires_at(%__MODULE__{authenticated: false} = s, policy),
    do: DateTime.add(s.created_at, policy.pre_session_seconds, :second)

  def expires_at(%__MODULE__{authenticated: true} = s, policy) do
    absolute = DateTime.add(s.created_at, policy.absolute_seconds, :second)
    idle = DateTime.add(s.last_seen_at, policy.idle_seconds, :second)
    if DateTime.compare(idle, absolute) == :lt, do: idle, else: absolute
  end

  @doc "True once `now` reaches `expires_at/2`."
  @spec expired?(t(), policy(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{} = session, policy, %DateTime{} = now),
    do: DateTime.compare(now, expires_at(session, policy)) != :lt

  @doc "Records use at `now` (extends the idle window, never the absolute one)."
  @spec touch(t(), DateTime.t()) :: t()
  def touch(%__MODULE__{} = session, %DateTime{} = now), do: %{session | last_seen_at: now}
end

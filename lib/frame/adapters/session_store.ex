defmodule Frame.Adapters.SessionStore do
  @moduledoc """
  SessionStore — the port for the portal's server-side session registry
  (spec §5). Sessions are opaque random ids (≥ 256 bits) mapped to
  `Frame.Domain.Session` records; deleting the record revokes the session
  immediately. A restart loses every session by design (single replica, no
  Redis/DB for the portal).

  The only implementation is `Frame.Adapters.SessionStore.Memory` (ETS).
  """

  alias Frame.Domain.Session

  @typedoc "Any struct whose module implements this behaviour."
  @type t :: struct()

  @type kind :: :pre | :authenticated

  @doc "Creates a new session of the given kind with fresh id and CSRF token."
  @callback create(t(), kind()) :: Session.t()

  @doc """
  Looks up a live session of the given kind. Expired records are deleted
  and reported as `:error`; authenticated sessions are touched (idle window).
  """
  @callback fetch(t(), String.t(), kind()) :: {:ok, Session.t()} | :error

  @doc "Deletes a session (logout, login rotation). Unknown ids are a no-op."
  @callback revoke(t(), String.t()) :: :ok

  @doc "The lifetimes in force."
  @callback policy(t()) :: Session.policy()

  @spec create(t(), kind()) :: Session.t()
  def create(%impl{} = store, kind), do: impl.create(store, kind)

  @spec fetch(t(), String.t(), kind()) :: {:ok, Session.t()} | :error
  def fetch(%impl{} = store, id, kind), do: impl.fetch(store, id, kind)

  @spec revoke(t(), String.t()) :: :ok
  def revoke(%impl{} = store, id), do: impl.revoke(store, id)

  @spec policy(t()) :: Session.policy()
  def policy(%impl{} = store), do: impl.policy(store)
end

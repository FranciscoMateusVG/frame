defmodule Frame.Web.SessionCookieStore do
  @moduledoc """
  A read-only `Plug.Session.Store` over the server-side session registry
  (`Frame.Adapters.SessionStore`), keyed by the `__Host-print_session`
  cookie. It gives Phoenix and LiveView their usual session map — on HTTP
  requests (`fetch_session`) and on every LiveView socket connect
  (`connect_info: [session: ...]`) — without making the session
  self-contained: the cookie stays an opaque id, revocable server side.

  The map holds:

    * `"portal_session_id"` — the server session id (stays server side:
      LiveView signs into the page only the `live_session` extras, never the
      plug session);
    * `"_csrf_token"` — the Plug CSRF *state* derived from the session's
      CSRF token, so Phoenix can verify the masked token a page presents
      when its socket connects;
    * `"live_socket_id"` — `portal_session:<sha256(id)>`, the topic used to
      disconnect every live page of a session at logout.

  Cookies are written by `Frame.Web.Security` (login rotation, logout), not
  by Plug.Session: `put/4` and `delete/3` never change anything.
  """

  @behaviour Plug.Session.Store

  alias Frame.Adapters.SessionStore
  alias Frame.Domain.Session
  alias Frame.Web.Deps
  alias Frame.Web.Security

  @doc "Plug.Session / socket connect_info options."
  @spec options() :: keyword()
  def options do
    [store: __MODULE__, key: Security.session_cookie(), secure: true, http_only: true]
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def get(conn, cookie, _opts) do
    deps = Deps.fetch(conn)

    case SessionStore.fetch(deps.session_store, cookie, :authenticated) do
      {:ok, session} -> {session.id, session_map(session)}
      :error -> {nil, %{}}
    end
  end

  @impl true
  def put(_conn, sid, _data, _opts), do: sid

  @impl true
  def delete(_conn, _sid, _opts), do: :ok

  @doc "The session map of an authenticated session."
  @spec session_map(Session.t()) :: map()
  def session_map(%Session{} = session) do
    %{
      "portal_session_id" => session.id,
      "_csrf_token" => csrf_state(session),
      "live_socket_id" => Security.live_socket_id(session.id)
    }
  end

  @doc "The Plug CSRF state (24 url-safe base64 chars) bound to a session."
  @spec csrf_state(Session.t()) :: String.t()
  def csrf_state(%Session{csrf_token: token}) do
    :hmac
    |> :crypto.mac(:sha256, "frame live csrf", token)
    |> binary_part(0, 18)
    |> Base.url_encode64()
  end
end

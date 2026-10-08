defmodule Frame.Unit.WebSessionTest do
  @moduledoc """
  The session plumbing of the Phoenix edge: the read-only Plug.Session
  store over the server registry (what a LiveView socket connect reads),
  the CSRF state it hands Phoenix, and the LiveView mount guard.
  """
  use Frame.Test.PortalCase, async: true

  alias Frame.Adapters.SessionStore
  alias Frame.Web.Security
  alias Frame.Web.SessionCookieStore

  defmodule GuardedLive do
    @moduledoc false
    use Phoenix.LiveView

    on_mount Frame.Web.LiveAuth

    def render(assigns), do: ~H"<p>dentro</p>"
  end

  setup do
    %{portal: Portal.start()}
  end

  defp conn_with(p), do: Phoenix.ConnTest.build_conn() |> Plug.Conn.put_private(:frame_deps, p.deps)

  test "get/3 maps a live authenticated session, and nothing else", %{portal: p} do
    session = SessionStore.create(p.deps.session_store, :authenticated)
    pre = SessionStore.create(p.deps.session_store, :pre)

    assert {id, map} = SessionCookieStore.get(conn_with(p), session.id, [])
    assert id == session.id
    assert map["portal_session_id"] == session.id
    assert map["live_socket_id"] == Security.live_socket_id(session.id)
    assert byte_size(map["_csrf_token"]) == 24

    # A pre-session, an unknown id and a revoked session are all no session.
    assert SessionCookieStore.get(conn_with(p), pre.id, []) == {nil, %{}}
    assert SessionCookieStore.get(conn_with(p), "desconhecido", []) == {nil, %{}}
    :ok = SessionStore.revoke(p.deps.session_store, session.id)
    assert SessionCookieStore.get(conn_with(p), session.id, []) == {nil, %{}}

    # Cookies are written by Security, never by Plug.Session.
    assert SessionCookieStore.put(conn_with(p), "sid", %{"x" => 1}, []) == "sid"
    assert SessionCookieStore.delete(conn_with(p), "sid", []) == :ok
    assert SessionCookieStore.init(key: "k") == [key: "k"]
  end

  test "the page's masked token verifies against the session's CSRF state only", %{portal: p} do
    session = SessionStore.create(p.deps.session_store, :authenticated)
    other = SessionStore.create(p.deps.session_store, :authenticated)
    state = SessionCookieStore.csrf_state(session)

    Process.delete(:plug_masked_csrf_token)
    Plug.CSRFProtection.load_state("secret", state)
    masked = Plug.CSRFProtection.get_csrf_token()

    assert Plug.CSRFProtection.valid_state_and_csrf_token?(state, masked)

    refute Plug.CSRFProtection.valid_state_and_csrf_token?(
             SessionCookieStore.csrf_state(other),
             masked
           )

    # The state is derived, never the raw token itself.
    refute state == session.csrf_token
  end

  # (The signed-in mount is covered through the router in PortalLiveTest.)
  test "a LiveView mount without a live session goes to /login", %{portal: p} do
    for session <- [%{}, %{"portal_session_id" => "revogada"}] do
      assert {:error, {:redirect, %{to: "/login"}}} =
               live_isolated(Portal.conn(p), GuardedLive, session: session)
    end
  end
end

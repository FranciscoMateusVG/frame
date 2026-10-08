defmodule Frame.Web.BrowserSession do
  @moduledoc """
  Browser pipeline plugs:

    * `fetch/2` — after `fetch_session`: assigns the live authenticated
      session (`:portal_session`, or `nil`) and loads its CSRF state, so
      `Plug.CSRFProtection.get_csrf_token/0` hands the page the masked token
      its LiveView socket must present;
    * `require_session/2` — HTML pages without a session redirect to `/login`
      (never to an external `returnTo`).
  """

  import Plug.Conn

  alias Frame.Adapters.SessionStore
  alias Frame.Web.Deps
  alias Frame.Web.SessionCookieStore

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, :fetch), do: fetch(conn, [])
  def call(conn, :require), do: require_session(conn, [])

  @doc "Assigns `:portal_session` and loads the page's CSRF state."
  @spec fetch(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def fetch(conn, _opts) do
    deps = Deps.fetch(conn)

    session =
      case get_session(conn, "portal_session_id") do
        nil ->
          nil

        id ->
          case SessionStore.fetch(deps.session_store, id, :authenticated) do
            {:ok, session} -> session
            :error -> nil
          end
      end

    # Bandit reuses a process for keep-alive requests: never let a masked
    # token of an earlier request survive into this one.
    Process.delete(:plug_masked_csrf_token)
    state = if session, do: SessionCookieStore.csrf_state(session)
    Plug.CSRFProtection.load_state(conn.secret_key_base, state)

    assign(conn, :portal_session, session)
  end

  @doc "Redirects to `/login` when there is no live session."
  @spec require_session(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_session(%Plug.Conn{assigns: %{portal_session: %{}}} = conn, _opts), do: conn

  def require_session(conn, _opts) do
    conn |> put_resp_header("location", "/login") |> send_resp(302, "") |> halt()
  end
end

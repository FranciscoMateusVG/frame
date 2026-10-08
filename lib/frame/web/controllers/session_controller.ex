defmodule Frame.Web.SessionController do
  @moduledoc """
  `GET|POST|DELETE /api/session` (spec §4.5): the pre-session and its CSRF
  token, login (exact Origin + pre-session CSRF; rotation to a brand-new
  session cookie) and logout (revokes the session and disconnects its live
  pages; a repeat without a session is still 204).
  """

  use Frame.Web, :controller

  alias Frame.Adapters.SessionStore
  alias Frame.Domain.Requests
  alias Frame.Domain.Session
  alias Frame.UseCases
  alias Frame.Web.ApiRequest
  alias Frame.Web.Deps
  alias Frame.Web.Reply
  alias Frame.Web.Security

  @doc false
  def show(conn, _params) do
    deps = Deps.fetch(conn)

    input = %{
      session_id: Security.cookie(conn, Security.session_cookie()),
      pre_session_id: Security.cookie(conn, Security.pre_session_cookie())
    }

    {:ok, result} = UseCases.EstablishSession.establish_session(deps, input)

    case result do
      {:authenticated, session} ->
        Reply.json(conn, 200, session_body(session, deps))

      {:anonymous, pre, status} ->
        conn =
          if status == :created,
            do: Security.put_cookie(conn, Security.pre_session_cookie(), pre.id),
            else: conn

        Reply.json(conn, 200, %{authenticated: false, csrfToken: pre.csrf_token, expiresAt: nil})
    end
  end

  @doc false
  def create(conn, _params) do
    deps = Deps.fetch(conn)
    pre_id = Security.cookie(conn, Security.pre_session_cookie())
    session_id = Security.cookie(conn, Security.session_cookie())

    with :ok <- ApiRequest.origin(conn, deps),
         {:ok, pre} <- pre_session(deps, pre_id),
         :ok <- ApiRequest.csrf(conn, pre),
         {:ok, conn, body} <- ApiRequest.json_body(conn),
         {:ok, password} <- ApiRequest.parse(Requests.login(body)) do
      input = %{
        password: password,
        client_ip: Security.client_ip(conn, deps.trusted_proxies),
        revoke: Enum.reject([pre_id, session_id], &is_nil/1)
      }

      case UseCases.LogIn.log_in(deps, input) do
        {:ok, session} -> signed_in(conn, deps, session, session_id)
        {:error, error} -> Reply.error(conn, error)
      end
    else
      {:error, conn, reason} -> Reply.error(conn, reason)
      {:error, reason} -> Reply.error(conn, reason)
    end
  end

  # Rotation: the new cookie replaces the old one, whose live pages drop.
  defp signed_in(conn, deps, session, old_id) do
    if old_id, do: Security.disconnect_live(conn, old_id)

    conn
    |> Security.put_cookie(Security.session_cookie(), session.id)
    |> Security.drop_cookie(Security.pre_session_cookie())
    |> Reply.json(200, session_body(session, deps))
  end

  @doc false
  def delete(conn, _params) do
    deps = Deps.fetch(conn)

    with :ok <- ApiRequest.origin(conn, deps),
         {:ok, session} <- current(conn, deps),
         :ok <- ApiRequest.csrf(conn, session) do
      :ok = UseCases.LogOut.log_out(deps, session.id)
      Security.disconnect_live(conn, session.id)
      logged_out(conn)
    else
      :no_session -> logged_out(conn)
      {:error, reason} -> Reply.error(conn, reason)
    end
  end

  defp current(conn, deps) do
    case Security.current_session(conn, deps.session_store) do
      {:ok, session} -> {:ok, session}
      :error -> :no_session
    end
  end

  defp logged_out(conn) do
    conn |> Security.drop_cookie(Security.session_cookie()) |> send_resp(204, "")
  end

  defp session_body(%Session{} = session, deps) do
    expires = Session.expires_at(session, SessionStore.policy(deps.session_store))

    %{
      authenticated: true,
      csrfToken: session.csrf_token,
      expiresAt: expires |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp pre_session(_deps, nil), do: {:error, :csrf_failed}

  defp pre_session(deps, id) do
    case SessionStore.fetch(deps.session_store, id, :pre) do
      {:ok, pre} -> {:ok, pre}
      :error -> {:error, :csrf_failed}
    end
  end
end

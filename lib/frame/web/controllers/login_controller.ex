defmodule Frame.Web.LoginController do
  @moduledoc """
  The browser's sign-in and sign-out (spec §5, §7.3/§7.12). They set and
  drop the host-only session cookies, so they are plain form posts:

    * `GET /login` — the form, bound to a pre-session (its CSRF token);
    * `POST /login` — exact Origin + pre-session CSRF; success rotates to a
      brand-new session cookie and goes to `/` (the current batch); a wrong password gets
      the same answer every time (401), the limiter 429 + `Retry-After`;
    * `POST /logout` — exact Origin + session CSRF; revokes the session and
      disconnects its live pages at once.
  """

  use Frame.Web, :controller

  alias Frame.Adapters.SessionStore
  alias Frame.Errors.PortalError
  alias Frame.UseCases
  alias Frame.Web.Deps
  alias Frame.Web.PageHTML
  alias Frame.Web.Security

  @form_limit 16_384

  @doc false
  def new(%Plug.Conn{assigns: %{portal_session: %{}}} = conn, _params),
    do: see_other(conn, "/")

  def new(conn, _params) do
    deps = Deps.fetch(conn)
    input = %{session_id: nil, pre_session_id: Security.cookie(conn, Security.pre_session_cookie())}
    {:ok, {:anonymous, pre, status}} = UseCases.EstablishSession.establish_session(deps, input)

    conn =
      if status == :created,
        do: Security.put_cookie(conn, Security.pre_session_cookie(), pre.id),
        else: conn

    PageHTML.login(conn, 200, pre.csrf_token, nil)
  end

  @doc false
  def create(conn, _params) do
    deps = Deps.fetch(conn)
    pre_id = Security.cookie(conn, Security.pre_session_cookie())
    old_id = Security.cookie(conn, Security.session_cookie())

    with true <- Security.same_origin?(conn, deps.portal_origin),
         {:ok, conn, form} <- form(conn),
         {:ok, pre} <- fetch_pre(deps, pre_id),
         true <- Security.csrf_valid?(form["_csrf"], pre) do
      input = %{
        password: form["password"] || "",
        client_ip: Security.client_ip(conn, deps.trusted_proxies),
        revoke: Enum.reject([pre_id, old_id], &is_nil/1)
      }

      case UseCases.LogIn.log_in(deps, input) do
        {:ok, session} -> signed_in(conn, session, old_id)
        {:error, %PortalError{} = error} -> login_failed(conn, pre, error)
      end
    else
      _ -> PageHTML.forbidden(conn)
    end
  end

  # Rotation: the new cookie replaces the old one, whose live pages drop.
  defp signed_in(conn, session, old_id) do
    if old_id, do: Security.disconnect_live(conn, old_id)

    conn
    |> Security.put_cookie(Security.session_cookie(), session.id)
    |> Security.drop_cookie(Security.pre_session_cookie())
    |> see_other("/")
  end

  # The same answer for every wrong password; the limiter adds Retry-After.
  defp login_failed(conn, pre, error) do
    conn =
      if error.retry_after,
        do: put_resp_header(conn, "retry-after", "#{error.retry_after}"),
        else: conn

    PageHTML.login(conn, error.status, pre.csrf_token, error.reason)
  end

  @doc false
  def delete(conn, _params) do
    deps = Deps.fetch(conn)

    with true <- Security.same_origin?(conn, deps.portal_origin),
         {:ok, conn, form} <- form(conn) do
      log_out(conn, deps, conn.assigns.portal_session, form["_csrf"])
    else
      _ -> PageHTML.forbidden(conn)
    end
  end

  # Without a session there is nothing to revoke; with one, its CSRF token.
  defp log_out(conn, _deps, nil, _csrf), do: logged_out(conn)

  defp log_out(conn, deps, session, csrf) do
    if Security.csrf_valid?(csrf, session) do
      :ok = UseCases.LogOut.log_out(deps, session.id)
      Security.disconnect_live(conn, session.id)
      logged_out(conn)
    else
      PageHTML.forbidden(conn)
    end
  end

  defp logged_out(conn),
    do: conn |> Security.drop_cookie(Security.session_cookie()) |> see_other("/login")

  defp form(conn) do
    with ["application/x-www-form-urlencoded" <> _] <- get_req_header(conn, "content-type"),
         {:ok, raw, conn} <- read_body(conn, length: @form_limit),
         true <- String.valid?(raw) do
      {:ok, conn, URI.decode_query(raw)}
    else
      _ -> :error
    end
  rescue
    _ in [ArgumentError, Plug.BadRequestError] -> :error
  end

  defp fetch_pre(_deps, nil), do: :error
  defp fetch_pre(deps, id), do: SessionStore.fetch(deps.session_store, id, :pre)

  # 302 for GET, 303 after a POST (the browser follows with GET).
  defp see_other(conn, to) do
    status = if conn.method == "GET", do: 302, else: 303
    conn |> put_resp_header("location", to) |> send_resp(status, "")
  end
end

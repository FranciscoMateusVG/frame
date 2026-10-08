defmodule Frame.Http.Api do
  @moduledoc """
  The portal's JSON API (spec §4.5) — common to the TS/Rust/Elixir portals:

    * `GET|POST|DELETE /api/session` — pre-session/CSRF, login, logout;
    * `/api/print/v1/...` — the ten service routes of §4.3 with the session
      cookie instead of the bearer token. Commands require the exact Origin
      and `X-CSRF-Token`; `If-Match` and `Idempotency-Key` are relayed for
      the upstream to enforce.

  The browser's `Authorization` and cookies are never forwarded; the
  upstream path is rebuilt from validated ids only (no proxying of
  arbitrary paths or hosts).
  """

  import Plug.Conn

  alias Frame.Adapters.SessionStore
  alias Frame.Domain.Competence
  alias Frame.Domain.Document
  alias Frame.Domain.Requests
  alias Frame.Domain.Session
  alias Frame.Http.Multipart
  alias Frame.Http.Reply
  alias Frame.Http.Security
  alias Frame.UseCases

  @json_limit 16_384

  @doc "Dispatches `/api/...` (path segments after `api`)."
  @spec call(Plug.Conn.t(), map(), [String.t()]) :: Plug.Conn.t()
  def call(conn, deps, ["session"]), do: session(conn, deps, conn.method)
  def call(conn, deps, ["print", "v1" | rest]), do: print(conn, deps, rest)
  def call(conn, _deps, _path), do: Reply.error(conn, :not_found)

  # --- /api/session ---

  defp session(conn, deps, "GET") do
    input = %{
      session_id: Security.cookie(conn, Security.session_cookie()),
      pre_session_id: Security.cookie(conn, Security.pre_session_cookie())
    }

    {:ok, result} = UseCases.EstablishSession.establish_session(deps, input)

    case result do
      {:authenticated, session} ->
        Reply.json(conn, 200, session_body(session, deps))

      {:anonymous, pre, status} ->
        conn = if status == :created, do: put_pre_session(conn, pre), else: conn
        Reply.json(conn, 200, %{authenticated: false, csrfToken: pre.csrf_token, expiresAt: nil})
    end
  end

  defp session(conn, deps, "POST") do
    pre_id = Security.cookie(conn, Security.pre_session_cookie())
    session_id = Security.cookie(conn, Security.session_cookie())

    with :ok <- origin(conn, deps),
         {:ok, pre} <- pre_session(deps, pre_id),
         :ok <- csrf(header(conn, "x-csrf-token"), pre),
         {:ok, conn, body} <- json_body(conn),
         {:ok, password} <- parse(Requests.login(body)) do
      input = %{
        password: password,
        client_ip: Security.client_ip(conn, deps.trusted_proxies),
        revoke: Enum.reject([pre_id, session_id], &is_nil/1)
      }

      case UseCases.LogIn.log_in(deps, input) do
        {:ok, session} ->
          conn
          |> Security.put_cookie(Security.session_cookie(), session.id)
          |> Security.drop_cookie(Security.pre_session_cookie())
          |> Reply.json(200, session_body(session, deps))

        {:error, error} ->
          Reply.error(conn, error)
      end
    else
      {:error, conn, reason} -> Reply.error(conn, reason)
      {:error, reason} -> Reply.error(conn, reason)
    end
  end

  defp session(conn, deps, "DELETE") do
    case origin(conn, deps) do
      :ok -> log_out(conn, deps)
      {:error, reason} -> Reply.error(conn, reason)
    end
  end

  defp session(conn, _deps, _method), do: method_not_allowed(conn, "GET, POST, DELETE")

  defp log_out(conn, deps) do
    case Security.current_session(conn, deps.session_store) do
      {:ok, session} -> log_out_session(conn, deps, session)
      :error -> logged_out(conn)
    end
  end

  defp log_out_session(conn, deps, session) do
    if Security.csrf_valid?(header(conn, "x-csrf-token"), session) do
      :ok = UseCases.LogOut.log_out(deps, session.id)
      logged_out(conn)
    else
      Reply.error(conn, :csrf_failed)
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

  defp put_pre_session(conn, pre),
    do: Security.put_cookie(conn, Security.pre_session_cookie(), pre.id)

  # --- /api/print/v1 ---

  @routes [
    {["orders"], ["GET"]},
    {["orders", :id], ["GET"]},
    {["orders", :id, "files", :id], ["GET"]},
    {["orders", :id, "collected"], ["POST"]},
    {["orders", :id, "quotes"], ["POST"]},
    {["orders", :id, "quotes", :id, "file"], ["GET"]},
    {["orders", :id, "printed"], ["POST"]},
    {["monthly-closes", :id], ["GET"]},
    {["monthly-closes", :id, "invoice"], ["GET", "POST"]}
  ]

  defp print(conn, deps, path) do
    case route_methods(path) do
      nil ->
        Reply.error(conn, :not_found)

      methods ->
        if conn.method in methods,
          do: authorized(conn, deps, path),
          else: method_not_allowed(conn, Enum.join(methods, ", "))
    end
  end

  defp route_methods(path) do
    Enum.find_value(@routes, fn {pattern, methods} -> if matches?(pattern, path), do: methods end)
  end

  defp matches?([], []), do: true
  defp matches?([:id | p], [_ | rest]), do: matches?(p, rest)
  defp matches?([seg | p], [seg | rest]), do: matches?(p, rest)
  defp matches?(_pattern, _path), do: false

  defp authorized(conn, deps, path) do
    case Security.current_session(conn, deps.session_store) do
      {:ok, session} ->
        if conn.method == "GET" or command_allowed?(conn, deps, session),
          do: print_route(conn, deps, conn.method, path),
          else: Reply.error(conn, :csrf_failed)

      :error ->
        Reply.error(conn, :unauthenticated)
    end
  end

  defp command_allowed?(conn, deps, session),
    do:
      Security.same_origin?(conn, deps.portal_origin) and
        Security.csrf_valid?(header(conn, "x-csrf-token"), session)

  defp print_route(conn, deps, "GET", ["orders"]) do
    conn = fetch_query_params(conn)

    case Requests.list_query(conn.query_params) do
      {:ok, query} -> respond(conn, UseCases.ListOrders.list_orders(deps, query))
      :error -> Reply.error(conn, :invalid_request)
    end
  end

  defp print_route(conn, deps, "GET", ["orders", id]) do
    with_ids(conn, [id], fn [id] -> respond(conn, UseCases.GetOrder.get_order(deps, id)) end)
  end

  defp print_route(conn, deps, "GET", ["orders", id, "files", file_id]) do
    with_ids(conn, [id, file_id], fn [id, file_id] ->
      Reply.download(conn, deps, {:order_file, id, file_id})
    end)
  end

  defp print_route(conn, deps, "GET", ["orders", id, "quotes", quote_id, "file"]) do
    with_ids(conn, [id, quote_id], fn [id, quote_id] ->
      Reply.download(conn, deps, {:quote_file, id, quote_id})
    end)
  end

  defp print_route(conn, deps, "POST", ["orders", id, "collected"]) do
    with_command(conn, [id], &Requests.collected/1, fn conn, [id], input, pre ->
      respond(conn, UseCases.CollectFiles.collect_files(deps, id, input, pre))
    end)
  end

  defp print_route(conn, deps, "POST", ["orders", id, "printed"]) do
    with_command(conn, [id], &Requests.printed/1, fn conn, [id], input, pre ->
      respond(conn, UseCases.MarkPrinted.mark_printed(deps, id, input, pre))
    end)
  end

  defp print_route(conn, deps, "POST", ["orders", id, "quotes"]) do
    with_upload(conn, [id], &Requests.quote_fields/1, fn conn, [id], fields, file, pre ->
      input = Map.put(fields, :file, file)
      respond(conn, UseCases.SubmitQuote.submit_quote(deps, id, input, pre))
    end)
  end

  defp print_route(conn, deps, "GET", ["monthly-closes", competence]) do
    with_competence(conn, competence, fn c ->
      respond(conn, UseCases.GetMonthlyClose.get_monthly_close(deps, c))
    end)
  end

  defp print_route(conn, deps, "GET", ["monthly-closes", competence, "invoice"]) do
    with_competence(conn, competence, fn c -> Reply.download(conn, deps, {:invoice_file, c}) end)
  end

  defp print_route(conn, deps, "POST", ["monthly-closes", competence, "invoice"]) do
    with_competence(conn, competence, fn c ->
      with_upload(conn, [], &Requests.invoice_fields/1, fn conn, [], fields, file, pre ->
        input = Map.put(fields, :file, file)
        respond(conn, UseCases.SubmitInvoice.submit_invoice(deps, c, input, pre))
      end)
    end)
  end

  # --- request plumbing ---

  # Non-UUID ids cannot exist upstream: 404 without a round trip.
  defp with_ids(conn, ids, fun) do
    if Enum.all?(ids, &match?({:ok, _}, Requests.uuid(&1))),
      do: fun.(ids),
      else: Reply.error(conn, :not_found)
  end

  defp with_competence(conn, competence, fun) do
    case Competence.parse(competence) do
      {:ok, c} -> fun.(Competence.to_string(c))
      :error -> Reply.error(conn, :invalid_competence)
    end
  end

  # Body first (as the upstream does), then preconditions.
  defp with_command(conn, ids, parser, fun) do
    with_ids(conn, ids, fn ids ->
      with {:ok, conn, body} <- json_body(conn),
           {:ok, input} <- parse(parser.(body)),
           {:ok, pre} <- preconditions(conn) do
        fun.(conn, ids, input, pre)
      else
        {:error, conn, reason} -> Reply.error(conn, reason)
        {:error, reason} -> Reply.error(conn, reason)
      end
    end)
  end

  defp with_upload(conn, ids, parser, fun) do
    with_ids(conn, ids, fn ids ->
      with {:ok, conn, fields, file} <- Multipart.read(conn, Document.max_body_bytes()),
           {:ok, input} <- parse(parser.(fields)),
           {:ok, pre} <- preconditions(conn) do
        fun.(conn, ids, input, file, pre)
      else
        {:error, conn, :too_large} -> Reply.error(conn, :file_too_large)
        {:error, conn, :invalid} -> Reply.error(conn, :invalid_request)
        {:error, reason} -> Reply.error(conn, reason)
      end
    end)
  end

  # Relayed as given; only unusable header values are refused here.
  defp preconditions(conn) do
    if_match = header(conn, "if-match")
    key = header(conn, "idempotency-key")

    if Enum.all?([if_match, key], &(is_nil(&1) or Regex.match?(~r/^[\x21-\x7E]{1,200}$/, &1))),
      do: {:ok, %{if_match: if_match, idempotency_key: key}},
      else: {:error, :invalid_request}
  end

  defp json_body(conn) do
    with ["application/json" <> _] <- get_req_header(conn, "content-type"),
         {:ok, raw, conn} <- read_body(conn, length: @json_limit),
         {:ok, %{} = body} <- JSON.decode(raw) do
      {:ok, conn, body}
    else
      {:more, _partial, conn} -> {:error, conn, :invalid_request}
      _ -> {:error, conn, :invalid_request}
    end
  end

  defp parse({:ok, value}), do: {:ok, value}
  defp parse(:error), do: {:error, :invalid_request}

  defp origin(conn, deps) do
    if Security.same_origin?(conn, deps.portal_origin), do: :ok, else: {:error, :csrf_failed}
  end

  defp pre_session(_deps, nil), do: {:error, :csrf_failed}

  defp pre_session(deps, id) do
    case SessionStore.fetch(deps.session_store, id, :pre) do
      {:ok, pre} -> {:ok, pre}
      :error -> {:error, :csrf_failed}
    end
  end

  defp csrf(token, pre),
    do: if(Security.csrf_valid?(token, pre), do: :ok, else: {:error, :csrf_failed})

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _ -> nil
    end
  end

  defp respond(conn, {:ok, response}), do: Reply.relay(conn, response)
  defp respond(conn, {:error, error}), do: Reply.error(conn, error)

  defp method_not_allowed(conn, allow) do
    conn |> put_resp_header("allow", allow) |> Reply.error(:method_not_allowed)
  end
end

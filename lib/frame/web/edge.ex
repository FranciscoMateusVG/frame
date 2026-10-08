defmodule Frame.Web.Edge do
  @moduledoc """
  The request edge, the last endpoint plug: request id, dependency map,
  hardening headers, static assets, then the router — all inside one server
  span with one `http.request` access line.

  Access logs and spans carry the route *template* (from the router), the
  method, status and duration — never query strings, bodies, cookies or
  headers. An exception anywhere below is answered here (500) and recorded
  as its *type* only: never `record_exception`, never the message or stack
  (they may carry request data), and never re-raised, so neither Phoenix
  nor Bandit logs it.
  """

  @behaviour Plug

  import Plug.Conn

  require OpenTelemetry.Tracer, as: Tracer

  alias Frame.Observability.Logger
  alias Frame.Web.Deps
  alias Frame.Web.PageHTML
  alias Frame.Web.Reply
  alias Frame.Web.Router
  alias Frame.Web.Security

  @assets %{
    "app.css" => {:frame, "priv/static/app.css"},
    "app.js" => {:frame, "priv/static/app.js"},
    "phoenix.min.js" => {:phoenix, "priv/static/phoenix.min.js"},
    "phoenix_live_view.min.js" => {:phoenix_live_view, "priv/static/phoenix_live_view.min.js"}
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    deps = Deps.fetch(conn)
    request_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Elixir.Logger.metadata(request_id: request_id)
    template = template(conn)
    started = System.monotonic_time()

    attributes = %{
      "http.request.method": conn.method,
      "http.route": template,
      "request.id": request_id
    }

    Tracer.with_span "HTTP #{conn.method} #{template}", %{kind: :server, attributes: attributes} do
      conn
      |> Deps.put(deps)
      |> assign(:request_id, request_id)
      |> put_resp_header("x-request-id", request_id)
      |> Security.put_security_headers(String.starts_with?(deps.portal_origin, "https://"))
      |> register_before_send(fn conn ->
        log(deps, conn, template, started)
        conn
      end)
      |> dispatch(deps)
    end
  end

  defp dispatch(conn, deps) do
    case conn.path_info do
      ["assets", file] -> asset(conn, file)
      _ -> Router.call(conn, Router.init([]))
    end
  rescue
    # Plug.Conn.WrapperError carries the conn as it was when the router
    # raised (pipeline assigns, layout); whatever was raised, only its type
    # is recorded.
    error ->
      {conn, error} = unwrap(conn, error)

      if Plug.Exception.status(error) == 404 and conn.state in [:unset, :set] do
        not_found(conn)
      else
        type = inspect(error.__struct__)
        Tracer.set_attribute(:"error.type", type)
        Tracer.set_status(OpenTelemetry.status(:error, "unhandled"))
        Logger.error(deps.observability.logger, "http.unhandled", %{error: type})

        if conn.state in [:unset, :set],
          do: Reply.error(conn, :internal),
          else: halt(conn)
      end
  end

  defp unwrap(_conn, %Plug.Conn.WrapperError{conn: conn, reason: reason}) when is_exception(reason),
    do: {conn, reason}

  defp unwrap(conn, error), do: {conn, error}

  # Only a LiveView's disconnected mount raises it: an HTML page.
  defp not_found(conn), do: PageHTML.not_found(conn)

  # Only the four known files; anything else under /assets is a 404.
  defp asset(conn, file) do
    case Map.fetch(@assets, file) do
      {:ok, {app, path}} when conn.method in ["GET", "HEAD"] ->
        conn
        |> put_resp_content_type(MIME.from_path(file), if(file =~ ".js", do: nil, else: "utf-8"))
        |> put_resp_header("cache-control", "public, max-age=300")
        |> send_file(200, Application.app_dir(app, path))

      _ ->
        Reply.error(conn, :not_found)
    end
  end

  defp log(deps, conn, template, started) do
    duration = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
    Tracer.set_attribute(:"http.response.status_code", conn.status)
    if conn.status >= 500, do: Tracer.set_status(OpenTelemetry.status(:error, "#{conn.status}"))

    unless template in ["/healthz", "/readyz", "/assets/:file"] do
      Logger.info(deps.observability.logger, "http.request", %{
        method: conn.method,
        route: template,
        status: conn.status,
        duration_ms: duration
      })
    end
  end

  @doc """
  The route template of a request, from the router (`/orders/:id`,
  `/api/print/v1/monthly-closes/:competence`). Unrouted paths are
  the catch-all `/*path` (or `/api/*path`) — the raw path never reaches
  telemetry.
  """
  @spec template(Plug.Conn.t()) :: String.t()
  def template(%Plug.Conn{path_info: ["assets" | _]}), do: "/assets/:file"

  def template(conn) do
    %{route: route} = Phoenix.Router.route_info(Router, conn.method, conn.path_info, conn.host)
    route
  end
end

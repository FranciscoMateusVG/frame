defmodule Frame.Http.Router do
  @moduledoc """
  The portal's top-level Plug: request id, hardening headers, one server
  span and one access-log line per request, then dispatch by path:

    * `GET /healthz` — liveness (no dependencies);
    * `GET /readyz` — configuration loaded and upstream answering with the
      service token (no content in the answer);
    * `/assets/*` — the stylesheet and script;
    * `/api/*` — `Frame.Http.Api`;
    * everything else — `Frame.Http.Pages`.

  `init/1` receives the dependency map built by the composition root
  (`Frame.Application`) or by tests. Access logs and spans carry the route
  *template*, method, status and duration — never query strings, bodies,
  cookies or headers.
  """

  @behaviour Plug

  import Plug.Conn

  require OpenTelemetry.Tracer, as: Tracer

  alias Frame.Adapters.PrintApi.Response
  alias Frame.Http.Api
  alias Frame.Http.Pages
  alias Frame.Http.Reply
  alias Frame.Http.Security
  alias Frame.Observability.Logger
  alias Frame.UseCases.ListOrders

  @static Plug.Static.init(
            at: "/assets",
            from: {:frame, "priv/static"},
            only: ~w(app.css app.js),
            gzip: false,
            headers: %{"cache-control" => "public, max-age=300"}
          )

  @impl true
  def init(deps), do: deps

  @impl true
  def call(conn, deps) do
    request_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    Elixir.Logger.metadata(request_id: request_id)
    template = template(conn.path_info)
    started = System.monotonic_time()

    attributes = %{
      "http.request.method": conn.method,
      "http.route": template,
      "request.id": request_id
    }

    Tracer.with_span "HTTP #{conn.method} #{template}", %{kind: :server, attributes: attributes} do
      conn
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
      ["healthz"] -> conn |> put_resp_content_type("text/plain") |> send_resp(200, "ok")
      ["readyz"] -> ready(conn, deps)
      ["assets" | _] -> static(conn)
      ["api" | rest] -> Api.call(conn, deps, rest)
      path -> Pages.call(conn, deps, path)
    end
  rescue
    # An exception message or stack trace may carry request data (bodies,
    # names, tokens): telemetry gets only the exception *type* and a fixed
    # status, never `record_exception`. Nothing is re-raised, so Bandit never
    # logs the exception either; a response already streaming is cut off.
    error ->
      type = inspect(error.__struct__)
      Tracer.set_attribute(:"error.type", type)
      Tracer.set_status(OpenTelemetry.status(:error, "unhandled"))
      Logger.error(deps.observability.logger, "http.unhandled", %{error: type})

      if conn.state in [:unset, :set],
        do: Reply.error(conn, :internal),
        else: halt(conn)
  end

  defp static(conn) do
    case Plug.Static.call(conn, @static) do
      %{halted: true} = conn -> conn
      conn -> Reply.error(conn, :not_found)
    end
  end

  # Ready = configured (we are running) + the upstream accepts the token.
  defp ready(conn, deps) do
    case ListOrders.list_orders(deps, %{limit: 1}) do
      {:ok, %Response{status: 200}} -> Reply.json(conn, 200, %{ready: true})
      _ -> Reply.json(conn, 503, %{ready: false})
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

  @uuid ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

  @doc "The route template of a path (ids → `:id`, months → `:competence`)."
  @spec template([String.t()]) :: String.t()
  def template(["assets" | _]), do: "/assets/:file"

  def template(path) do
    "/" <>
      Enum.map_join(path, "/", fn segment ->
        cond do
          Regex.match?(@uuid, segment) -> ":id"
          Regex.match?(~r/^\d{4}-\d{2}$/, segment) -> ":competence"
          Regex.match?(~r/^[a-z][a-z0-9-]{0,30}$/, segment) -> segment
          true -> ":param"
        end
      end)
  end
end

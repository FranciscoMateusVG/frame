defmodule Frame.Test.Portal do
  @moduledoc """
  The whole portal for tests, the Phoenix way: requests go through
  `Frame.Web.Endpoint` with `Phoenix.ConnTest` (and LiveViews with
  `Phoenix.LiveViewTest` on `conn/1`), carrying a small cookie jar like a
  browser.

  **One shared setup** (`start_shared/0`, from `test_helper.exs`): one
  `FakeHono` listener (real socket), one Finch pool, the PubSub and the
  endpoint. Each `start/1` then gets its **own** world — a FakeHono tenant
  (own token and in-memory upstream), its own session store and login
  limiter — and passes it to the endpoint per conn
  (`conn.private.frame_deps`), the way the composition root passes its
  own. So tests are `async: true` and never see each other's orders,
  sessions or limits; the portal still talks to the upstream through the
  real HTTP adapter over a real socket.

      portal = Frame.Test.Portal.start()
      {portal, body} = Frame.Test.Portal.login(portal)
      {portal, resp} = Frame.Test.Portal.get(portal, "/api/print/v1/orders")
  """

  alias Frame.Adapters.LoginLimiter
  alias Frame.Adapters.PrintApi
  alias Frame.Adapters.SessionStore
  alias Frame.Domain.Session
  alias Frame.Observability.NoopLogger
  alias Frame.Observability.Observability
  alias Frame.Observability.Tracer
  alias Frame.Test.FakeHono

  @password "senha-compartilhada-de-teste"
  @origin "http://portal.test"
  @finch Frame.Test.Finch
  @endpoint Frame.Web.Endpoint

  defstruct [:origin, :hono, :memory, :deps, jar: %{}, csrf: nil, remote_ip: {127, 0, 0, 1}]

  def password, do: @password
  def origin, do: @origin

  @doc """
  Starts the shared resources once (test_helper): Finch, the FakeHono
  listener, PubSub and the endpoint (no listener; ConnTest dispatches
  in-process).
  """
  def start_shared do
    {:ok, _} = Finch.start_link(name: @finch)
    hono = FakeHono.start()
    :persistent_term.put({__MODULE__, :hono}, hono)
    {:ok, pubsub} = Phoenix.PubSub.Supervisor.start_link(name: Frame.PubSub)
    Process.unlink(pubsub)
    restart_endpoint(hono)
  end

  @doc "Restarts the shared PubSub and endpoint (after a test took their names over)."
  def restart_shared do
    {:ok, pubsub} = Phoenix.PubSub.Supervisor.start_link(name: Frame.PubSub)
    Process.unlink(pubsub)
    restart_endpoint(hono())
  end

  @doc "(Re)starts the shared endpoint (no listener) with default deps on `hono`."
  def restart_endpoint(hono) do
    {:ok, config} = config(hono.token, FakeHono.origin(hono))
    deps = deps(config, hono, [])
    {:ok, pid} = @endpoint.start_link(Frame.Application.endpoint_options(config, deps))
    Process.unlink(pid)
    :ok
  end

  @doc "The shared FakeHono listener."
  def hono, do: :persistent_term.get({__MODULE__, :hono})

  @doc """
  A fresh, isolated portal world. Options: `:clock`, `:session_policy`,
  `:limits`, `:trusted_proxies`, `:timeout_ms`, `:observability`, `:token`
  (what the portal sends; defaults to its tenant's token), `:hono` (another
  FakeHono to talk to).
  """
  def start(opts \\ []) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    hono = FakeHono.tenant(Keyword.get_lazy(opts, :hono, &hono/0), clock: clock)
    {:ok, config} = config(Keyword.get(opts, :token, hono.token), FakeHono.origin(hono))
    config = %{config | trusted_proxies: Keyword.get(opts, :trusted_proxies, [])}

    %__MODULE__{origin: @origin, hono: hono, memory: hono.memory, deps: deps(config, hono, opts)}
  end

  defp config(token, api_origin) do
    Frame.Config.from_env(%{
      "PRINT_PORTAL_PASSWORD" => @password,
      "INCLUIR_PRINT_SERVICE_TOKEN" => token,
      "INCLUIR_PRINT_API_ORIGIN" => api_origin,
      "PRINT_PORTAL_ORIGIN" => @origin
    })
  end

  defp deps(config, _hono, opts) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    api =
      PrintApi.Http.new(
        finch: @finch,
        origin: config.api_origin,
        token: config.service_token,
        timeout_ms: Keyword.get(opts, :timeout_ms, 5_000)
      )

    store =
      SessionStore.Memory.new(
        policy: Keyword.get(opts, :session_policy, Session.default_policy()),
        clock: clock
      )

    limiter = LoginLimiter.Memory.new(limits: Keyword.get(opts, :limits, %{}))

    config
    |> Frame.Application.deps(print_api: api, session_store: store, login_limiter: limiter)
    |> Map.put(:clock, clock)
    |> Map.put(:observability, Keyword.get(opts, :observability, quiet_observability()))
  end

  defp quiet_observability do
    %Observability{logger: NoopLogger.new(), tracer: Tracer.noop_tracer()}
  end

  @doc "A fresh browser (empty cookie jar) on the same portal."
  def fresh(%__MODULE__{} = p), do: %{p | jar: %{}, csrf: nil}

  @doc "The same browser seen from another client address."
  def from_ip(%__MODULE__{} = p, ip), do: %{p | remote_ip: ip}

  @doc """
  A `Phoenix.ConnTest` conn for this browser: its cookies, its client
  address and this portal's deps — ready for `get/2` or
  `Phoenix.LiveViewTest.live/2`.
  """
  def conn(%__MODULE__{} = p) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, p.remote_ip)
    |> Plug.Conn.put_private(:frame_deps, p.deps)
    |> put_cookies(p.jar)
  end

  defp put_cookies(conn, jar),
    do: Enum.reduce(jar, conn, fn {k, v}, conn -> Plug.Test.put_req_cookie(conn, k, v) end)

  @doc "GET /api/session then POST the password. Returns the logged-in portal handle."
  def login(%__MODULE__{} = p, password \\ @password) do
    {p, %{body: %{"csrfToken" => pre_csrf}}} = request(p, :get, "/api/session")

    {p, resp} =
      request(p, :post, "/api/session",
        json: %{password: password},
        headers: [{"origin", p.origin}, {"x-csrf-token", pre_csrf}]
      )

    csrf = if resp.status == 200, do: resp.body["csrfToken"], else: pre_csrf
    {%{p | csrf: csrf}, resp}
  end

  @doc "Logs in and returns only the signed-in handle."
  def signed_in(%__MODULE__{} = p) do
    {p, %{status: 200}} = login(p)
    p
  end

  def get(p, path, opts \\ []), do: request(p, :get, path, opts)

  @doc "A browser command: Origin + CSRF headers added."
  def command(p, method, path, opts \\ []) do
    headers = [{"origin", p.origin}, {"x-csrf-token", p.csrf} | Keyword.get(opts, :headers, [])]
    request(p, method, path, Keyword.put(opts, :headers, headers))
  end

  @doc """
  Sends a request through the endpoint. Options: `:headers`, `:json`
  (map), `:form` (map), `:multipart` ({fields, {filename, content_type,
  bytes}}), `:raw` ({content_type, body}).
  Returns `{portal_with_updated_jar, %{status, headers, body, raw}}`.
  """
  def request(%__MODULE__{} = p, method, path, opts \\ []) do
    {content_headers, body} = encode_body(opts)

    conn =
      p
      |> conn()
      |> then(fn conn ->
        Enum.reduce(content_headers ++ Keyword.get(opts, :headers, []), conn, fn {k, v}, conn ->
          Plug.Conn.put_req_header(conn, k, v)
        end)
      end)
      |> Phoenix.ConnTest.dispatch(@endpoint, method, path, body)

    headers = conn.resp_headers

    decoded =
      case JSON.decode(conn.resp_body || "") do
        {:ok, value} -> value
        _ -> conn.resp_body
      end

    {%{p | jar: update_jar(p.jar, headers)},
     %{status: conn.status, headers: headers, body: decoded, raw: conn.resp_body}}
  end

  defp encode_body(opts) do
    cond do
      json = opts[:json] ->
        {[{"content-type", "application/json"}], JSON.encode!(json)}

      form = opts[:form] ->
        {[{"content-type", "application/x-www-form-urlencoded"}], URI.encode_query(form)}

      mp = opts[:multipart] ->
        multipart(mp)

      raw = opts[:raw] ->
        {[{"content-type", elem(raw, 0)}], elem(raw, 1)}

      true ->
        {[], nil}
    end
  end

  def header(resp, name) do
    for {k, v} <- resp.headers, k == name, do: v
  end

  defp update_jar(jar, headers) do
    for {"set-cookie", value} <- headers, reduce: jar do
      jar ->
        [pair | _] = String.split(value, ";")
        [name, val] = String.split(pair, "=", parts: 2)

        if val == "" or String.contains?(value, "max-age=0"),
          do: Map.delete(jar, name),
          else: Map.put(jar, name, val)
    end
  end

  defp multipart({fields, file}) do
    boundary = "testboundary#{System.unique_integer([:positive])}"

    parts =
      Enum.map(fields, fn {k, v} ->
        ~s(--#{boundary}\r\ncontent-disposition: form-data; name="#{k}"\r\n\r\n#{v}\r\n)
      end)

    file_part =
      case file do
        nil ->
          ""

        {name, type, bytes} ->
          ~s(--#{boundary}\r\ncontent-disposition: form-data; name="file"; filename="#{name}"\r\n) <>
            "content-type: #{type}\r\n\r\n" <> bytes <> "\r\n"
      end

    {[{"content-type", "multipart/form-data; boundary=#{boundary}"}],
     IO.iodata_to_binary([parts, file_part, "--#{boundary}--\r\n"])}
  end

  @pdf "%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n"
  def pdf(extra \\ ""), do: @pdf <> extra

  @doc "Seeds a ready order with two jobs (distinct bytes). Returns the order DTO."
  def seed(%__MODULE__{memory: m}, opts \\ []) do
    PrintApi.Memory.seed_order(
      m,
      [
        %{
          title: "Apostila de Matemática",
          copies: 2,
          instructions: "Frente e verso, grampeado",
          file_name: "matematica.pdf",
          bytes: pdf("mat")
        },
        %{
          title: "Lista de Física",
          copies: 7,
          instructions: "Só frente, colorido",
          file_name: "física final.pdf",
          bytes: pdf("fis")
        }
      ],
      opts
    )
  end
end

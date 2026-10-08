defmodule Frame.Test.Portal do
  @moduledoc """
  Starts the whole portal for black-box tests: `Frame.Http.Router` on Bandit
  (real socket), wired with the real HTTP adapter to a `FakeHono` (real
  socket), the real session store and login limiter. Requests go through
  Finch with a tiny cookie jar, like a browser would.

      portal = Frame.Test.Portal.start()
      {portal, body} = Frame.Test.Portal.login(portal)
      resp = Frame.Test.Portal.get(portal, "/api/print/v1/orders")
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

  defstruct [:port, :origin, :hono, :memory, :deps, :finch, jar: %{}, csrf: nil]

  def password, do: @password

  @doc """
  Options: `:clock`, `:session_policy`, `:limits`, `:trusted_proxies`,
  `:timeout_ms`, `:observability`, `:token` (what the portal sends; defaults
  to the fake's token).
  """
  def start(opts \\ []) do
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    hono = FakeHono.start(clock: clock)
    finch = :"finch_#{System.unique_integer([:positive])}"
    {:ok, _} = Finch.start_link(name: finch)

    port = free_port()
    origin = "http://localhost:#{port}"

    {:ok, config} =
      Frame.Config.from_env(%{
        "PRINT_PORTAL_PASSWORD" => @password,
        "INCLUIR_PRINT_SERVICE_TOKEN" => Keyword.get(opts, :token, hono.token),
        "INCLUIR_PRINT_API_ORIGIN" => FakeHono.origin(hono),
        "PRINT_PORTAL_ORIGIN" => origin
      })

    config = %{config | trusted_proxies: Keyword.get(opts, :trusted_proxies, [])}

    api =
      PrintApi.Http.new(
        finch: finch,
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

    deps =
      Frame.Application.deps(config, print_api: api, session_store: store, login_limiter: limiter)
      |> Map.put(:clock, clock)
      |> then(fn deps ->
        case Keyword.get(opts, :observability) do
          nil -> Map.put(deps, :observability, quiet_observability())
          obs -> Map.put(deps, :observability, obs)
        end
      end)

    {:ok, _} =
      Bandit.start_link(
        plug: {Frame.Http.Router, deps},
        port: port,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    %__MODULE__{
      port: port,
      origin: origin,
      hono: hono,
      memory: hono.memory,
      deps: deps,
      finch: finch
    }
  end

  defp quiet_observability do
    %Observability{logger: NoopLogger.new(), tracer: Tracer.noop_tracer()}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  @doc "A fresh browser (empty cookie jar) on the same portal."
  def fresh(%__MODULE__{} = p), do: %{p | jar: %{}, csrf: nil}

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

  def get(p, path, opts \\ []), do: request(p, :get, path, opts)

  @doc "A browser command: Origin + CSRF headers added."
  def command(p, method, path, opts \\ []) do
    headers = [{"origin", p.origin}, {"x-csrf-token", p.csrf} | Keyword.get(opts, :headers, [])]
    request(p, method, path, Keyword.put(opts, :headers, headers))
  end

  @doc """
  Sends a request. Options: `:headers`, `:json` (map), `:form` (map),
  `:multipart` ({fields, {filename, content_type, bytes}}), `:raw` ({content_type, body}).
  Returns `{portal_with_updated_jar, %{status, headers, body, raw}}`.
  """
  def request(%__MODULE__{} = p, method, path, opts \\ []) do
    {content_headers, body} = encode_body(opts)

    cookie =
      case p.jar do
        jar when map_size(jar) == 0 -> []
        jar -> [{"cookie", Enum.map_join(jar, "; ", fn {k, v} -> "#{k}=#{v}" end)}]
      end

    headers = content_headers ++ cookie ++ Keyword.get(opts, :headers, [])
    req = Finch.build(method, "http://127.0.0.1:#{p.port}" <> path, headers, body)
    {:ok, resp} = Finch.request(req, p.finch, receive_timeout: 15_000)

    jar = update_jar(p.jar, resp.headers)

    decoded =
      case JSON.decode(resp.body) do
        {:ok, value} -> value
        _ -> resp.body
      end

    {%{p | jar: jar}, %{status: resp.status, headers: resp.headers, body: decoded, raw: resp.body}}
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

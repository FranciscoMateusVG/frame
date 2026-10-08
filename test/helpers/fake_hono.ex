defmodule Frame.Test.FakeHono do
  @moduledoc """
  A fake of the Incluir print-portal service API served over real HTTP
  (Bandit), backed by `Frame.Adapters.PrintApi.Memory`. Lets the HTTP
  adapter and the whole portal be tested through real sockets.

  One server hosts any number of **tenants** (`tenant/2`): each has its own
  token, memory and control, and a request is served by the tenant whose
  token it carries — so async tests share one listener without sharing any
  state.

  It checks the bearer token like the real middleware (401 otherwise) and
  can misbehave on demand (`misbehave/2`): `:redirect`, `:slow`, `:huge`,
  `:drift` (off-contract body), `:html_500`, `:short_body`, `:no_closes`. It records the
  headers of the last request (`last_headers/1`) so tests can assert what
  the portal sends.
  """

  @behaviour Plug

  import Plug.Conn

  alias Frame.Adapters.PrintApi
  alias Frame.Adapters.PrintApi.Memory

  @prefix ["api", "print-portal", "v1"]

  defstruct [:port, :memory, :control, :token, :tenants]

  @doc "Starts a fake on a random port with one tenant. Returns its handle."
  def start(opts \\ []) do
    {:ok, tenants} = Agent.start_link(fn -> %{} end)

    {:ok, pid} =
      Bandit.start_link(
        plug: {__MODULE__, tenants},
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    tenant(
      %__MODULE__{port: port, tenants: tenants},
      Keyword.put_new(opts, :token, String.duplicate("s", 48))
    )
  end

  @doc """
  A new tenant on the same server: its own token (random unless given),
  memory (`:memory` or a fresh one with `:clock`) and control.
  """
  def tenant(%__MODULE__{} = hono, opts \\ []) do
    memory = Keyword.get_lazy(opts, :memory, fn -> Memory.new(Keyword.take(opts, [:clock])) end)

    token =
      Keyword.get_lazy(opts, :token, fn -> Base.url_encode64(:crypto.strong_rand_bytes(36)) end)

    {:ok, control} = Agent.start(fn -> %{mode: nil, headers: [], requests: 0, commands: []} end)

    Agent.update(
      hono.tenants,
      &Map.put(&1, token, %{memory: memory, control: control, token: token})
    )

    %{hono | memory: memory, control: control, token: token}
  end

  def origin(%__MODULE__{port: port}), do: "http://127.0.0.1:#{port}"

  def misbehave(%__MODULE__{control: c}, mode), do: Agent.update(c, &%{&1 | mode: mode})
  def last_headers(%__MODULE__{control: c}), do: Agent.get(c, & &1.headers)
  def request_count(%__MODULE__{control: c}), do: Agent.get(c, & &1.requests)

  @doc "The headers (as maps) of every non-GET request this tenant received, in order."
  def commands(%__MODULE__{control: c}), do: Agent.get(c, & &1.commands)

  @impl true
  def init(state), do: state

  @impl true
  def call(conn, tenants) do
    case tenant_of(conn, tenants) do
      nil ->
        json(conn, 401, err("UNAUTHORIZED", "Credencial inválida."))

      state ->
        Agent.update(state.control, &record(&1, conn))

        case Agent.get(state.control, & &1.mode) do
          nil -> serve(conn, state)
          mode -> misbehave_now(conn, mode, state)
        end
    end
  end

  defp record(control, conn) do
    commands =
      if conn.method == "GET",
        do: control.commands,
        else: control.commands ++ [Map.new(conn.req_headers)]

    %{control | headers: conn.req_headers, requests: control.requests + 1, commands: commands}
  end

  defp tenant_of(conn, tenants) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Agent.get(tenants, &Map.get(&1, token))
      _ -> nil
    end
  end

  # A Hono without PR C: the monthly-close routes do not exist.
  defp misbehave_now(conn, :no_closes, state) do
    if "monthly-closes" in conn.path_info,
      do: json(conn, 404, err("NOT_FOUND", "Recurso não encontrado.")),
      else: serve(conn, state)
  end

  defp misbehave_now(conn, :redirect, _state),
    do: conn |> put_resp_header("location", "http://127.0.0.1:1/steal") |> send_resp(302, "")

  defp misbehave_now(conn, :slow, state) do
    Process.sleep(1500)
    serve(conn, state)
  end

  defp misbehave_now(conn, :huge, _state) do
    conn = send_chunked(conn, 200)
    chunk = String.duplicate("a", 1_000_000)

    Enum.reduce_while(1..4, conn, fn _, conn ->
      case chunk(conn, chunk) do
        {:ok, conn} -> {:cont, conn}
        _ -> {:halt, conn}
      end
    end)
  end

  defp misbehave_now(conn, :drift, _state),
    do: json(conn, 200, %{"items" => [%{"id" => "x"}], "nextCursor" => nil, "extra" => true})

  defp misbehave_now(conn, :html_500, _state),
    do: conn |> put_resp_content_type("text/html") |> send_resp(500, "<h1>boom</h1>")

  defp misbehave_now(conn, :short_body, _state) do
    conn
    |> put_resp_header("content-type", "application/pdf")
    |> put_resp_header("content-length", "1000")
    |> send_chunked(200)
    |> then(fn conn ->
      {:ok, conn} = chunk(conn, "%PDF-1.4 short")
      conn
    end)
  end

  defp serve(conn, state) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(token, state.token) do
      route(conn, state.memory, conn.method, conn.path_info)
    else
      _ -> json(conn, 401, err("UNAUTHORIZED", "Credencial inválida."))
    end
  end

  defp route(conn, m, "GET", @prefix ++ ["orders"]) do
    conn = fetch_query_params(conn)
    q = conn.query_params

    query =
      %{}
      |> put_if(:status, q["status"])
      |> put_if(:limit, q["limit"] && String.to_integer(q["limit"]))
      |> put_if(:cursor, q["cursor"])

    reply(conn, PrintApi.list_orders(m, query))
  end

  defp route(conn, m, "GET", @prefix ++ ["orders", id]), do: reply(conn, PrintApi.get_order(m, id))

  defp route(conn, m, "GET", @prefix ++ ["orders", id, "files", file_id]),
    do: download(conn, m, {:order_file, id, file_id})

  defp route(conn, m, "GET", @prefix ++ ["orders", id, "quotes", qid, "file"]),
    do: download(conn, m, {:quote_file, id, qid})

  defp route(conn, m, "GET", @prefix ++ ["monthly-closes", c, "invoice"]),
    do: download(conn, m, {:invoice_file, c})

  defp route(conn, m, "GET", @prefix ++ ["monthly-closes", c]),
    do: reply(conn, PrintApi.get_close(m, c))

  defp route(conn, m, "POST", @prefix ++ ["orders", id, "collected"]) do
    {:ok, raw, conn} = read_body(conn)
    %{"revision" => r} = JSON.decode!(raw)
    reply(conn, PrintApi.collect(m, id, %{revision: r}, pre(conn)))
  end

  defp route(conn, m, "POST", @prefix ++ ["orders", id, "printed"]) do
    {:ok, raw, conn} = read_body(conn)
    %{"revision" => r, "quoteId" => q} = JSON.decode!(raw)
    reply(conn, PrintApi.mark_printed(m, id, %{revision: r, quote_id: q}, pre(conn)))
  end

  defp route(conn, m, "POST", @prefix ++ ["orders", id, "quotes"]) do
    conn = parse_multipart(conn)
    p = conn.body_params
    file = upload(p["file"])

    input = %{
      amount_cents: String.to_integer(p["amountCents"]),
      order_revision: String.to_integer(p["orderRevision"]),
      file: file
    }

    reply(conn, PrintApi.submit_quote(m, id, input, pre(conn)))
  end

  defp route(conn, m, "POST", @prefix ++ ["monthly-closes", c, "invoice"]) do
    conn = parse_multipart(conn)
    p = conn.body_params

    input = %{
      declared_total_cents: String.to_integer(p["declaredTotalCents"]),
      file: upload(p["file"])
    }

    reply(conn, PrintApi.submit_invoice(m, c, input, pre(conn)))
  end

  defp route(conn, _m, _method, _path),
    do: json(conn, 404, err("NOT_FOUND", "Recurso não encontrado."))

  defp parse_multipart(conn) do
    opts = Plug.Parsers.init(parsers: [:multipart], length: 10_000_000)
    Plug.Parsers.call(conn, opts)
  end

  defp upload(%Plug.Upload{filename: name, path: path, content_type: type}),
    do: %{name: name, bytes: File.read!(path), content_type: type}

  defp pre(conn) do
    %{
      if_match: List.first(get_req_header(conn, "if-match")),
      idempotency_key: List.first(get_req_header(conn, "idempotency-key"))
    }
  end

  defp download(conn, m, target) do
    sink = fn
      {:head, headers}, conn ->
        Enum.reduce(headers, conn, fn {k, v}, conn -> put_resp_header(conn, k, v) end)
        |> send_chunked(200)

      {:data, data}, conn ->
        {:ok, conn} = chunk(conn, data)
        conn
    end

    case PrintApi.download(m, target, conn, sink) do
      {:streamed, conn} -> conn
      {:ok, response} -> reply(conn, {:ok, response})
    end
  end

  defp reply(conn, {:ok, %PrintApi.Response{} = r}) do
    conn = if r.etag, do: put_resp_header(conn, "etag", r.etag), else: conn
    conn = if r.replayed, do: put_resp_header(conn, "idempotency-replayed", "true"), else: conn
    json(conn, r.status, r.body)
  end

  defp reply(conn, {:error, :unavailable}), do: json(conn, 503, err("UPSTREAM_UNAVAILABLE", "x"))

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
  end

  defp err(code, message),
    do: %{"error" => %{"code" => code, "message" => message, "requestId" => ""}}

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)
end

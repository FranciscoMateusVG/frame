# Example: Expose `create_cat` over an HTTP API using Plug + Bandit.
#
# Plug is Elixir's minimal composable web interface and Bandit a pure-Elixir
# HTTP server. This example demonstrates how to wire a Frame use case into
# HTTP routes without bleeding HTTP concerns into the use case itself — the
# route handler is a thin shell:
#
#   1. parse + validate the request body
#   2. call the use case with deps + input
#   3. translate domain errors into HTTP responses
#
# The use case (`create_cat`) and the repository (`CatRepository.Postgres`)
# are unchanged from the SDK examples. Plug is purely a transport adapter.
#
# Fully self-contained — uses Testcontainers to spin up a Postgres instance,
# boots Bandit on an ephemeral port, issues a few self-requests to demonstrate
# the flow, then tears everything down.
#
# Usage: MIX_ENV=test mix run examples/create_cat.plug.exs

alias Frame.Adapters.CatRepository.Postgres
alias Frame.Observability.{ConsoleLogger, Observability, Tracer}
alias Frame.Test.TestDb

defmodule CatRouter do
  # Routes are thin adapters: parse → invoke use case → translate errors.
  use Plug.Router, copy_opts_to_assign: :router_opts

  alias Frame.Adapters.CatRepository
  alias Frame.Errors.{CatAlreadyExistsError, InvalidCatNameError}

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: JSON
  plug :dispatch

  post "/cats" do
    name =
      case conn.body_params do
        %{"name" => name} when is_binary(name) -> name
        _ -> ""
      end

    case Frame.create_cat(conn.assigns.router_opts[:deps], %{id: Ecto.UUID.generate(), name: name}) do
      {:ok, cat} ->
        json(conn, 201, cat_json(cat))

      {:error, %CatAlreadyExistsError{} = err} ->
        json(conn, 409, %{error: err.code, message: err.message})

      {:error, %InvalidCatNameError{} = err} ->
        json(conn, 400, %{error: err.code, message: err.message})
    end
  end

  get "/cats/:id" do
    case CatRepository.find_by_id(conn.assigns.router_opts[:deps].cat_repository, id) do
      nil -> json(conn, 404, %{error: "NOT_FOUND"})
      cat -> json(conn, 200, cat_json(cat))
    end
  end

  defp cat_json(cat),
    do: %{id: cat.id, name: cat.name, createdAt: DateTime.to_iso8601(cat.created_at)}

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end

defmodule Client do
  def request(method, url, body \\ nil) do
    request =
      if body,
        do: {String.to_charlist(url), [], ~c"application/json", JSON.encode!(body)},
        else: {String.to_charlist(url), []}

    {:ok, {{_, status, _}, _headers, resp_body}} = :httpc.request(method, request, [], [])
    {status, JSON.decode!(IO.iodata_to_binary(resp_body))}
  end
end

IO.puts("🐱 Frame Example: Create a Cat (HTTP via Plug + Bandit)")
IO.puts("========================================================")
IO.puts("")

{:ok, _} = Application.ensure_all_started([:inets, :bandit])
test_db = TestDb.create_test_database()

try do
  deps = %{
    cat_repository: Postgres.new(test_db.db),
    clock: &DateTime.utc_now/0,
    observability: %Observability{logger: ConsoleLogger.new(), tracer: Tracer.noop_tracer()}
  }

  # --- Boot on an ephemeral port ---
  {:ok, server} =
    Bandit.start_link(plug: {CatRouter, deps: deps}, ip: :loopback, port: 0, startup_log: false)

  {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
  base_url = "http://127.0.0.1:#{port}"
  IO.puts("✅ Bandit server listening on #{base_url}")
  IO.puts("")

  try do
    # --- Demonstrate the API ---
    {status, created} = Client.request(:post, "#{base_url}/cats", %{name: "Whiskers"})
    IO.puts("✅ POST /cats → #{status} #{inspect(created)}")

    {status, fetched} = Client.request(:get, "#{base_url}/cats/#{created["id"]}")
    IO.puts("✅ GET /cats/#{created["id"]} → #{status} #{inspect(fetched)}")

    # Duplicate name → 409
    {status, dup} = Client.request(:post, "#{base_url}/cats", %{name: "Whiskers"})
    IO.puts("✅ POST /cats (duplicate) → #{status} #{inspect(dup)}")

    # Invalid name → 400
    {status, bad} = Client.request(:post, "#{base_url}/cats", %{name: ""})
    IO.puts("✅ POST /cats (invalid) → #{status} #{inspect(bad)}")

    IO.puts("")
    IO.puts("🎉 Example completed successfully!")
  after
    :ok = Supervisor.stop(server)
  end
after
  TestDb.teardown(test_db)
end

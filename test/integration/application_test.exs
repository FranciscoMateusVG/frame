defmodule Frame.Integration.ApplicationTest do
  @moduledoc """
  The composition root as production runs it: the real children (Finch
  pool, session table owner, login limiter, PubSub, the Phoenix endpoint on
  Bandit) wired from a Config, against a fake Hono over HTTP, on a real
  port. Proves the release is not "works only with the fake in tests"
  (wire-the-adapter), and checks the LiveView socket's Origin gate on a
  real websocket upgrade.

  Sync: it takes over the endpoint and PubSub names from the shared test
  setup for its duration (sync tests run after every async one).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Frame.Test.FakeHono
  alias Frame.Test.Portal

  setup do
    :ok = Supervisor.stop(Frame.Web.Endpoint)
    :ok = Supervisor.stop(Frame.PubSub.Supervisor)

    on_exit(fn ->
      # Give the shared setup its endpoint and PubSub back.
      :ok = Portal.restart_shared()
    end)
  end

  test "children/1 serves the portal end to end" do
    hono = FakeHono.start()
    port = free_port()
    origin = "http://localhost:#{port}"

    config =
      Frame.Application.load_config!(%{
        "PRINT_PORTAL_PASSWORD" => "senha-de-producao-falsa",
        "INCLUIR_PRINT_SERVICE_TOKEN" => hono.token,
        "INCLUIR_PRINT_API_ORIGIN" => FakeHono.origin(hono),
        "PRINT_PORTAL_ORIGIN" => origin,
        "PORT" => "#{port}"
      })

    start_supervised!(%{
      id: :portal,
      type: :supervisor,
      start:
        {Supervisor, :start_link, [Frame.Application.children(config), [strategy: :one_for_one]]}
    })

    {:ok, _} = Finch.start_link(name: AppTestClient)

    get = fn path ->
      Finch.build(:get, "http://127.0.0.1:#{port}" <> path) |> Finch.request(AppTestClient)
    end

    assert {:ok, %{status: 200, headers: version_headers, body: version_body}} = get.("/version")
    assert JSON.decode!(version_body) == %{"revision" => "unknown"}
    assert {"cache-control", "no-store"} in version_headers

    assert Enum.any?(version_headers, fn {key, value} ->
             key == "content-type" and String.starts_with?(value, "application/json")
           end)

    assert {:ok, %{status: 200}} = get.("/healthz")
    assert {:ok, %{status: 200, body: ~s({"ready":true})}} = get.("/readyz")
    assert {:ok, %{status: 302}} = get.("/orders")
    assert {:ok, %{status: 200, body: body}} = get.("/api/session")
    assert body =~ ~s("authenticated":false)

    assert {:ok, %{status: 200, body: "var LiveView=" <> _}} =
             get.("/assets/phoenix_live_view.min.js")

    # The LiveView socket: exact Origin only, and never without one.
    assert upgrade(port, nil) =~ ~r/^HTTP\/1.1 403/
    assert upgrade(port, "http://evil.example") =~ ~r/^HTTP\/1.1 403/
    assert upgrade(port, origin) =~ ~r/^HTTP\/1.1 101/
  end

  test "an invalid environment refuses to start, naming variables only" do
    stderr =
      capture_io(:stderr, fn ->
        assert_raise RuntimeError, ~r/refusing to start/, fn ->
          Frame.Application.load_config!(%{"PRINT_PORTAL_PASSWORD" => "curta"})
        end
      end)

    assert stderr =~ "PRINT_PORTAL_PASSWORD must have at least 12 characters"
    assert stderr =~ "INCLUIR_PRINT_SERVICE_TOKEN is required"
    refute stderr =~ "curta"
  end

  # A raw websocket upgrade request; returns the status line.
  defp upgrade(port, origin) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    request =
      [
        "GET /live/websocket?vsn=2.0.0 HTTP/1.1\r\n",
        "host: localhost:#{port}\r\n",
        "upgrade: websocket\r\n",
        "connection: Upgrade\r\n",
        "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
        "sec-websocket-version: 13\r\n",
        if(origin, do: "origin: #{origin}\r\n", else: ""),
        "\r\n"
      ]

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
    response |> String.split("\r\n") |> hd()
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

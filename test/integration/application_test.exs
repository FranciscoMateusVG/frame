defmodule Frame.Integration.ApplicationTest do
  @moduledoc """
  The composition root as production runs it: the real children (Finch
  pool, session table owner, login limiter, Bandit) wired from a Config,
  against a fake Hono over HTTP. Proves the release is not "works only with
  the fake in tests" (wire-the-adapter).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Frame.Test.FakeHono

  test "children/1 serves the portal end to end" do
    hono = FakeHono.start()
    port = free_port()

    config =
      Frame.Application.load_config!(%{
        "PRINT_PORTAL_PASSWORD" => "senha-de-producao-falsa",
        "INCLUIR_PRINT_SERVICE_TOKEN" => hono.token,
        "INCLUIR_PRINT_API_ORIGIN" => FakeHono.origin(hono),
        "PRINT_PORTAL_ORIGIN" => "http://localhost:#{port}",
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

    assert {:ok, %{status: 200}} = get.("/healthz")
    assert {:ok, %{status: 200, body: ~s({"ready":true})}} = get.("/readyz")
    assert {:ok, %{status: 302}} = get.("/orders")
    assert {:ok, %{status: 200, body: body}} = get.("/api/session")
    assert body =~ ~s("authenticated":false)
  end

  test "an invalid environment refuses to start, naming variables only" do
    stderr =
      capture_io(:stderr, fn ->
        assert_raise RuntimeError, ~r/refusing to start/, fn ->
          Frame.Application.load_config!(%{"PRINT_PORTAL_PASSWORD" => "curta"})
        end
      end)

    assert stderr =~ "PRINT_PORTAL_PASSWORD must have at least 16 characters"
    assert stderr =~ "INCLUIR_PRINT_SERVICE_TOKEN is required"
    refute stderr =~ "curta"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

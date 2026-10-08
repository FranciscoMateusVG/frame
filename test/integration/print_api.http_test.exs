defmodule Frame.Integration.PrintApiHttpTest do
  @moduledoc "The real HTTP adapter against a fake Hono over real sockets."
  use ExUnit.Case, async: false
  use Frame.Test.PrintApiConformance

  alias Frame.Test.Observability, as: TestObservability

  alias Frame.Adapters.PrintApi.Http
  alias Frame.Test.FakeHono

  setup_all do
    obs = TestObservability.create_test_observability()
    on_exit(fn -> TestObservability.shutdown(obs) end)
    %{obs: obs}
  end

  setup do
    {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)
    hono = FakeHono.start(clock: fn -> Agent.get(clock, & &1) end)
    finch = :"finch_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: finch})

    api =
      Http.new(
        finch: finch,
        origin: FakeHono.origin(hono),
        token: hono.token,
        timeout_ms: 800,
        download_timeout_ms: 800
      )

    %{api: api, memory: hono.memory, clock: clock, hono: hono}
  end

  test "sends the bearer token, never shows it in inspect", %{api: api, hono: hono} do
    {:ok, _} = PrintApi.list_orders(api, %{})
    headers = FakeHono.last_headers(hono)
    assert {"authorization", "Bearer " <> hono.token} in headers
    refute inspect(api) =~ hono.token
  end

  test "a refused token is relayed as 401 (the use case maps it)", %{api: api} do
    api = %{api | token: String.duplicate("w", 48)}
    assert {:ok, %Response{status: 401}} = PrintApi.list_orders(api, %{})
  end

  test "redirects are never followed", %{api: api, hono: hono} do
    FakeHono.misbehave(hono, :redirect)
    assert PrintApi.list_orders(api, %{}) == {:error, :unavailable}
    assert FakeHono.request_count(hono) == 1
  end

  test "timeouts, oversized and off-contract bodies are unavailable", %{api: api, hono: hono} do
    FakeHono.misbehave(hono, :slow)
    assert PrintApi.list_orders(api, %{}) == {:error, :unavailable}
    FakeHono.misbehave(hono, :huge)
    assert PrintApi.list_orders(api, %{}) == {:error, :unavailable}
    FakeHono.misbehave(hono, :drift)
    assert PrintApi.list_orders(api, %{}) == {:error, :unavailable}
    FakeHono.misbehave(hono, :html_500)
    assert PrintApi.list_orders(api, %{}) == {:error, :unavailable}
  end

  test "a truncated download is reported as interrupted", %{api: api, hono: hono} do
    FakeHono.misbehave(hono, :short_body)

    assert {:error, :interrupted, %{headers: _}} =
             collect_bytes(api, {:order_file, Ids.uuid(), Ids.uuid()})
  end

  test "an unreachable origin is unavailable", %{api: api} do
    api = %{api | origin: "http://127.0.0.1:1"}
    assert PrintApi.get_order(api, Ids.uuid()) == {:error, :unavailable}
    assert collect_bytes(api, {:invoice_file, "2026-09"}) == {:error, :unavailable}
  end
end

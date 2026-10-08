defmodule Frame.Unit.PrintApiMemoryTest do
  use ExUnit.Case, async: false
  use Frame.Test.PrintApiConformance

  alias Frame.Test.Observability, as: TestObservability

  setup_all do
    obs = TestObservability.create_test_observability()
    on_exit(fn -> TestObservability.shutdown(obs) end)
    %{obs: obs}
  end

  setup do
    {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)
    memory = Memory.new(clock: fn -> Agent.get(clock, & &1) end)
    %{api: memory, memory: memory, clock: clock}
  end

  test "injected failures", %{api: api} do
    Memory.fail_with(api, :unavailable)
    assert PrintApi.get_order(api, Ids.uuid()) == {:error, :unavailable}
    Memory.fail_with(api, :unauthorized)
    assert {:ok, %Response{status: 401}} = PrintApi.list_orders(api, %{})
    Memory.fail_with(api, :not_configured)
    assert {:ok, %Response{status: 503}} = PrintApi.get_close(api, "2026-09")
    Memory.fail_with(api, nil)
    assert {:ok, %Response{status: 200}} = PrintApi.list_orders(api, %{})
  end

  test "staff helpers refuse invalid transitions", %{api: api} do
    [o] = seed(api)
    assert Memory.decide_quote(api, o["id"], :approved) == :error
    assert Memory.decide_invoice(api, "2026-09", :accepted) == :error
    assert Memory.cancel(api, o["id"], "Pedido duplicado") == :ok
    assert Memory.cancel(api, o["id"], "de novo") == :error
    {:ok, %Response{body: %{"order" => cancelled}}} = PrintApi.get_order(api, o["id"])

    assert {cancelled["status"], cancelled["cancellationReason"]} ==
             {"cancelled", "Pedido duplicado"}
  end
end

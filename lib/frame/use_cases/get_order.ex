defmodule Frame.UseCases.GetOrder do
  @moduledoc "The `getOrder` use case — one order with its jobs and current quote."

  alias Frame.Adapters.PrintApi
  alias Frame.UseCases.UpstreamCall

  @doc "Reads an order by id (a validated UUID)."
  @spec get_order(UpstreamCall.deps(), String.t()) ::
          {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def get_order(deps, order_id) do
    UpstreamCall.run(deps, "getOrder", %{"order.id": order_id}, fn ->
      PrintApi.get_order(deps.print_api, order_id)
    end)
  end
end

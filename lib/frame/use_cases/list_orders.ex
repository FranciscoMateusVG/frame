defmodule Frame.UseCases.ListOrders do
  @moduledoc "The `listOrders` use case — the supplier's queue (GET /orders)."

  alias Frame.Adapters.PrintApi
  alias Frame.UseCases.UpstreamCall

  @doc "Lists orders with validated filters (`Frame.Domain.Requests.list_query/1`)."
  @spec list_orders(UpstreamCall.deps(), PrintApi.list_query()) ::
          {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def list_orders(deps, query) do
    attributes = %{
      "orders.status_filter": query[:status] || "all",
      "orders.limit": query[:limit] || 20
    }

    UpstreamCall.run(deps, "listOrders", attributes, fn ->
      PrintApi.list_orders(deps.print_api, query)
    end)
  end
end

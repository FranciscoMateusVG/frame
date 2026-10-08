defmodule Frame.UseCases.MarkPrinted do
  @moduledoc """
  The `markPrinted` use case — the supplier confirms printing of the exact
  approved quote of the exact revision ("Marcar como impresso").
  """

  alias Frame.Adapters.PrintApi
  alias Frame.Observability.Logger
  alias Frame.UseCases.UpstreamCall

  @doc "Marks an order printed, conditional on `pre` (If-Match + Idempotency-Key)."
  @spec mark_printed(
          UpstreamCall.deps(),
          String.t(),
          %{revision: pos_integer(), quote_id: String.t()},
          PrintApi.preconditions()
        ) :: {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def mark_printed(deps, order_id, input, pre) do
    attributes = %{"order.id": order_id, "order.revision": input.revision}

    with {:ok, response} <-
           UpstreamCall.run(deps, "markPrinted", attributes, fn ->
             PrintApi.mark_printed(deps.print_api, order_id, input, pre)
           end) do
      if response.status == 200 and not response.replayed,
        do: Logger.info(deps.observability.logger, "order.printed", %{orderId: order_id})

      {:ok, response}
    end
  end
end

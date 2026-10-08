defmodule Frame.UseCases.CollectFiles do
  @moduledoc """
  The `collectFiles` use case — the supplier declares the files of the
  current revision collected ("Arquivos retirados"). A download never does
  this by itself (spec §7.5).
  """

  alias Frame.Adapters.PrintApi
  alias Frame.Observability.Logger
  alias Frame.UseCases.UpstreamCall

  @doc "Confirms collection of `revision`, conditional on `pre` (If-Match + Idempotency-Key)."
  @spec collect_files(
          UpstreamCall.deps(),
          String.t(),
          %{revision: pos_integer()},
          PrintApi.preconditions()
        ) ::
          {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def collect_files(deps, order_id, input, pre) do
    attributes = %{"order.id": order_id, "order.revision": input.revision}

    with {:ok, response} <-
           UpstreamCall.run(deps, "collectFiles", attributes, fn ->
             PrintApi.collect(deps.print_api, order_id, input, pre)
           end) do
      if response.status == 200 and not response.replayed,
        do: Logger.info(deps.observability.logger, "order.files_collected", %{orderId: order_id})

      {:ok, response}
    end
  end
end

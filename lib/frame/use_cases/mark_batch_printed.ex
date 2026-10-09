defmodule Frame.UseCases.MarkBatchPrinted do
  @moduledoc """
  The `markBatchPrinted` use case — the supplier confirms the whole batch
  printed, against its approved quote. Receipt is Financeiro's, not here.
  """

  alias Frame.Adapters.PrintApi
  alias Frame.Observability.Logger
  alias Frame.UseCases.UpstreamCall

  @doc "Marks the batch printed, conditional on `pre` (If-Match + Idempotency-Key)."
  @spec mark_batch_printed(
          UpstreamCall.deps(),
          String.t(),
          %{quote_id: String.t()},
          PrintApi.preconditions()
        ) ::
          {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def mark_batch_printed(deps, batch_id, input, pre) do
    with {:ok, response} <-
           UpstreamCall.run(deps, "markBatchPrinted", %{"batch.id": batch_id}, fn ->
             PrintApi.mark_batch_printed(deps.print_api, batch_id, input, pre)
           end) do
      if response.status == 200 and not response.replayed,
        do: Logger.info(deps.observability.logger, "batch.printed", %{batchId: batch_id})

      {:ok, response}
    end
  end
end

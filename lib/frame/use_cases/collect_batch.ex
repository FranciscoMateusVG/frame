defmodule Frame.UseCases.CollectBatch do
  @moduledoc """
  The `collectBatch` use case — the supplier declares every file of the
  batch collected ("Retirei os arquivos"), freezing exactly the membership
  they saw (If-Match = its ETag). A download never does this by itself.
  """

  alias Frame.Adapters.PrintApi
  alias Frame.Observability.Logger
  alias Frame.UseCases.UpstreamCall

  @doc "Confirms collection, conditional on `pre` (If-Match + Idempotency-Key)."
  @spec collect_batch(UpstreamCall.deps(), String.t(), PrintApi.preconditions()) ::
          {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def collect_batch(deps, batch_id, pre) do
    with {:ok, response} <-
           UpstreamCall.run(deps, "collectBatch", %{"batch.id": batch_id}, fn ->
             PrintApi.collect_batch(deps.print_api, batch_id, pre)
           end) do
      if response.status == 200 and not response.replayed,
        do: Logger.info(deps.observability.logger, "batch.files_collected", %{batchId: batch_id})

      {:ok, response}
    end
  end
end

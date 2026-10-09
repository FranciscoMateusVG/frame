defmodule Frame.UseCases.GetBatch do
  @moduledoc "The `getBatch` use case — one batch (current or history) with its items and quote."

  alias Frame.Adapters.PrintApi
  alias Frame.UseCases.UpstreamCall

  @doc "Reads a batch by id (a validated UUID)."
  @spec get_batch(UpstreamCall.deps(), String.t()) ::
          {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def get_batch(deps, batch_id) do
    UpstreamCall.run(deps, "getBatch", %{"batch.id": batch_id}, fn ->
      PrintApi.get_batch(deps.print_api, batch_id)
    end)
  end
end

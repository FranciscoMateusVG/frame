defmodule Frame.UseCases.GetCurrentBatch do
  @moduledoc """
  The `getCurrentBatch` use case — the supplier's current batch (open, or
  active from collection until printed), or none (`GET /batches/open`).
  Reading never collects or creates a batch.
  """

  alias Frame.Adapters.PrintApi
  alias Frame.UseCases.UpstreamCall

  @doc "Reads the current batch (`{\"batch\": null}` when there is none)."
  @spec get_current_batch(UpstreamCall.deps()) ::
          {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def get_current_batch(deps) do
    UpstreamCall.run(deps, "getCurrentBatch", %{}, fn ->
      PrintApi.get_open_batch(deps.print_api)
    end)
  end
end

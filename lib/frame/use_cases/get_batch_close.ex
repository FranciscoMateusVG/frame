defmodule Frame.UseCases.GetBatchClose do
  @moduledoc """
  The `getBatchClose` use case — the supplier's v2 monthly close for one
  competence (approved batch quotes once, plus historical individual charges).
  """

  alias Frame.Adapters.PrintApi
  alias Frame.UseCases.UpstreamCall

  @doc "Reads the v2 close of `competence` (`YYYY-MM`, validated)."
  @spec get_batch_close(UpstreamCall.deps(), String.t()) ::
          {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def get_batch_close(deps, competence) do
    UpstreamCall.run(deps, "getBatchClose", %{"close.competence": competence}, fn ->
      PrintApi.get_batch_close(deps.print_api, competence)
    end)
  end
end

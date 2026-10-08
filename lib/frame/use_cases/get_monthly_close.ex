defmodule Frame.UseCases.GetMonthlyClose do
  @moduledoc "The `getMonthlyClose` use case — the supplier's close for one competence."

  alias Frame.Adapters.PrintApi
  alias Frame.UseCases.UpstreamCall

  @doc "Reads the close of `competence` (`YYYY-MM`, validated)."
  @spec get_monthly_close(UpstreamCall.deps(), String.t()) ::
          {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def get_monthly_close(deps, competence) do
    UpstreamCall.run(deps, "getMonthlyClose", %{"close.competence": competence}, fn ->
      PrintApi.get_close(deps.print_api, competence)
    end)
  end
end

defmodule Frame.UseCases.SubmitInvoice do
  @moduledoc """
  The `submitInvoice` use case — the supplier sends the monthly NF (declared
  total + one document) as a proposal for Financeiro to check. It never
  changes accounting totals by itself (spec §3.5).
  """

  alias Frame.Adapters.PrintApi
  alias Frame.Errors.PortalError
  alias Frame.Observability.Logger
  alias Frame.UseCases.SubmitQuote
  alias Frame.UseCases.UpstreamCall

  @type input :: %{declared_total_cents: pos_integer(), file: %{name: String.t(), bytes: binary()}}

  @doc "Submits the invoice of `competence`, conditional on `pre` (If-Match + Idempotency-Key)."
  @spec submit_invoice(UpstreamCall.deps(), String.t(), input(), PrintApi.preconditions()) ::
          {:ok, PrintApi.Response.t()} | {:error, PortalError.t()}
  def submit_invoice(deps, competence, input, pre) do
    attributes = %{"close.competence": competence, "document.bytes": byte_size(input.file.bytes)}

    with {:ok, response} <-
           UpstreamCall.run(deps, "submitInvoice", attributes, fn ->
             send_invoice(deps, competence, input, pre)
           end) do
      if response.status == 201 and not response.replayed,
        do: Logger.info(deps.observability.logger, "invoice.submitted", %{competence: competence})

      {:ok, response}
    end
  end

  defp send_invoice(deps, competence, input, pre) do
    with {:ok, upload} <- SubmitQuote.upload(input.file) do
      PrintApi.submit_invoice(deps.print_api, competence, %{input | file: upload}, pre)
    end
  end
end

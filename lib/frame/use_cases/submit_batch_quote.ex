defmodule Frame.UseCases.SubmitBatchQuote do
  @moduledoc """
  The `submitBatchQuote` use case — the supplier sends one quote (total
  amount + one document) for the whole batch. The upstream detects the
  type, transcodes images and is the authority on the document.
  """

  alias Frame.Adapters.PrintApi
  alias Frame.Errors.PortalError
  alias Frame.Observability.Logger
  alias Frame.UseCases.SubmitQuote
  alias Frame.UseCases.UpstreamCall

  @type input :: %{amount_cents: pos_integer(), file: %{name: String.t(), bytes: binary()}}

  @doc "Submits the batch quote, conditional on `pre` (If-Match + Idempotency-Key)."
  @spec submit_batch_quote(UpstreamCall.deps(), String.t(), input(), PrintApi.preconditions()) ::
          {:ok, PrintApi.Response.t()} | {:error, PortalError.t()}
  def submit_batch_quote(deps, batch_id, input, pre) do
    attributes = %{"batch.id": batch_id, "document.bytes": byte_size(input.file.bytes)}

    with {:ok, response} <-
           UpstreamCall.run(deps, "submitBatchQuote", attributes, fn ->
             send_quote(deps, batch_id, input, pre)
           end) do
      if response.status == 201 and not response.replayed,
        do: Logger.info(deps.observability.logger, "batch.quote_submitted", %{batchId: batch_id})

      {:ok, response}
    end
  end

  defp send_quote(deps, batch_id, input, pre) do
    with {:ok, upload} <- SubmitQuote.upload(input.file) do
      PrintApi.submit_batch_quote(deps.print_api, batch_id, %{input | file: upload}, pre)
    end
  end
end

defmodule Frame.UseCases.SubmitQuote do
  @moduledoc """
  The `submitQuote` use case — the supplier sends a quote (amount + one
  document) for the current order revision. The upstream detects the type,
  transcodes images and is the authority on the document.
  """

  alias Frame.Adapters.PrintApi
  alias Frame.Domain.Document
  alias Frame.Errors.PortalError
  alias Frame.Observability.Logger
  alias Frame.UseCases.UpstreamCall

  @type input :: %{
          amount_cents: pos_integer(),
          order_revision: pos_integer(),
          file: %{name: String.t(), bytes: binary()}
        }

  @doc "Submits a quote, conditional on `pre` (If-Match + Idempotency-Key)."
  @spec submit_quote(UpstreamCall.deps(), String.t(), input(), PrintApi.preconditions()) ::
          {:ok, PrintApi.Response.t()} | {:error, PortalError.t()}
  def submit_quote(deps, order_id, input, pre) do
    attributes = %{
      "order.id": order_id,
      "order.revision": input.order_revision,
      "document.bytes": byte_size(input.file.bytes)
    }

    with {:ok, response} <-
           UpstreamCall.run(deps, "submitQuote", attributes, fn ->
             send_quote(deps, order_id, input, pre)
           end) do
      if response.status == 201 and not response.replayed,
        do: Logger.info(deps.observability.logger, "order.quote_submitted", %{orderId: order_id})

      {:ok, response}
    end
  end

  defp send_quote(deps, order_id, input, pre) do
    with {:ok, upload} <- upload(input.file) do
      PrintApi.submit_quote(deps.print_api, order_id, %{input | file: upload}, pre)
    end
  end

  @doc """
  Prepares the document for the upstream. Only the size cap is enforced
  here (the upstream rejects an oversized file before anything else); an
  empty or unsupported file is left to the upstream, which answers it
  after authorization and preconditions — same codes, same order.
  The declared type is the one detected from the bytes.
  """
  @spec upload(%{name: String.t(), bytes: binary()}) ::
          {:ok, PrintApi.upload()} | {:error, PortalError.t()}
  def upload(file) do
    if byte_size(file.bytes) > Document.max_bytes() do
      {:error, PortalError.exception(:file_too_large)}
    else
      mime =
        case Document.detect_mime(file.bytes) do
          {:ok, mime} -> mime
          :error -> "application/octet-stream"
        end

      {:ok, %{name: Document.sanitize_name(file.name), content_type: mime, bytes: file.bytes}}
    end
  end
end

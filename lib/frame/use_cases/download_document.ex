defmodule Frame.UseCases.DownloadDocument do
  @moduledoc """
  The `downloadDocument` use case — streams a print file, the current quote
  document or the current invoice proposal from the upstream to a sink
  (the HTTP response), without keeping a copy. Never changes order state.
  """

  alias Frame.Adapters.PrintApi
  alias Frame.Errors.PortalError
  alias Frame.Observability.Logger
  alias Frame.UseCases.UpstreamCall

  @type result(acc) ::
          {:streamed, acc}
          | {:ok, PrintApi.Response.t()}
          | {:error, PortalError.t()}
          | {:error, :interrupted, acc}

  @doc """
  Streams `target` into `sink` (see `Frame.Adapters.PrintApi.sink/1`).
  Returns `{:streamed, acc}` on success, the upstream's error answer as
  `{:ok, response}` (e.g. 404), or a typed failure.
  """
  @spec download_document(UpstreamCall.deps(), PrintApi.target(), acc, PrintApi.sink(acc)) ::
          result(acc)
        when acc: term()
  def download_document(deps, target, acc, sink) do
    attributes = %{"document.kind": target |> elem(0) |> Atom.to_string()}

    :otel_tracer.with_span(
      deps.observability.tracer,
      "downloadDocument",
      %{attributes: attributes},
      fn span ->
        case PrintApi.download(deps.print_api, target, acc, sink) do
          {:streamed, _acc} = ok ->
            OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:ok))
            ok

          {:ok, %PrintApi.Response{status: status}} when status in [401, 403] or status >= 500 ->
            Logger.error(deps.observability.logger, "upstream.refused", %{
              operation: "downloadDocument",
              status: status
            })

            UpstreamCall.fail(span, PortalError.exception(:upstream_unavailable))

          {:ok, %PrintApi.Response{}} = relayed ->
            relayed

          {:error, :unavailable} ->
            Logger.warn(deps.observability.logger, "upstream.unavailable", %{
              operation: "downloadDocument"
            })

            UpstreamCall.fail(span, PortalError.exception(:upstream_unavailable))

          {:error, :interrupted, _acc} = interrupted ->
            Logger.warn(deps.observability.logger, "download.interrupted", %{})
            OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, "interrupted"))
            interrupted
        end
      end
    )
  end
end

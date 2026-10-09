defmodule Frame.UseCases.ListBatches do
  @moduledoc "The `listBatches` use case — every batch of the supplier, history included."

  alias Frame.Adapters.PrintApi
  alias Frame.UseCases.UpstreamCall

  @doc "Lists batches with validated filters (`Frame.Domain.Requests.list_query/1`)."
  @spec list_batches(UpstreamCall.deps(), PrintApi.list_query()) ::
          {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def list_batches(deps, query) do
    attributes = %{
      "batches.status_filter": query[:status] || "all",
      "batches.limit": query[:limit] || 20
    }

    UpstreamCall.run(deps, "listBatches", attributes, fn ->
      PrintApi.list_batches(deps.print_api, query)
    end)
  end
end

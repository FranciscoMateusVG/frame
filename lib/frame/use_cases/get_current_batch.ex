defmodule Frame.UseCases.GetCurrentBatch do
  @moduledoc """
  The `getCurrentBatch` use case — the supplier's current batch: the open
  one (`GET /batches/open`), or, since `/open` is null while a collected…
  printed batch is active, that active batch, found in the history
  (`GET /batches`, every page) and read with its ETag (`GET /batches/:id`).
  `{"batch": null}` when there is neither. Reading never collects or
  creates a batch.
  """

  alias Frame.Adapters.PrintApi
  alias Frame.Adapters.PrintApi.Response
  alias Frame.Domain.Batch
  alias Frame.UseCases.UpstreamCall

  @page_limit 100
  @max_pages 50

  @doc "Reads the current batch (`{\"batch\": null}` when there is none)."
  @spec get_current_batch(UpstreamCall.deps()) ::
          {:ok, PrintApi.Response.t()} | {:error, Frame.Errors.PortalError.t()}
  def get_current_batch(deps) do
    UpstreamCall.run(deps, "getCurrentBatch", %{}, fn ->
      case PrintApi.get_open_batch(deps.print_api) do
        {:ok, %Response{status: 200, body: %{"batch" => nil}} = none} -> active(deps, none)
        other -> other
      end
    end)
  end

  defp active(deps, none) do
    case find_active(deps.print_api, nil, @max_pages) do
      {:ok, nil} -> {:ok, none}
      {:ok, id} -> PrintApi.get_batch(deps.print_api, id)
      other -> other
    end
  end

  defp find_active(_api, _cursor, 0), do: {:error, :unavailable}

  defp find_active(api, cursor, pages_left) do
    query = if cursor, do: %{limit: @page_limit, cursor: cursor}, else: %{limit: @page_limit}

    case PrintApi.list_batches(api, query) do
      {:ok, %Response{status: 200, body: %{"items" => items, "nextCursor" => next}}} ->
        case {Enum.find(items, &Batch.active?/1), next} do
          {%{"id" => id}, _next} -> {:ok, id}
          {nil, nil} -> {:ok, nil}
          {nil, next} -> find_active(api, next, pages_left - 1)
        end

      other ->
        other
    end
  end
end

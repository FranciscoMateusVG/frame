defmodule Frame.Domain.Batch do
  @moduledoc """
  The supplier-visible print batch (lote) of the v2 contract: the whole set
  of requests going to the print shop together, as the upstream DTO
  describes it (decoded JSON maps, camelCase string keys). Hono is the
  only authority on state; these pure functions decide what the batch
  screen *offers*. The upstream re-checks every command, so a hidden button
  is never the only guard.
  """

  @labels %{
    "open" => "Pronto para retirada",
    "files_collected" => "Arquivos retirados",
    "quote_pending" => "Aguardando aprovação do Financeiro",
    "quote_rejected" => "Orçamento rejeitado",
    "quote_approved" => "Orçamento aprovado",
    "printed" => "Impresso",
    "received" => "Recebido",
    "cancelled" => "Cancelado"
  }

  @steps [
    {"open", "Pronto"},
    {"files_collected", "Arquivos retirados"},
    {"quote_pending", "Orçamento enviado"},
    {"quote_approved", "Orçamento aprovado"},
    {"printed", "Impresso"}
  ]

  @typedoc "What the supplier can do next with the batch."
  @type action ::
          :collect | :quote | :requote | :await_decision | :print | :await_receipt | :none

  @typedoc "One file card of a request: a paired job, or a residual (unpaired) file."
  @type card :: {:job, map()} | {:residual, map()}

  @doc "Portuguese label of a batch status (unknown values are shown as-is)."
  @spec status_label(String.t()) :: String.t()
  def status_label(status), do: Map.get(@labels, status, status)

  @doc "The next supplier action the screen should offer."
  @spec next_action(map()) :: action()
  def next_action(%{"status" => "open", "items" => [_ | _]}), do: :collect
  def next_action(%{"status" => "files_collected"}), do: :quote
  def next_action(%{"status" => "quote_rejected"}), do: :requote
  def next_action(%{"status" => "quote_pending"}), do: :await_decision

  def next_action(%{"status" => "quote_approved", "currentQuote" => %{"decision" => "approved"}}),
    do: :print

  def next_action(%{"status" => "printed"}), do: :await_receipt
  def next_action(_batch), do: :none

  @doc "The ETag the upstream issues for a batch (`\"<id>:<version>\"`)."
  @spec etag(map()) :: String.t()
  def etag(%{"id" => id, "version" => version}), do: ~s("#{id}:#{version}")

  @doc "Sum of copies across every job of the batch (residual files have none)."
  @spec total_copies(map()) :: non_neg_integer()
  def total_copies(%{"items" => items}) do
    for item <- items, job <- item["jobs"], reduce: 0, do: (sum -> sum + job["copies"])
  end

  @doc "Number of file cards in the batch."
  @spec file_count(map()) :: non_neg_integer()
  def file_count(%{"items" => items}), do: Enum.sum_by(items, &length(cards(&1)))

  @doc """
  The file cards of one request, in contract order: its jobs first, then
  the residual files of its general instructions — each file exactly once.
  """
  @spec cards(map()) :: [card()]
  def cards(item) do
    Enum.map(item["jobs"], &{:job, &1}) ++
      Enum.map(get_in(item, ["generalInstructions", "files"]) || [], &{:residual, &1})
  end

  @doc "The progress track: `[{label, :done | :current | :todo}]`."
  @spec steps(map()) :: [{String.t(), :done | :current | :todo}]
  def steps(%{"status" => status}) do
    status = track_status(status)
    index = Enum.find_index(@steps, fn {s, _} -> s == status end)

    @steps
    |> Enum.with_index()
    |> Enum.map(fn {{_s, label}, i} ->
      cond do
        index == nil -> {label, :todo}
        i < index -> {label, :done}
        i == index and status == "printed" -> {label, :done}
        i == index -> {label, :current}
        true -> {label, :todo}
      end
    end)
  end

  # A rejection waits on a new quote; a received batch has every step done.
  defp track_status("quote_rejected"), do: "quote_pending"
  defp track_status("received"), do: "printed"
  defp track_status(status), do: status
end

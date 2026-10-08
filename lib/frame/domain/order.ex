defmodule Frame.Domain.Order do
  @moduledoc """
  The supplier-visible print order (spec §3.4, §4.2), as the upstream DTO
  describes it: decoded JSON maps with the contract's camelCase string
  keys. Hono is the only authority on state; these pure functions decide
  what the portal *offers* on screen. The upstream re-checks every command,
  so a hidden button is never the only guard.
  """

  @statuses ~w(ready files_collected quote_pending quote_rejected quote_approved printed cancelled)

  @labels %{
    "ready" => "Pronto para retirada",
    "files_collected" => "Arquivos retirados",
    "quote_pending" => "Aguardando aprovação do Financeiro",
    "quote_rejected" => "Orçamento rejeitado",
    "quote_approved" => "Orçamento aprovado",
    "printed" => "Impresso",
    "cancelled" => "Cancelado"
  }

  @typedoc "One of the seven public statuses."
  @type status :: String.t()

  @typedoc "What the supplier can do next with an order."
  @type action :: :collect | :quote | :await_decision | :requote | :print | :none

  @doc "The public statuses, in workflow order."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "True for one of the public statuses."
  @spec status?(term()) :: boolean()
  def status?(value), do: value in @statuses

  @doc "Portuguese label of a status (unknown values are shown as-is)."
  @spec status_label(String.t()) :: String.t()
  def status_label(status), do: Map.get(@labels, status, status)

  @doc "The next supplier action the screen should offer."
  @spec next_action(map()) :: action()
  def next_action(%{"status" => "ready"}), do: :collect
  def next_action(%{"status" => "files_collected"}), do: :quote
  def next_action(%{"status" => "quote_pending"}), do: :await_decision
  def next_action(%{"status" => "quote_rejected"}), do: :requote

  def next_action(%{"status" => "quote_approved", "currentQuote" => %{"decision" => "approved"}}),
    do: :print

  def next_action(_order), do: :none

  @doc "The ETag the upstream issues for an order (`\"<id>:<version>\"`)."
  @spec etag(map()) :: String.t()
  def etag(%{"id" => id, "version" => version}), do: ~s("#{id}:#{version}")

  @doc "Sum of copies across the jobs of an order."
  @spec total_copies(map()) :: non_neg_integer()
  def total_copies(%{"jobs" => jobs}) when is_list(jobs),
    do: Enum.reduce(jobs, 0, &(&1["copies"] + &2))

  def total_copies(_order), do: 0
end

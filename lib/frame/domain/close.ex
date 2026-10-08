defmodule Frame.Domain.Close do
  @moduledoc """
  The supplier's monthly close (spec §3.5, frozen PR C contract): decoded
  `Close` DTO maps. Hono decides; these functions only decide what the
  "Notas fiscais" screen offers.
  """

  @labels %{
    "open" => "Aberto",
    "submitted" => "Aguardando conferência",
    "rejected" => "NF rejeitada",
    "accepted" => "NF aceita"
  }

  @doc "Portuguese label of a close state."
  @spec state_label(String.t()) :: String.t()
  def state_label(state), do: Map.get(@labels, state, state)

  @doc """
  Why the invoice form is not offered, or `:ok` when it is: the period has
  ended, there are items, and the close is `open` or `rejected`.
  """
  @spec submission(map()) :: :ok | :period_open | :empty | :already_submitted | :accepted
  def submission(%{"periodClosed" => false}), do: :period_open
  def submission(%{"items" => []}), do: :empty
  def submission(%{"state" => "submitted"}), do: :already_submitted
  def submission(%{"state" => "accepted"}), do: :accepted
  def submission(%{"state" => state}) when state in ["open", "rejected"], do: :ok

  @doc "True when the declared total differs from the calculated one."
  @spec divergent?(map()) :: boolean()
  def divergent?(%{"declaredTotalCents" => nil}), do: false
  def divergent?(%{"declaredTotalCents" => d, "expectedTotalCents" => e}), do: d != e

  @doc "The ETag the upstream issues for a close (virtual closes included)."
  @spec etag(map()) :: String.t()
  def etag(%{"id" => nil, "competence" => competence}), do: ~s("month:#{competence}:0")
  def etag(%{"id" => id, "version" => version}), do: ~s("#{id}:#{version}")
end

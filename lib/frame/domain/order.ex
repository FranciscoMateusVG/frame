defmodule Frame.Domain.Order do
  @moduledoc """
  The supplier-visible print order of the v1 contract (spec §3.4, §4.2).
  The pages work on batches (`Frame.Domain.Batch`); orders remain only
  behind the `/api/print/v1` JSON routes, whose list filter accepts the
  seven public statuses.
  """

  @statuses ~w(ready files_collected quote_pending quote_rejected quote_approved printed cancelled)

  @typedoc "One of the seven public statuses."
  @type status :: String.t()

  @doc "The public statuses, in workflow order."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "True for one of the public statuses."
  @spec status?(term()) :: boolean()
  def status?(value), do: value in @statuses
end

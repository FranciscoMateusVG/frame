defmodule Frame.Errors.InvalidCatNameError do
  @moduledoc """
  Returned when create-cat input fails validation — including a malformed ID
  (the name is historical; it mirrors the reference contract).
  """

  defexception [:reason, :message, code: "INVALID_CAT_NAME"]

  @type t :: %__MODULE__{reason: String.t(), message: String.t(), code: String.t()}

  @impl true
  def exception(reason) when is_binary(reason) do
    %__MODULE__{reason: reason, message: "Invalid cat name: #{reason}"}
  end
end

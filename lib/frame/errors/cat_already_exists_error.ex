defmodule Frame.Errors.CatAlreadyExistsError do
  @moduledoc "Raised (returned) when a cat with the same name already exists."

  alias Frame.Domain.Cat

  defexception [:name, :message, code: "CAT_ALREADY_EXISTS"]

  @type t :: %__MODULE__{name: Cat.name(), message: String.t(), code: String.t()}

  @impl true
  def exception(name) when is_binary(name) do
    %__MODULE__{name: name, message: ~s(A cat with the name "#{name}" already exists.)}
  end
end

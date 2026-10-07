defmodule Frame.Adapters.CatRepository do
  @moduledoc """
  CatRepository — the port (behaviour) for cat persistence.

  An implementation is a struct whose module implements this behaviour
  (e.g. `Frame.Adapters.CatRepository.Postgres`). Callers hold the struct
  and go through the dispatch functions below, so use cases depend only on
  this port, never on a concrete adapter.
  """

  alias Frame.Domain.Cat
  alias Frame.Errors.CatAlreadyExistsError

  @typedoc "Any struct whose module implements this behaviour."
  @type t :: struct()

  @doc "Save a new cat. Fails if a cat with the same name already exists."
  @callback save(t(), Cat.t()) :: :ok | {:error, CatAlreadyExistsError.t()}

  @doc "Find a cat by its ID. Returns nil if not found."
  @callback find_by_id(t(), Cat.id()) :: Cat.t() | nil

  @doc "Find a cat by its name. Returns nil if not found."
  @callback find_by_name(t(), Cat.name()) :: Cat.t() | nil

  @doc "Delete a cat by its ID. Returns true if deleted, false if not found."
  @callback delete_by_id(t(), Cat.id()) :: boolean()

  @spec save(t(), Cat.t()) :: :ok | {:error, CatAlreadyExistsError.t()}
  def save(%impl{} = repo, %Cat{} = cat), do: impl.save(repo, cat)

  @spec find_by_id(t(), Cat.id()) :: Cat.t() | nil
  def find_by_id(%impl{} = repo, id), do: impl.find_by_id(repo, id)

  @spec find_by_name(t(), Cat.name()) :: Cat.t() | nil
  def find_by_name(%impl{} = repo, name), do: impl.find_by_name(repo, name)

  @spec delete_by_id(t(), Cat.id()) :: boolean()
  def delete_by_id(%impl{} = repo, id), do: impl.delete_by_id(repo, id)
end

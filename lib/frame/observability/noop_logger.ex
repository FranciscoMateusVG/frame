defmodule Frame.Observability.NoopLogger do
  @moduledoc """
  NoopLogger — does nothing.

  Use in tests and any context where logging output is undesirable.
  Zero overhead, zero side effects.
  """

  @behaviour Frame.Observability.Logger

  defstruct []

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl true
  def info(_logger, _message, _attrs), do: :ok

  @impl true
  def warn(_logger, _message, _attrs), do: :ok

  @impl true
  def error(_logger, _message, _attrs), do: :ok

  @impl true
  def debug(_logger, _message, _attrs), do: :ok
end

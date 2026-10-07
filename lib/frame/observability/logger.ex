defmodule Frame.Observability.Logger do
  @moduledoc """
  Logger port — Frame's logging behaviour.

  Three implementations ship with Frame:

    * `Frame.Observability.ConsoleLogger` — pretty stdout output for examples and local dev.
    * `Frame.Observability.NoopLogger` — silent, for tests and contexts where logging is undesirable.
    * `Frame.Observability.OtelLogger` — forwards to the OTel logs bridge with automatic trace correlation.

  A logger is any struct whose module implements this behaviour; consumers
  may implement their own to integrate with existing logging stacks. The
  `attrs` map carries structured context — keep values serializable.
  """

  @typedoc "Any struct whose module implements this behaviour."
  @type t :: struct()
  @type attrs :: %{optional(atom() | String.t()) => term()}

  @callback info(t(), String.t(), attrs()) :: :ok
  @callback warn(t(), String.t(), attrs()) :: :ok
  @callback error(t(), String.t(), attrs()) :: :ok
  @callback debug(t(), String.t(), attrs()) :: :ok

  @spec info(t(), String.t(), attrs()) :: :ok
  def info(%impl{} = logger, message, attrs \\ %{}), do: impl.info(logger, message, attrs)

  @spec warn(t(), String.t(), attrs()) :: :ok
  def warn(%impl{} = logger, message, attrs \\ %{}), do: impl.warn(logger, message, attrs)

  @spec error(t(), String.t(), attrs()) :: :ok
  def error(%impl{} = logger, message, attrs \\ %{}), do: impl.error(logger, message, attrs)

  @spec debug(t(), String.t(), attrs()) :: :ok
  def debug(%impl{} = logger, message, attrs \\ %{}), do: impl.debug(logger, message, attrs)
end

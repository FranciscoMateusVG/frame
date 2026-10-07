defmodule Frame.Observability.ConsoleLogger do
  @moduledoc """
  ConsoleLogger — pretty console output with timestamp, level, and structured attrs.

  Intended for examples and local development. Not suitable for production —
  use `Frame.Observability.OtelLogger` with a proper OTel SDK setup instead.

  Streams mirror the Node console: INFO and DEBUG go to stdout, WARN and
  ERROR go to stderr.
  """

  @behaviour Frame.Observability.Logger

  defstruct []

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @impl true
  def info(_logger, message, attrs), do: log(:stdio, "INFO", message, attrs)

  @impl true
  def warn(_logger, message, attrs), do: log(:stderr, "WARN", message, attrs)

  @impl true
  def error(_logger, message, attrs), do: log(:stderr, "ERROR", message, attrs)

  @impl true
  def debug(_logger, message, attrs), do: log(:stdio, "DEBUG", message, attrs)

  defp log(device, level, message, attrs) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    attrs_str = if map_size(attrs) > 0, do: " " <> JSON.encode!(attrs), else: ""
    IO.puts(device, "[#{timestamp}] #{String.pad_trailing(level, 5)} #{message}#{attrs_str}")
  end
end

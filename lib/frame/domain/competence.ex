defmodule Frame.Domain.Competence do
  @moduledoc """
  Billing competence — a `YYYY-MM` month in `America/Sao_Paulo` (spec §3.5).

  São Paulo has kept a fixed UTC−03:00 offset since daylight saving time was
  abolished in 2019, so the offset is a constant here instead of a
  time-zone database dependency. The upstream is the authority on whether a
  period is closed (`periodClosed` in the Close DTO); these helpers only
  pick the default month and explain the closing date on screen.
  """

  @offset_seconds -3 * 3600

  @enforce_keys [:year, :month]
  defstruct [:year, :month]

  @type t :: %__MODULE__{year: 2000..9999, month: 1..12}

  @doc "Parses `YYYY-MM` (boundary parser)."
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(<<y::binary-size(4), "-", m::binary-size(2)>>) do
    with true <- Regex.match?(~r/^\d{4}$/, y) and Regex.match?(~r/^\d{2}$/, m),
         year when year in 2000..9999 <- String.to_integer(y),
         month when month in 1..12 <- String.to_integer(m) do
      {:ok, %__MODULE__{year: year, month: month}}
    else
      _ -> :error
    end
  end

  def parse(_value), do: :error

  @doc "Renders as `YYYY-MM`."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{year: y, month: m}),
    do: "#{y}-#{m |> Integer.to_string() |> String.pad_leading(2, "0")}"

  @doc "Renders as `MM/YYYY` for people."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{year: y, month: m}),
    do: "#{m |> Integer.to_string() |> String.pad_leading(2, "0")}/#{y}"

  @doc "The competence that contains the given UTC instant, in São Paulo time."
  @spec containing(DateTime.t()) :: t()
  def containing(%DateTime{} = utc) do
    local = DateTime.add(utc, @offset_seconds, :second)
    %__MODULE__{year: local.year, month: local.month}
  end

  @doc "The competence after this one."
  @spec next(t()) :: t()
  def next(%__MODULE__{year: y, month: 12}), do: %__MODULE__{year: y + 1, month: 1}
  def next(%__MODULE__{year: y, month: m}), do: %__MODULE__{year: y, month: m + 1}

  @doc "The competence before this one."
  @spec previous(t()) :: t()
  def previous(%__MODULE__{year: y, month: 1}), do: %__MODULE__{year: y - 1, month: 12}
  def previous(%__MODULE__{year: y, month: m}), do: %__MODULE__{year: y, month: m - 1}

  @doc "The `count` most recent competences, newest first, starting at `from`."
  @spec recent(t(), pos_integer()) :: [t()]
  def recent(%__MODULE__{} = from, count) when count >= 1 do
    from |> Stream.iterate(&previous/1) |> Enum.take(count)
  end

  @doc """
  The local date (São Paulo) on which an invoice for this competence may be
  sent: the first day of the following month.
  """
  @spec opens_on(t()) :: Date.t()
  def opens_on(%__MODULE__{} = competence) do
    %__MODULE__{year: y, month: m} = next(competence)
    Date.new!(y, m, 1)
  end

  @doc "True while the São Paulo month of `competence` has not ended at `now`."
  @spec open?(t(), DateTime.t()) :: boolean()
  def open?(%__MODULE__{} = competence, %DateTime{} = now) do
    current = containing(now)
    {current.year, current.month} <= {competence.year, competence.month}
  end
end

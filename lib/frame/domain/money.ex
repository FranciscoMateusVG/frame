defmodule Frame.Domain.Money do
  @moduledoc """
  BRL money as integer cents — never floats (spec §4: integers in cents,
  maximum 2,147,483,647, overflow rejected).

  `parse_brl/1` is the boundary parser for what a person types in the
  "Valor" fields ("459", "459,90", "1.234,56", "R$ 1.234,56", "1234.56").
  `format_brl/1` renders cents for display.
  """

  @max_cents 2_147_483_647

  @typedoc "An amount in BRL cents, 1..2,147,483,647."
  @type cents :: pos_integer()

  @doc "The largest representable amount (Postgres `integer`)."
  @spec max_cents() :: cents()
  def max_cents, do: @max_cents

  @doc """
  Parses a typed BRL amount into cents. Accepts Brazilian grouping
  (`1.234,56`) and a plain decimal point when unambiguous (`1234.56`). At most
  two decimal places; zero, negatives and amounts above `max_cents/0` are
  rejected.
  """
  @spec parse_brl(term()) :: {:ok, cents()} | {:error, :invalid | :out_of_range}
  def parse_brl(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/^R\$\s*/u, "")
    |> String.replace(~r/[\s\x{00A0}]/u, "")
    |> split_amount()
    |> to_cents()
  end

  def parse_brl(_value), do: {:error, :invalid}

  # "1.234,56" / "1234,56" / "1234" / "1234.56" / "1.234"
  defp split_amount(text) do
    cond do
      Regex.match?(~r/^\d{1,3}(\.\d{3})+(,\d{1,2})?$/, text) ->
        [int | frac] = String.split(text, ",")
        {String.replace(int, ".", ""), List.first(frac, "")}

      Regex.match?(~r/^\d+(,\d{1,2})?$/, text) ->
        [int | frac] = String.split(text, ",")
        {int, List.first(frac, "")}

      Regex.match?(~r/^\d+\.\d{1,2}$/, text) ->
        [int, frac] = String.split(text, ".")
        {int, frac}

      true ->
        :invalid
    end
  end

  defp to_cents(:invalid), do: {:error, :invalid}

  defp to_cents({int, frac}) do
    cents = String.to_integer(int) * 100 + String.to_integer(String.pad_trailing(frac, 2, "0"))

    if cents >= 1 and cents <= @max_cents, do: {:ok, cents}, else: {:error, :out_of_range}
  end

  @doc """
  Parses the canonical decimal-string form the upstream accepts
  (`^[1-9][0-9]{0,9}$`, ≤ max) — used for multipart fields sent as cents.
  """
  @spec parse_cents_string(term()) :: {:ok, cents()} | :error
  def parse_cents_string(value) when is_binary(value) do
    if Regex.match?(~r/^[1-9][0-9]{0,9}$/, value) do
      n = String.to_integer(value)
      if n <= @max_cents, do: {:ok, n}, else: :error
    else
      :error
    end
  end

  def parse_cents_string(_value), do: :error

  @doc ~S'Formats cents as "R$ 1.234,56".'
  @spec format_brl(integer()) :: String.t()
  def format_brl(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs = abs(cents)
    reais = abs |> div(100) |> Integer.to_string() |> group_thousands()
    centavos = abs |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{sign}R$ #{reais},#{centavos}"
  end

  @doc ~S'Formats cents for an input field ("1234,56"), the inverse of `parse_brl/1`.'
  @spec format_input(integer()) :: String.t()
  def format_input(cents) when is_integer(cents) and cents >= 0 do
    "#{div(cents, 100)},#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp group_thousands(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(".", &Enum.join/1)
    |> String.reverse()
  end
end

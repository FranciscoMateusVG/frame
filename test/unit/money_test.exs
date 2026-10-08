defmodule Frame.Unit.MoneyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Frame.Domain.Money

  describe "parse_brl/1" do
    test "accepts the forms people type" do
      assert Money.parse_brl("459") == {:ok, 45_900}
      assert Money.parse_brl("459,9") == {:ok, 45_990}
      assert Money.parse_brl("459,90") == {:ok, 45_990}
      assert Money.parse_brl("1.234,56") == {:ok, 123_456}
      assert Money.parse_brl("R$ 1.234,56") == {:ok, 123_456}
      assert Money.parse_brl("  1234.56 ") == {:ok, 123_456}
      assert Money.parse_brl("1.234") == {:ok, 123_400}
      assert Money.parse_brl("0,01") == {:ok, 1}
    end

    test "rejects ambiguous, negative, zero and overflowing amounts" do
      assert Money.parse_brl("") == {:error, :invalid}
      assert Money.parse_brl("-5") == {:error, :invalid}
      assert Money.parse_brl("1,234") == {:error, :invalid}
      assert Money.parse_brl("1.2.3") == {:error, :invalid}
      assert Money.parse_brl("12,345") == {:error, :invalid}
      assert Money.parse_brl("abc") == {:error, :invalid}
      assert Money.parse_brl(12) == {:error, :invalid}
      assert Money.parse_brl("0") == {:error, :out_of_range}
      assert Money.parse_brl("21474836,48") == {:error, :out_of_range}
      assert Money.parse_brl("21474836,47") == {:ok, Money.max_cents()}
    end
  end

  test "parse_cents_string/1 mirrors the upstream canonical form" do
    assert Money.parse_cents_string("45900") == {:ok, 45_900}
    assert Money.parse_cents_string("2147483647") == {:ok, 2_147_483_647}
    assert Money.parse_cents_string("2147483648") == :error
    assert Money.parse_cents_string("0") == :error
    assert Money.parse_cents_string("045") == :error
    assert Money.parse_cents_string("4.5") == :error
    assert Money.parse_cents_string(45) == :error
  end

  test "format_brl/1 and format_input/1" do
    assert Money.format_brl(45_900) == "R$ 459,00"
    assert Money.format_brl(123_456_789) == "R$ 1.234.567,89"
    assert Money.format_brl(5) == "R$ 0,05"
    assert Money.format_brl(-150) == "-R$ 1,50"
    assert Money.format_input(123_456) == "1234,56"
  end

  property "format_input/1 round-trips through parse_brl/1" do
    check all(cents <- integer(1..Money.max_cents())) do
      assert Money.parse_brl(Money.format_input(cents)) == {:ok, cents}
      assert Money.parse_brl(Money.format_brl(cents)) == {:ok, cents}
    end
  end
end

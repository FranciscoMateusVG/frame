defmodule Frame.Unit.CompetenceTest do
  use ExUnit.Case, async: true

  alias Frame.Domain.Competence

  test "parse/1 accepts YYYY-MM only" do
    assert {:ok, %Competence{year: 2026, month: 9}} = Competence.parse("2026-09")

    for bad <- [
          "2026-9",
          "2026-13",
          "2026-00",
          "26-09",
          "abcd-ef",
          "1999-01",
          nil,
          202_609,
          "2026-09-01"
        ],
        do: assert(Competence.parse(bad) == :error)
  end

  test "rendering" do
    {:ok, c} = Competence.parse("2026-09")
    assert Competence.to_string(c) == "2026-09"
    assert Competence.label(c) == "09/2026"
    assert Competence.opens_on(c) == ~D[2026-10-01]
  end

  test "containing/1 uses São Paulo time (UTC−3)" do
    assert Competence.containing(~U[2026-10-01 02:59:59Z]) |> Competence.to_string() == "2026-09"
    assert Competence.containing(~U[2026-10-01 03:00:00Z]) |> Competence.to_string() == "2026-10"
  end

  test "next/previous/recent wrap years" do
    {:ok, jan} = Competence.parse("2026-01")
    {:ok, dec} = Competence.parse("2025-12")
    assert Competence.previous(jan) == dec
    assert Competence.next(dec) == jan

    assert Competence.recent(jan, 3) |> Enum.map(&Competence.to_string/1) == [
             "2026-01",
             "2025-12",
             "2025-11"
           ]
  end

  test "open?/2 is true until the São Paulo month ends" do
    {:ok, sep} = Competence.parse("2026-09")
    assert Competence.open?(sep, ~U[2026-09-30 23:00:00Z])
    assert Competence.open?(sep, ~U[2026-10-01 02:00:00Z])
    refute Competence.open?(sep, ~U[2026-10-01 03:00:00Z])
    {:ok, nov} = Competence.parse("2026-11")
    assert Competence.open?(nov, ~U[2026-10-15 12:00:00Z])
  end
end

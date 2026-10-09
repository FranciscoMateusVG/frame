defmodule Frame.Unit.OrderCloseTest do
  use ExUnit.Case, async: true

  alias Frame.Domain.Close
  alias Frame.Domain.Order

  test "the v1 order statuses (the JSON API's list filter)" do
    assert length(Order.statuses()) == 7
    assert Order.status?("ready")
    refute Order.status?("awaiting_readiness")
  end

  test "close submission rules" do
    base = %{"periodClosed" => true, "items" => [%{}], "state" => "open"}
    assert Close.submission(base) == :ok
    assert Close.submission(%{base | "state" => "rejected"}) == :ok
    assert Close.submission(%{base | "periodClosed" => false}) == :period_open
    assert Close.submission(%{base | "items" => []}) == :empty
    assert Close.submission(%{base | "state" => "submitted"}) == :already_submitted
    assert Close.submission(%{base | "state" => "accepted"}) == :accepted
  end

  test "close helpers" do
    assert Close.state_label("submitted") == "Aguardando conferência"
    assert Close.state_label("x") == "x"
    refute Close.divergent?(%{"declaredTotalCents" => nil})
    assert Close.divergent?(%{"declaredTotalCents" => 57_000, "expectedTotalCents" => 57_900})
    refute Close.divergent?(%{"declaredTotalCents" => 57_900, "expectedTotalCents" => 57_900})
    assert Close.etag(%{"id" => nil, "competence" => "2026-09"}) == ~s("month:2026-09:0")
    assert Close.etag(%{"id" => "c1", "version" => 4}) == ~s("c1:4")
  end
end

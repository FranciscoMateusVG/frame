defmodule Frame.Unit.OrderCloseTest do
  use ExUnit.Case, async: true

  alias Frame.Domain.Close
  alias Frame.Domain.Order

  test "statuses and labels" do
    assert length(Order.statuses()) == 7
    assert Order.status?("ready")
    refute Order.status?("awaiting_readiness")
    assert Order.status_label("quote_pending") == "Aguardando aprovação do Financeiro"
    assert Order.status_label("weird") == "weird"
  end

  test "next_action/1 follows the state machine" do
    assert Order.next_action(%{"status" => "ready"}) == :collect
    assert Order.next_action(%{"status" => "files_collected"}) == :quote
    assert Order.next_action(%{"status" => "quote_pending"}) == :await_decision
    assert Order.next_action(%{"status" => "quote_rejected"}) == :requote

    assert Order.next_action(%{
             "status" => "quote_approved",
             "currentQuote" => %{"decision" => "approved"}
           }) == :print

    # Approved status without an approved quote never offers printing.
    assert Order.next_action(%{
             "status" => "quote_approved",
             "currentQuote" => %{"decision" => "pending"}
           }) == :none

    assert Order.next_action(%{"status" => "printed"}) == :none
    assert Order.next_action(%{"status" => "cancelled"}) == :none
  end

  test "etag and copies" do
    assert Order.etag(%{"id" => "abc", "version" => 3}) == ~s("abc:3")
    assert Order.total_copies(%{"jobs" => [%{"copies" => 2}, %{"copies" => 7}]}) == 9
    assert Order.total_copies(%{}) == 0
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

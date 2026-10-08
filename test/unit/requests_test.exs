defmodule Frame.Unit.RequestsTest do
  use ExUnit.Case, async: true

  alias Frame.Domain.Requests

  @id "fbad2d0c-ca65-4a36-8f95-86813104b5e1"

  test "uuid/1 and if_match/1" do
    assert Requests.uuid(@id) == {:ok, @id}
    assert Requests.uuid("../x") == :error
    assert Requests.uuid(1) == :error
    assert Requests.if_match(~s("#{@id}:3")) == {:ok, ~s("#{@id}:3")}
    assert Requests.if_match(~s("month:2026-09:0")) == {:ok, ~s("month:2026-09:0")}
    assert Requests.if_match("W/\"x\"") == :error
    assert Requests.if_match(nil) == :error
  end

  test "login/1 requires exactly {password}" do
    assert Requests.login(%{"password" => "x"}) == {:ok, "x"}
    assert Requests.login(%{"password" => "x", "role" => "admin"}) == :error
    assert Requests.login(%{"password" => 1}) == :error
    assert Requests.login(%{"password" => ""}) == :error
    assert Requests.login([]) == :error
  end

  test "collected/1 and printed/1 reject unknown fields and non-integers" do
    assert Requests.collected(%{"revision" => 1}) == {:ok, %{revision: 1}}
    assert Requests.collected(%{"revision" => "1"}) == :error
    assert Requests.collected(%{"revision" => 1.0}) == :error
    assert Requests.collected(%{"revision" => 0}) == :error
    assert Requests.collected(%{"revision" => 1, "x" => 1}) == :error
    assert Requests.collected(nil) == :error

    assert Requests.printed(%{"revision" => 2, "quoteId" => @id}) ==
             {:ok, %{revision: 2, quote_id: @id}}

    assert Requests.printed(%{"revision" => 2, "quoteId" => "nope"}) == :error
    assert Requests.printed(%{"revision" => 2}) == :error
  end

  test "list_query/1" do
    assert Requests.list_query(%{}) == {:ok, %{}}
    assert Requests.list_query(%{"status" => "", "x" => "y"}) == {:ok, %{}}

    assert Requests.list_query(%{"status" => "ready", "limit" => "100", "cursor" => "abc"}) ==
             {:ok, %{status: "ready", limit: 100, cursor: "abc"}}

    assert Requests.list_query(%{"status" => "awaiting_readiness"}) == :error
    assert Requests.list_query(%{"limit" => "101"}) == :error
    assert Requests.list_query(%{"limit" => "0"}) == :error
    assert Requests.list_query(%{"limit" => "05"}) == :error
    assert Requests.list_query(%{"cursor" => String.duplicate("a", 513)}) == :error
    assert Requests.list_query(%{"cursor" => ["a"]}) == :error
  end

  test "multipart fields are exact" do
    assert Requests.quote_fields(%{"amountCents" => "45900", "orderRevision" => "1"}) ==
             {:ok, %{amount_cents: 45_900, order_revision: 1}}

    assert Requests.quote_fields(%{"amountCents" => "45900", "orderRevision" => "1", "x" => "1"}) ==
             :error

    assert Requests.quote_fields(%{"amountCents" => "0", "orderRevision" => "1"}) == :error
    assert Requests.quote_fields(%{"amountCents" => "1", "orderRevision" => "01"}) == :error

    assert Requests.invoice_fields(%{"declaredTotalCents" => "57900"}) ==
             {:ok, %{declared_total_cents: 57_900}}

    assert Requests.invoice_fields(%{"declaredTotalCents" => "x"}) == :error
    assert Requests.invoice_fields(%{}) == :error
    assert Requests.revision_string(nil) == :error
  end
end

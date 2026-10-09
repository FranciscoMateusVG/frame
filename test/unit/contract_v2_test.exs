defmodule Frame.Unit.ContractV2Test do
  @moduledoc "The validator against the frozen v2 batch fixture and schema (monorepo-incluir PR #1053)."
  use ExUnit.Case, async: true

  alias Frame.Domain.Close
  alias Frame.Domain.Contract
  alias Frame.Test.BatchFixture

  @fixtures Path.expand("../fixtures", __DIR__)

  defp schema,
    do: @fixtures |> Path.join("print-portal-v2.schema.json") |> File.read!() |> JSON.decode!()

  test "every frozen batch snapshot validates, as a batch and as the open batch" do
    f = BatchFixture.fixture()

    for batch <- f["batches"] ++ [BatchFixture.rebatched(), BatchFixture.next_batch()] do
      assert Contract.validate(:batch_response, %{"batch" => batch}) == :ok, batch["status"]
      assert Contract.validate(:open_batch_response, %{"batch" => batch}) == :ok
    end

    assert Contract.validate(:open_batch_response, %{"batch" => nil}) == :ok
    assert {:error, _} = Contract.validate(:batch_response, %{"batch" => nil})
  end

  test "the frozen mixed monthly close validates and its ETag is derivable" do
    close = BatchFixture.monthly_close()
    assert Contract.validate(:batch_close_response, %{"close" => close}) == :ok
    assert Close.etag(close) == ~s("#{close["id"]}:#{close["version"]}")
  end

  test "batch summaries validate in a list response" do
    summaries =
      for b <- BatchFixture.fixture()["batches"],
          do: Map.drop(b, ["items", "currentQuote", "cancellationReason"])

    assert Contract.validate(:batch_list_response, %{"items" => summaries, "nextCursor" => nil}) ==
             :ok

    assert {:error, _} =
             Contract.validate(:batch_list_response, %{
               "items" => [BatchFixture.batch("open")],
               "nextCursor" => nil
             })
  end

  test "the validator knows exactly the schema's properties and required keys" do
    defs = schema()["$defs"]
    batch = BatchFixture.rebatched()
    item = hd(batch["items"])
    quoted = BatchFixture.batch("quote_pending")

    for {def_name, sample, optional} <- [
          {"Batch", batch, []},
          {"BatchItem", item, ["generalInstructions", "previouslyCancelledIn"]},
          {"PrintJob", hd(item["jobs"]), []},
          {"File", hd(item["jobs"])["file"], []},
          {"BatchQuote", quoted["currentQuote"], []},
          {"BatchClose", BatchFixture.monthly_close(), []}
        ] do
      schema = defs[def_name]
      assert Enum.sort(schema["required"] ++ optional) == Enum.sort(Map.keys(schema["properties"]))
      assert Enum.sort(Map.keys(sample) -- optional) == Enum.sort(schema["required"]), def_name
    end

    for key <- defs["Batch"]["required"] do
      assert {:error, _} = Contract.validate(:batch_response, %{"batch" => Map.delete(batch, key)})
    end

    for key <- defs["BatchClose"]["required"] do
      close = Map.delete(BatchFixture.monthly_close(), key)
      assert {:error, _} = Contract.validate(:batch_close_response, %{"close" => close})
    end
  end

  test "types, enums, ranges, formats and semantic counts are enforced" do
    batch = BatchFixture.batch("quote_pending")
    bad = fn path, value -> %{"batch" => put_in(batch, path, value)} end

    for {path, value} <- [
          {["status"], "ready"},
          {["reference"], "IMP-0001"},
          {["version"], 0},
          {["itemCount"], 2},
          {["items"], []},
          {["currentQuote", "currency"], "USD"},
          {["currentQuote", "orderRevision"], 1},
          {["cancellationReason"], 1}
        ] do
      assert {:error, _} = Contract.validate(:batch_response, bad.(path, value)), inspect(path)
    end

    item = hd(batch["items"])

    for bad_item <- [
          Map.put(item, "previouslyCancelledIn", "IMP-0001"),
          Map.put(item, "extra", true),
          Map.put(item, "reference", "LOT-0001"),
          put_in(item, ["generalInstructions", "extra"], 1),
          item |> Map.put("jobs", []) |> Map.delete("generalInstructions")
        ] do
      assert {:error, _} =
               Contract.validate(:batch_response, %{"batch" => %{batch | "items" => [bad_item]}})
    end

    duplicate = %{batch | "items" => [item, item], "itemCount" => 2}
    assert {:error, _} = Contract.validate(:batch_response, %{"batch" => duplicate})

    close = BatchFixture.monthly_close()
    [batch_item, legacy] = close["items"]

    for bad_close_item <- [
          Map.put(batch_item, "kind", "order"),
          Map.put(batch_item, "orderId", legacy["orderId"]),
          Map.delete(legacy, "orderId")
        ] do
      assert {:error, _} =
               Contract.validate(:batch_close_response, %{
                 "close" => %{close | "items" => [bad_close_item]}
               })
    end
  end
end

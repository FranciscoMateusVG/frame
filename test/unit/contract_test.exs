defmodule Frame.Unit.ContractTest do
  @moduledoc "The validator against the frozen Hono fixtures and schema (monorepo-incluir PR B + PR C)."
  use ExUnit.Case, async: true

  alias Frame.Adapters.PrintApi
  alias Frame.Domain.Close
  alias Frame.Domain.Contract
  alias Frame.Test.Ids

  @fixtures Path.expand("../fixtures", __DIR__)

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> JSON.decode!()

  test "every frozen order body validates" do
    for {name, body} <- fixture("print-portal-v1.fixture.json") do
      kind =
        cond do
          String.starts_with?(name, "error") -> :error_response
          name == "GET /orders" -> :order_list_response
          true -> :order_response
        end

      assert Contract.validate(kind, body) == :ok, name
    end
  end

  test "every frozen monthly-close body validates and its ETag is derivable" do
    %{"bodies" => bodies, "etags" => etags} = fixture("print-portal-v1.monthly-closes.fixture.json")

    for {name, body} <- bodies do
      assert Contract.validate(:close_response, body) == :ok, name
      assert Close.etag(body["close"]) == etags[name], name
    end
  end

  test "the validator knows exactly the schema's properties and required keys" do
    defs = fixture("print-portal-v1.schema.json")["$defs"]
    order = fixture("print-portal-v1.fixture.json")["GET /orders/:id (ready)"]

    close =
      fixture("print-portal-v1.monthly-closes.fixture.json")["bodies"][
        "POST /monthly-closes/:competence/invoice"
      ]

    for {def_name, sample} <- [
          {"Order", order["order"]},
          {"PrintJob", hd(order["order"]["jobs"])},
          {"File", hd(order["order"]["jobs"])["file"]},
          {"Close", close["close"]},
          {"CloseItem", hd(close["close"]["items"])}
        ] do
      schema = defs[def_name]
      assert Enum.sort(schema["required"]) == Enum.sort(Map.keys(schema["properties"])), def_name
      assert Enum.sort(Map.keys(sample)) == Enum.sort(schema["required"]), def_name
    end

    # Removing any required key or adding an unknown one fails validation.
    for key <- defs["Order"]["required"] do
      assert {:error, _} =
               Contract.validate(:order_response, %{"order" => Map.delete(order["order"], key)})
    end

    for key <- defs["Close"]["required"] do
      assert {:error, _} =
               Contract.validate(:close_response, %{"close" => Map.delete(close["close"], key)})
    end
  end

  test "types, enums, ranges and formats are enforced" do
    order = fixture("print-portal-v1.fixture.json")["POST /orders/:id/quotes"]["order"]
    bad = fn path, value -> %{"order" => put_in(order, path, value)} end

    for {path, value} <- [
          {["status"], "awaiting_readiness"},
          {["version"], 0},
          {["version"], "1"},
          {["reference"], "P-1"},
          {["createdAt"], "2026-10-08 00:00"},
          {["id"], "not-a-uuid"},
          {["approvedAmountCents"], 2_147_483_648},
          {["jobs"], []},
          {["currentQuote", "currency"], "USD"},
          {["currentQuote", "decision"], "maybe"},
          {["currentQuote", "document", "sha256"], "ABC"},
          {["title"], ""}
        ] do
      assert {:error, _} = Contract.validate(:order_response, bad.(path, value)), inspect(path)
    end

    assert {:error, "$.order.extra: extra"} =
             Contract.validate(:order_response, %{"order" => Map.put(order, "extra", 1)})

    assert {:error, _} = Contract.validate(:order_list_response, [])
    assert {:error, _} = Contract.validate(:error_response, %{"error" => %{"code" => ""}})
  end

  test "bodies produced by the in-memory fake satisfy the contract" do
    api = PrintApi.Memory.new()
    pdf = "%PDF-1.4 x"

    o =
      PrintApi.Memory.seed_order(api, [
        %{
          title: "Apostila",
          copies: 2,
          instructions: "Frente e verso",
          file_name: "a.pdf",
          bytes: pdf
        }
      ])

    {:ok, list} = PrintApi.list_orders(api, %{})
    assert Contract.validate(:order_list_response, list.body) == :ok
    {:ok, got} = PrintApi.get_order(api, o["id"])
    assert Contract.validate(:order_response, got.body) == :ok
    {:ok, close} = PrintApi.get_close(api, "2026-09")
    assert Contract.validate(:close_response, close.body) == :ok
    {:ok, missing} = PrintApi.get_order(api, Ids.uuid())
    assert Contract.validate(:error_response, missing.body) == :ok
  end
end

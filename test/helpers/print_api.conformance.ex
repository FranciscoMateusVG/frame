defmodule Frame.Test.PrintApiConformance do
  @moduledoc """
  The PrintApi conformance suite: the same behaviour is asserted for every
  adapter. `use` it in a test module whose `setup` returns `%{api: api,
  memory: memory, clock: clock_agent}`, where `memory` is the
  `PrintApi.Memory` holding the state (the adapter itself, or the one
  behind a FakeHono) and `clock` an Agent holding the fake's current time.

  The tests are grouped in three macros (orders, workflow, monthly close);
  their shared helpers live in `Frame.Test.PrintApiConformance.Helpers`.
  """

  defmacro __using__(_opts) do
    quote do
      alias Frame.Adapters.PrintApi
      alias Frame.Adapters.PrintApi.Memory
      alias Frame.Adapters.PrintApi.Response
      alias Frame.Test.Ids

      import Frame.Test.PrintApiConformance.Helpers

      require unquote(__MODULE__)

      @pdf pdf()

      unquote(__MODULE__).order_tests()
      unquote(__MODULE__).workflow_tests()
      unquote(__MODULE__).close_tests()
    end
  end

  @doc false
  defmacro order_tests do
    quote do
      alias Frame.Adapters.PrintApi
      alias Frame.Adapters.PrintApi.Memory
      alias Frame.Adapters.PrintApi.Response
      alias Frame.Test.Ids

      test "lists in createdAt/id order with a keyset cursor and status filter", %{
        api: api,
        memory: m
      } do
        orders = seed(m, 3)

        {:ok, %Response{status: 200, body: %{"items" => page1, "nextCursor" => cursor}}} =
          PrintApi.list_orders(api, %{limit: 2})

        assert Enum.map(page1, & &1["id"]) == orders |> Enum.take(2) |> Enum.map(& &1["id"])
        assert is_binary(cursor)

        {:ok, %Response{body: %{"items" => [last], "nextCursor" => nil}}} =
          PrintApi.list_orders(api, %{limit: 2, cursor: cursor})

        assert last["id"] == List.last(orders)["id"]
        refute Map.has_key?(last, "jobs")

        {:ok, %Response{body: %{"items" => []}}} = PrintApi.list_orders(api, %{status: "printed"})
        {:ok, bad} = PrintApi.list_orders(api, %{cursor: "garbage"})
        assert {bad.status, code(bad)} == {400, "INVALID_CURSOR"}
        # A cursor is bound to its status filter.
        {:ok, other} = PrintApi.list_orders(api, %{status: "ready", cursor: cursor})
        assert other.status == 400
      end

      test "gets an order with its ETag; unknown ids are 404", %{api: api, memory: m} do
        [o] = seed(m)

        {:ok, %Response{status: 200, etag: etag, body: %{"order" => got}}} =
          PrintApi.get_order(api, o["id"])

        assert etag == ~s("#{o["id"]}:1")
        assert got == o
        {:ok, missing} = PrintApi.get_order(api, Ids.uuid())
        assert {missing.status, code(missing)} == {404, "NOT_FOUND"}
      end

      test "commands enforce preconditions, ETags and idempotency", %{api: api, memory: m} do
        [o] = seed(m)

        {:ok, r} =
          PrintApi.collect(api, o["id"], %{revision: 1}, %{if_match: nil, idempotency_key: nil})

        assert {r.status, code(r)} == {428, "PRECONDITION_REQUIRED"}
        {:ok, r} = collect(api, o, pre(~s("#{o["id"]}:1"), "not-a-uuid"))
        assert {r.status, code(r)} == {400, "INVALID_REQUEST"}
        {:ok, r} = collect(api, o, pre(~s("#{o["id"]}:9")))
        assert {r.status, code(r)} == {412, "VERSION_MISMATCH"}
        {:ok, r} = PrintApi.collect(api, o["id"], %{revision: 2}, pre(~s("#{o["id"]}:1")))
        assert {r.status, code(r)} == {412, "VERSION_MISMATCH"}

        key = Ids.uuid()
        {:ok, ok} = collect(api, o, pre(~s("#{o["id"]}:1"), key))
        assert {ok.status, ok.etag, ok.replayed} == {200, ~s("#{o["id"]}:2"), false}
        assert ok.body["order"]["status"] == "files_collected"
        assert ok.body["order"]["collectedAt"]

        # Same key + same intent: original answer, even after the version moved.
        {:ok, replay} = collect(api, o, pre(~s("#{o["id"]}:1"), key))
        assert {replay.status, replay.body, replay.replayed} == {200, ok.body, true}
        # Same key, other intent: conflict.
        {:ok, conflict} = collect(api, o, pre(~s("#{o["id"]}:2"), key))
        assert {conflict.status, code(conflict)} == {409, "IDEMPOTENCY_CONFLICT"}
        # Fresh key, current ETag, wrong state.
        {:ok, again} = collect(api, o, pre(~s("#{o["id"]}:2")))
        assert {again.status, code(again)} == {409, "INVALID_STATE"}
      end
    end
  end

  @doc false
  defmacro workflow_tests do
    quote do
      alias Frame.Adapters.PrintApi
      alias Frame.Adapters.PrintApi.Memory
      alias Frame.Adapters.PrintApi.Response
      alias Frame.Test.Ids

      test "quote → approval → printed, with downloads", %{api: api, memory: m} do
        [o] = seed(m)
        {:ok, early} = quote!(api, o, 1)
        assert {early.status, code(early)} == {409, "INVALID_STATE"}
        {:ok, _} = collect(api, o)
        {:ok, q} = quote!(api, o, 2)
        assert q.status == 201
        quote = q.body["order"]["currentQuote"]

        assert {quote["decision"], quote["amountCents"], quote["currency"]} ==
                 {"pending", 45_900, "BRL"}

        assert quote["document"]["name"] == "orçamento.pdf"

        {:ok, premature} =
          PrintApi.mark_printed(api, o["id"], %{revision: 1, quote_id: quote["id"]}, pre(q.etag))

        assert {premature.status, code(premature)} == {409, "INVALID_STATE"}

        {:streamed, doc} = collect_bytes(api, {:quote_file, o["id"], quote["id"]})
        assert doc.data == @pdf <> "q45900"
        assert doc.headers["content-type"] == "application/pdf"
        assert doc.headers["content-disposition"] =~ "attachment;"

        :ok = Memory.decide_quote(m, o["id"], :approved)
        {:ok, %Response{etag: etag}} = PrintApi.get_order(api, o["id"])

        {:ok, wrong} =
          PrintApi.mark_printed(api, o["id"], %{revision: 1, quote_id: Ids.uuid()}, pre(etag))

        assert {wrong.status, code(wrong)} == {412, "VERSION_MISMATCH"}

        {:ok, done} =
          PrintApi.mark_printed(api, o["id"], %{revision: 1, quote_id: quote["id"]}, pre(etag))

        assert done.status == 200
        assert done.body["order"]["status"] == "printed"
        assert done.body["order"]["approvedAmountCents"] == 45_900
      end

      test "a rejected quote can be replaced; the new one is revision 2", %{api: api, memory: m} do
        [o] = seed(m)
        {:ok, _} = collect(api, o)
        {:ok, _} = quote!(api, o, 2)
        :ok = Memory.decide_quote(m, o["id"], {:rejected, "Valor acima do combinado"})
        {:ok, %Response{body: %{"order" => rejected}}} = PrintApi.get_order(api, o["id"])
        assert rejected["status"] == "quote_rejected"
        assert rejected["currentQuote"]["rejectionReason"] == "Valor acima do combinado"
        {:ok, second} = quote!(api, o, rejected["version"], 40_000)
        assert second.body["order"]["currentQuote"]["revision"] == 2
      end

      test "files of the current revision download byte-exact; foreign ids are 404", %{
        api: api,
        memory: m
      } do
        [a, b] = seed(m, 2)
        [job1, job2] = a["jobs"]
        {:streamed, f2} = collect_bytes(api, {:order_file, a["id"], job2["file"]["id"]})
        assert f2.data == @pdf <> "a1"

        assert :crypto.hash(:sha256, f2.data) |> Base.encode16(case: :lower) ==
                 job2["file"]["sha256"]

        assert f2.headers["content-length"] == "#{byte_size(f2.data)}"
        {:streamed, f1} = collect_bytes(api, {:order_file, a["id"], job1["file"]["id"]})
        assert f1.data == @pdf <> "1"

        {:ok, foreign} = collect_bytes(api, {:order_file, b["id"], job1["file"]["id"]})
        assert foreign.status == 404
        {:ok, nope} = collect_bytes(api, {:quote_file, a["id"], Ids.uuid()})
        assert nope.status == 404
      end
    end
  end

  @doc false
  defmacro close_tests do
    quote do
      alias Frame.Adapters.PrintApi
      alias Frame.Adapters.PrintApi.Memory
      alias Frame.Adapters.PrintApi.Response
      alias Frame.Test.Ids
      alias Frame.Test.Observability, as: TestObservability

      test "monthly close: virtual, PERIOD_OPEN, EMPTY_CLOSE, submit, reject, resubmit", %{
        api: api,
        memory: m,
        clock: clock
      } do
        Agent.update(clock, fn _ -> ~U[2026-09-10 12:00:00Z] end)
        {:ok, virtual} = PrintApi.get_close(api, "2026-08")
        assert virtual.etag == ~s("month:2026-08:0")
        assert virtual.body["close"]["id"] == nil
        {:ok, bad} = PrintApi.get_close(api, "2026-13")
        assert {bad.status, code(bad)} == {400, "INVALID_COMPETENCE"}

        [o] = seed(m)
        {:ok, _} = collect(api, o)
        {:ok, _} = quote!(api, o, 2)
        :ok = Memory.decide_quote(m, o["id"], :approved)

        {:ok, %Response{etag: etag, body: %{"order" => %{"currentQuote" => %{"id" => qid}}}}} =
          PrintApi.get_order(api, o["id"])

        {:ok, _} = PrintApi.mark_printed(api, o["id"], %{revision: 1, quote_id: qid}, pre(etag))

        nf = %{name: "NF setembro.pdf", content_type: "application/pdf", bytes: @pdf <> "nf"}
        {:ok, open} = PrintApi.get_close(api, "2026-09")
        assert open.body["close"]["periodClosed"] == false
        assert open.body["close"]["expectedTotalCents"] == 45_900

        {:ok, r} =
          PrintApi.submit_invoice(
            api,
            "2026-09",
            %{declared_total_cents: 45_900, file: nf},
            pre(open.etag)
          )

        assert {r.status, code(r)} == {409, "PERIOD_OPEN"}

        Agent.update(clock, fn _ -> ~U[2026-10-15 15:00:00Z] end)

        {:ok, r} =
          PrintApi.submit_invoice(
            api,
            "2026-08",
            %{declared_total_cents: 1, file: nf},
            pre(~s("month:2026-08:0"))
          )

        assert {r.status, code(r)} == {409, "EMPTY_CLOSE"}

        {:ok, closed} = PrintApi.get_close(api, "2026-09")
        assert closed.body["close"]["periodClosed"]
        [item] = closed.body["close"]["items"]
        assert {item["orderId"], item["amountCents"], item["quoteId"]} == {o["id"], 45_900, qid}

        {:ok, sub} =
          PrintApi.submit_invoice(
            api,
            "2026-09",
            %{declared_total_cents: 45_000, file: nf},
            pre(closed.etag)
          )

        assert sub.status == 201
        assert sub.body["close"]["state"] == "submitted"
        assert sub.body["close"]["declaredTotalCents"] == 45_000

        {:ok, again} =
          PrintApi.submit_invoice(
            api,
            "2026-09",
            %{declared_total_cents: 45_900, file: nf},
            pre(sub.etag)
          )

        assert {again.status, code(again)} == {409, "INVALID_STATE"}

        {:streamed, doc} = collect_bytes(api, {:invoice_file, "2026-09"})
        assert doc.data == @pdf <> "nf"

        :ok = Memory.decide_invoice(m, "2026-09", {:rejected, "Valor diverge"})
        {:ok, rejected} = PrintApi.get_close(api, "2026-09")
        assert rejected.body["close"]["rejectionReason"] == "Valor diverge"

        {:ok, resub} =
          PrintApi.submit_invoice(
            api,
            "2026-09",
            %{declared_total_cents: 45_900, file: nf},
            pre(rejected.etag)
          )

        assert resub.status == 201
      end

      test "an invalid document is refused by the upstream rules", %{api: api, memory: m} do
        [o] = seed(m)
        {:ok, _} = collect(api, o)
        html = %{name: "x.pdf", content_type: "application/pdf", bytes: "<html>"}

        {:ok, r} =
          PrintApi.submit_quote(
            api,
            o["id"],
            %{amount_cents: 1, order_revision: 1, file: html},
            pre(~s("#{o["id"]}:2"))
          )

        assert {r.status, code(r)} == {415, "UNSUPPORTED_MEDIA_TYPE"}
      end

      test "emits one http.print_api span per call", %{api: api, memory: m, obs: obs} do
        [o] = seed(m)
        TestObservability.reset(obs)
        {:ok, _} = PrintApi.get_order(api, o["id"])
        names = obs |> TestObservability.get_spans() |> Enum.map(& &1.name)
        assert "http.print_api.getOrder" in names
      end
    end
  end
end

defmodule Frame.Test.PrintApiConformance.Helpers do
  @moduledoc "Helpers shared by the PrintApi conformance tests."

  alias Frame.Adapters.PrintApi
  alias Frame.Adapters.PrintApi.Memory
  alias Frame.Adapters.PrintApi.Response
  alias Frame.Test.Ids

  @pdf "%PDF-1.4\n%conformance\n"

  def pdf, do: @pdf

  def seed(memory, n \\ 1) do
    for i <- 1..n do
      Memory.seed_order(
        memory,
        [
          %{
            title: "Trabalho #{i}",
            copies: i,
            instructions: "Instruções #{i}",
            file_name: "t#{i}.pdf",
            bytes: @pdf <> "#{i}"
          },
          %{
            title: "Anexo #{i}",
            copies: 1,
            instructions: "Só frente",
            file_name: "../a#{i}.pdf",
            bytes: @pdf <> "a#{i}"
          }
        ],
        created_at: DateTime.add(~U[2026-09-01 12:00:00.000Z], i)
      )
    end
  end

  def pre(etag, key \\ Ids.uuid()), do: %{if_match: etag, idempotency_key: key}
  def code(%Response{body: %{"error" => %{"code" => code}}}), do: code

  def collect(api, order, pre \\ nil),
    do: PrintApi.collect(api, order["id"], %{revision: 1}, pre || pre(~s("#{order["id"]}:1")))

  def quote!(api, order, version, cents \\ 45_900) do
    file = %{name: "orçamento.pdf", content_type: "application/pdf", bytes: @pdf <> "q#{cents}"}
    input = %{amount_cents: cents, order_revision: 1, file: file}
    PrintApi.submit_quote(api, order["id"], input, pre(~s("#{order["id"]}:#{version}")))
  end

  def collect_bytes(api, target) do
    sink = fn
      {:head, headers}, acc -> Map.put(acc, :headers, headers)
      {:data, data}, acc -> Map.update(acc, :data, data, &(&1 <> data))
    end

    PrintApi.download(api, target, %{}, sink)
  end
end

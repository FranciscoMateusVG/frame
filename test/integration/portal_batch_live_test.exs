defmodule Frame.Integration.PortalBatchLiveTest do
  @moduledoc """
  The batch screens (TTP task 1) through the portal: the home page `/` is
  the current batch with one card per file, grouped by request; commands
  run over the socket with If-Match = the batch ETag and one
  Idempotency-Key per intent; **Lotes anteriores** is the read-only
  history. Everything goes through the real HTTP adapter to FakeHono over
  a real socket, seeded with the frozen v2 fixture.
  """
  use Frame.Test.PortalCase, async: true

  alias Frame.Adapters.PrintApi
  alias Frame.Adapters.PrintApi.Memory
  alias Frame.Test.BatchFixture
  alias Frame.Test.FakeHono

  setup do
    p = Portal.start()
    %{portal: Portal.signed_in(p)}
  end

  defp live_page(p, path) do
    {:ok, view, html} = live(Portal.conn(p), path)
    {view, html}
  end

  defp batch_status(p, batch) do
    {:ok, %{body: %{"batch" => got}}} = PrintApi.get_batch(p.memory, batch["id"])
    got["status"]
  end

  defp upload(view, name, bytes, type \\ "application/pdf") do
    file = file_input(view, "#quote-form", :file, [%{name: name, content: bytes, type: type}])
    render_upload(file, name)
  end

  defp doc(html), do: LazyHTML.from_document(html)
  defp q(node, selector), do: LazyHTML.query(node, selector)
  defp attr(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
  defp text(node), do: node |> LazyHTML.text() |> String.split() |> Enum.join(" ")
  defp nodes(node), do: Enum.to_list(node)

  describe "home: the current batch" do
    test "a plain GET renders the batch, items in contract order and one card per file", %{
      portal: p
    } do
      batch = BatchFixture.rebatched()
      BatchFixture.seed(p.memory, batch)

      {_p, resp} = Portal.get(p, "/")
      assert resp.status == 200
      page = doc(resp.raw)

      [root] = nodes(q(page, ~s([data-ttp="batch"])))
      assert {attr(root, "data-batch-id"), attr(root, "data-status")} == {batch["id"], "open"}
      assert text(q(root, ~s([data-ttp="batch-reference"]))) == "LOT-0003"

      items = nodes(q(root, ~s([data-ttp="item"])))

      assert Enum.map(items, &attr(&1, "data-order-id")) ==
               Enum.map(batch["items"], & &1["orderId"])

      for {node, item} <- Enum.zip(items, batch["items"]) do
        assert text(q(node, ~s([data-ttp="item-reference"]))) == item["reference"]

        expected_files =
          Enum.map(item["jobs"], &{:job, &1}) ++
            Enum.map(get_in(item, ["generalInstructions", "files"]) || [], &{:residual, &1})

        files = nodes(q(node, ~s([data-ttp="file"])))
        assert length(files) == length(expected_files)

        for {file_node, card} <- Enum.zip(files, expected_files) do
          file = if match?({:job, _}, card), do: elem(card, 1)["file"], else: elem(card, 1)
          assert attr(file_node, "data-file-id") == file["id"]
          assert text(q(file_node, ~s([data-ttp="file-name"]))) == file["name"]
          size = q(file_node, ~s([data-ttp="file-size"]))
          assert attr(size, "data-bytes") == Integer.to_string(file["bytes"])
          assert text(size) == "634 B"
          [link] = nodes(q(file_node, ~s(a[data-ttp="download"])))
          assert text(link) == "Baixar arquivo"

          assert attr(link, "href") ==
                   "/api/print/v2/batches/#{batch["id"]}/orders/#{item["orderId"]}/files/#{file["id"]}"

          case card do
            {:job, job} ->
              assert text(q(file_node, ~s([data-ttp="copies"]))) == Integer.to_string(job["copies"])
              assert text(q(file_node, ~s([data-ttp="instructions"]))) == job["instructions"]

            {:residual, _file} ->
              assert nodes(q(file_node, ~s([data-ttp="copies"]))) == []
              assert nodes(q(file_node, ~s([data-ttp="instructions"]))) == []
              assert text(file_node) =~ "Sem vínculo seguro — consulte instruções gerais"
          end
        end
      end

      # The residual general instructions live only inside their own request.
      [mixed, plain] = items
      [general] = nodes(q(mixed, ~s([data-ttp="general-instructions"])))
      assert LazyHTML.text(general) == hd(batch["items"])["generalInstructions"]["text"]
      assert nodes(q(plain, ~s([data-ttp="general-instructions"]))) == []

      # The re-batched item carries the backend's warning; the other does not.
      [warning] = nodes(q(mixed, ~s([data-ttp="previously-cancelled"])))

      assert text(warning) ==
               "Este item esteve no lote LOT-0001, cancelado — confira antes de imprimir"

      assert nodes(q(plain, ~s([data-ttp="previously-cancelled"]))) == []

      # Header: status, item count, copies, the track; the one allowed action.
      header = text(q(root, "header"))

      for fragment <- ["Pronto para retirada", "2 pedidos", "44 cópias", "4 arquivos"],
          do: assert(header =~ fragment, fragment)

      assert text(q(root, ".track")) ==
               "Pronto Arquivos retirados Orçamento enviado Orçamento aprovado Impresso"

      [action] = nodes(q(page, ~s([data-ttp="action"])))
      assert {LazyHTML.tag(action), attr(action, "type")} == {["button"], "submit"}
      assert {attr(action, "data-action"), text(action)} == {"collect", "Retirei os arquivos"}
      assert nodes(q(page, ~s([data-ttp="status-message"]))) == []
    end

    test "each download returns the exact bytes of the fixture asset", %{portal: p} do
      batch = BatchFixture.rebatched()
      BatchFixture.seed(p.memory, batch)
      {p, resp} = Portal.get(p, "/")
      hrefs = resp.raw |> doc() |> q(~s(a[data-ttp="download"])) |> LazyHTML.attribute("href")
      assert length(hrefs) == 4

      for href <- hrefs do
        [file_id] = Regex.run(~r{[^/]+$}, href)
        {_p, got} = Portal.get(p, href)
        assert got.status == 200
        assert got.raw == BatchFixture.asset(file_id)
        assert Portal.header(got, "content-type") == ["application/pdf"]
      end

      # Without the session cookie nothing is served.
      {_p, anon} = Portal.get(Portal.fresh(p), hd(hrefs))
      assert anon.status == 401
    end

    test "no current batch: Nenhum pedido aguardando, and no batch markers", %{portal: p} do
      BatchFixture.seed(p.memory, BatchFixture.batch("received"))
      {_p, resp} = Portal.get(p, "/")
      page = doc(resp.raw)
      [empty] = nodes(q(page, ~s([data-ttp="empty"])))
      assert text(empty) == "Nenhum pedido aguardando"

      for marker <- ~w(batch item file action),
          do: assert(nodes(q(page, ~s([data-ttp="#{marker}"]))) == [], marker)
    end

    test "each status renders only its action, or its waiting message" do
      expected = %{
        "open" => {"collect", "Retirei os arquivos"},
        "files_collected" => {"upload-quote", "Enviar orçamento"},
        "quote_rejected" => {"upload-quote", "Enviar orçamento"},
        "quote_approved" => {"mark-printed", "Marcar como impresso"},
        "quote_pending" => {:message, "Aguardando aprovação do Financeiro"},
        "printed" => {:message, "Aguardando recebimento"}
      }

      for {status, want} <- expected do
        world = Portal.signed_in(Portal.start())
        BatchFixture.seed(world.memory, BatchFixture.batch(status))
        {_p, resp} = Portal.get(world, "/")
        page = doc(resp.raw)
        assert attr(q(page, ~s([data-ttp="batch"])), "data-status") == status
        actions = nodes(q(page, ~s([data-ttp="action"])))
        messages = nodes(q(page, ~s([data-ttp="status-message"])))

        case want do
          {:message, message} ->
            assert actions == [], status
            assert Enum.map(messages, &text/1) == [message], status

          {action, label} ->
            assert messages == [], status
            assert Enum.map(actions, &{attr(&1, "data-action"), text(&1)}) == [{action, label}]
        end
      end
    end

    test "the rejection reason is shown (escaped) above the new quote form", %{portal: p} do
      rejected = BatchFixture.batch("quote_rejected")

      rejected =
        put_in(rejected, ["currentQuote", "rejectionReason"], "Valor <acima> do combinado")

      BatchFixture.seed(p.memory, rejected)
      {_view, html} = live_page(p, "/")
      assert html =~ "Orçamento rejeitado"
      assert html =~ "Valor &lt;acima&gt; do combinado"
    end

    test "the page when the upstream is down offers Consultar novamente", %{portal: p} do
      BatchFixture.seed(p.memory, BatchFixture.batch("open"))
      Memory.fail_with(p.memory, :unavailable)
      {view, html} = live_page(p, "/")
      assert html =~ "Sem resposta do sistema do Incluir"
      refute html =~ ~s(data-ttp="batch")
      Memory.fail_with(p.memory, nil)
      assert view |> element("button", "Consultar novamente") |> render_click() =~ "LOT-0001"
    end
  end

  describe "commands on the batch" do
    test "Retirei os arquivos needs the checkbox and an explicit confirmation", %{portal: p} do
      batch = BatchFixture.rebatched()
      BatchFixture.seed(p.memory, batch)
      {view, _html} = live_page(p, "/")

      html = view |> form("#collect-form", %{}) |> render_submit()
      assert html =~ "Marque “Conferi todos os arquivos” para confirmar a retirada."
      refute has_element?(view, "#confirm-collect")
      assert FakeHono.commands(p.hono) == []

      view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
      confirm = view |> element("#confirm-collect") |> render()
      assert confirm =~ "4 arquivos"
      assert confirm =~ "2 pedidos"
      assert confirm =~ "LOT-0003"
      view |> element("#confirm-collect button", "Voltar") |> render_click()
      assert batch_status(p, batch) == "open"

      view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
      html = view |> element("#confirm-collect button", "Confirmar retirada") |> render_click()
      assert html =~ "Retirada confirmada."
      assert batch_status(p, batch) == "files_collected"
      assert [command] = FakeHono.commands(p.hono)
      assert command["if-match"] == ~s("#{batch["id"]}:1")
      assert html =~ "Enviar orçamento"
      # The cards stay on screen after collection.
      assert html =~ "Documento sem bloco.pdf"
    end

    test "the home keeps the batch after collection: quote → approved → printed on /", %{
      portal: p
    } do
      # History first, so the active batch is not the first one listed.
      BatchFixture.seed(p.memory, [%{BatchFixture.batch("received") | "id" => Ids.uuid()}])
      batch = BatchFixture.batch("open")
      BatchFixture.seed(p.memory, batch)
      {view, _html} = live_page(p, "/")

      view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
      html = view |> element("#confirm-collect button", "Confirmar retirada") |> render_click()
      assert html =~ "Retirada confirmada."
      assert has_element?(view, ~s([data-ttp="batch"][data-status="files_collected"]))
      assert has_element?(view, "#quote-form")

      # A fresh visit to / finds the active batch too (/open is null now).
      {view, _html} = live_page(p, "/")
      upload(view, "orçamento.pdf", Portal.pdf("q"))
      view |> form("#quote-form", %{"valor" => "459,00"}) |> render_submit()
      html = view |> element("#confirm-quote button", "Confirmar envio") |> render_click()
      assert html =~ "Orçamento enviado. Aguardando aprovação do Financeiro."

      assert has_element?(
               view,
               ~s([data-ttp="status-message"]),
               "Aguardando aprovação do Financeiro"
             )

      :ok = Memory.decide_batch_quote(p.memory, batch["id"], {:rejected, "Corrigir total"})
      {view, html} = live_page(p, "/")
      assert html =~ "Corrigir total"
      upload(view, "orçamento2.pdf", Portal.pdf("q2"))
      view |> form("#quote-form", %{"valor" => "450,00"}) |> render_submit()
      view |> element("#confirm-quote button", "Confirmar envio") |> render_click()

      :ok = Memory.decide_batch_quote(p.memory, batch["id"], :approved)
      {view, _html} = live_page(p, "/")
      view |> element(~s(button[data-action="mark-printed"])) |> render_click()
      html = view |> element("#confirm-print button", "Confirmar impressão") |> render_click()
      assert html =~ "Impressão confirmada."
      {_view, html} = live_page(p, "/")
      assert html =~ "Aguardando recebimento"
      assert batch_status(p, batch) == "printed"
    end

    test "the active batch is found past the first page of the history", %{portal: p} do
      base = %{BatchFixture.batch("received") | "createdAt" => "2026-08-01T12:00:00.000Z"}

      for n <- 1..120 do
        id = "00000000-0000-4000-a000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
        Memory.put_batch(p.memory, %{base | "id" => id}, %{})
      end

      BatchFixture.seed(p.memory, BatchFixture.batch("quote_approved"))
      {_p, resp} = Portal.get(p, "/")
      [root] = nodes(q(doc(resp.raw), ~s([data-ttp="batch"])))
      assert attr(root, "data-status") == "quote_approved"
    end

    test "a stale ETag gets 412: the page reloads and asks to confirm again", %{portal: p} do
      batch = BatchFixture.batch("open")
      BatchFixture.seed(p.memory, batch)
      {view, _html} = live_page(p, "/")

      # The batch changes upstream while the page is open.
      :ok = Memory.revise_batch(p.memory, batch["id"])

      view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
      html = view |> element("#confirm-collect button", "Confirmar retirada") |> render_click()
      assert html =~ "O lote foi atualizado. Confira os arquivos e confirme a retirada novamente."
      assert batch_status(p, batch) == "open"
      refute has_element?(view, "#confirm-collect")

      # Recoverable after the reload: the new ETag is used.
      view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
      html = view |> element("#confirm-collect button", "Confirmar retirada") |> render_click()
      assert html =~ "Retirada confirmada."
      assert [first, second] = FakeHono.commands(p.hono)
      assert first["if-match"] == ~s("#{batch["id"]}:1")
      assert second["if-match"] == ~s("#{batch["id"]}:2")
      assert second["idempotency-key"] != first["idempotency-key"]
      assert batch_status(p, batch) == "files_collected"
    end

    test "quote refusals: format, size and the upstream's verdict", %{portal: p} do
      batch = BatchFixture.batch("files_collected")
      BatchFixture.seed(p.memory, batch)
      {view, _} = live_page(p, "/")

      assert {:error, [[_ref, :not_accepted]]} = upload(view, "notas.txt", "texto", "text/plain")
      assert render(view) =~ "Formato não aceito"
      view |> element("button[phx-click=cancel-upload]") |> render_click()

      big = "%PDF-" <> :binary.copy("a", 5 * 1024 * 1024)
      assert {:error, [[_ref, :too_large]]} = upload(view, "grande.pdf", big)
      assert render(view) =~ "O arquivo passa de 5 MB."
      view |> element("button[phx-click=cancel-upload]") |> render_click()

      html = view |> form("#quote-form", %{"valor" => "abc"}) |> render_change()
      assert html =~ "Informe o valor do orçamento em reais"

      # A .pdf that is not a PDF: the upstream's 415 is shown, nothing changes.
      upload(view, "falso.pdf", "<html>")
      view |> form("#quote-form", %{"valor" => "10,00"}) |> render_submit()
      html = view |> element("#confirm-quote button", "Confirmar envio") |> render_click()
      assert html =~ "Formato não aceito. Envie PDF, JPEG, PNG ou WebP."
      assert batch_status(p, batch) == "files_collected"
    end

    test "Enviar orçamento: lost reply, Repetir reuses the key, one quote only", %{portal: p} do
      batch = BatchFixture.batch("files_collected")
      BatchFixture.seed(p.memory, batch)
      {view, _} = live_page(p, "/")

      upload(view, "orçamento.pdf", Portal.pdf("q"))
      view |> form("#quote-form", %{"valor" => "459,00"}) |> render_submit()
      confirm = view |> element("#confirm-quote") |> render()
      assert confirm =~ "R$ 459,00"
      assert confirm =~ "LOT-0001"

      # The quote lands upstream, but its answer is lost (503).
      FakeHono.misbehave(p.hono, :lost_reply)
      html = view |> element("#confirm-quote button", "Confirmar envio") |> render_click()
      assert html =~ "Sem resposta do sistema do Incluir"
      refute html =~ "Orçamento enviado."

      html = view |> element("button", "Repetir") |> render_click()
      assert html =~ "Orçamento enviado. Aguardando aprovação do Financeiro."
      assert html =~ "Aguardando aprovação do Financeiro"

      assert [first, second] = FakeHono.commands(p.hono)
      assert second["idempotency-key"] == first["idempotency-key"]
      assert second["if-match"] == first["if-match"]

      {:ok, %{body: %{"batch" => got}}} = PrintApi.get_batch(p.memory, batch["id"])
      assert {got["status"], got["version"]} == {"quote_pending", 3}
      assert {got["currentQuote"]["revision"], got["currentQuote"]["amountCents"]} == {1, 45_900}
    end

    test "Marcar como impresso → confirmation → printed", %{portal: p} do
      batch = BatchFixture.batch("quote_approved")
      BatchFixture.seed(p.memory, batch)
      {view, html} = live_page(p, "/")
      assert html =~ "R$ 459,00"

      view |> element(~s(button[data-action="mark-printed"])) |> render_click()
      assert view |> element("#confirm-print") |> render() =~ "LOT-0001"
      html = view |> element("#confirm-print button", "Confirmar impressão") |> render_click()
      assert html =~ "Impressão confirmada."
      assert html =~ "Aguardando recebimento"
      refute has_element?(view, ~s([data-ttp="action"]))
      assert batch_status(p, batch) == "printed"

      assert [command] = FakeHono.commands(p.hono)
      assert command["if-match"] == ~s("#{batch["id"]}:5")
    end
  end

  describe "Lotes anteriores" do
    test "lists every batch; the detail is read-only with the same cards", %{portal: p} do
      received = BatchFixture.batch("received")
      next = BatchFixture.next_batch()
      BatchFixture.seed(p.memory, [received, next])

      {view, html} = live_page(p, "/lotes")

      for text <- ["Lotes anteriores", "LOT-0001", "Recebido", "R$ 459,00", "LOT-0002"],
          do: assert(html =~ text, text)

      {:ok, detail, html} =
        view
        |> element(~s(a[href="/lotes/#{received["id"]}"]))
        |> render_click()
        |> follow_redirect(Portal.conn(p))

      assert html =~ "LOT-0001"
      assert html =~ "Recebido"
      assert html =~ "2.2 - Turma 9h - Revisão Tucanos"
      assert html =~ "Instruções gerais"
      refute has_element?(detail, ~s([data-ttp="action"]))
      refute has_element?(detail, "#collect-form, #quote-form, .panel")
    end

    test "Próxima página follows the cursor; a bad cursor and silence are handled", %{portal: p} do
      base = BatchFixture.batch("received")

      for n <- 1..21 do
        suffix = n |> Integer.to_string() |> String.pad_leading(12, "0")
        id = "00000000-0000-4000-9000-" <> suffix
        ref = "LOT-" <> String.pad_leading(Integer.to_string(n), 4, "0")
        Memory.put_batch(p.memory, %{base | "id" => id, "reference" => ref}, %{})
      end

      {view, html} = live_page(p, "/lotes")
      assert html =~ "LOT-0020"
      refute html =~ "LOT-0021"
      view |> element("a", "Próxima página") |> render_click()
      html = render(view)
      assert html =~ "LOT-0021"
      refute html =~ "LOT-0020"
      refute html =~ "Próxima página"

      {_view, html} = live_page(p, "/lotes?cursor=bogus")
      assert html =~ "Nenhum lote ainda"

      Memory.fail_with(p.memory, :unavailable)
      {view, html} = live_page(p, "/lotes")
      assert html =~ "Sem resposta do sistema do Incluir"
      Memory.fail_with(p.memory, nil)
      assert view |> element("button", "Consultar novamente") |> render_click() =~ "LOT-0001"
    end

    test "empty history and unknown or malformed ids", %{portal: p} do
      {_view, html} = live_page(p, "/lotes")
      assert html =~ "Nenhum lote ainda"

      for id <- [Ids.uuid(), "not-a-uuid"] do
        conn = get(Portal.conn(p), "/lotes/#{id}")
        assert html_response(conn, 404) =~ "Não encontrado"
      end
    end
  end

  test "pages without a session redirect to /login", %{portal: p} do
    for path <- ["/", "/lotes", "/lotes/#{Ids.uuid()}"] do
      conn = get(Portal.conn(Portal.fresh(p)), path)
      assert redirected_to(conn, 302) == "/login"
    end
  end
end

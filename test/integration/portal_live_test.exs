defmodule Frame.Integration.PortalLiveTest do
  @moduledoc """
  The supplier journey of spec §7 through the LiveView pages, the way a
  browser drives them (Phoenix.LiveViewTest): filters and pagination,
  two-step confirmations, uploads, and every command running over the
  socket through the same use cases as the JSON API — against the upstream
  (FakeHono) over the real HTTP adapter.
  """
  use Frame.Test.PortalCase, async: true

  alias Frame.Adapters.PrintApi
  alias Frame.Adapters.PrintApi.Memory
  alias Frame.Test.FakeHono
  alias Frame.Web.Security

  setup do
    p = Portal.start()
    %{portal: Portal.signed_in(p)}
  end

  defp live_page(p, path) do
    {:ok, view, html} = live(Portal.conn(p), path)
    {view, html}
  end

  defp pre(etag), do: %{if_match: etag, idempotency_key: Ids.uuid()}

  defp to_collected(p, o) do
    {:ok, _} = PrintApi.collect(p.memory, o["id"], %{revision: 1}, pre(~s("#{o["id"]}:1")))
  end

  defp to_quoted(p, o, cents \\ 100) do
    to_collected(p, o)
    file = %{name: "q.pdf", content_type: "application/pdf", bytes: Portal.pdf()}

    {:ok, r} =
      PrintApi.submit_quote(
        p.memory,
        o["id"],
        %{amount_cents: cents, order_revision: 1, file: file},
        pre(~s("#{o["id"]}:2"))
      )

    r.body["order"]["currentQuote"]["id"]
  end

  defp order_status(p, o) do
    {:ok, %{body: %{"order" => order}}} = PrintApi.get_order(p.memory, o["id"])
    order["status"]
  end

  defp upload(view, form, name, bytes, type \\ "application/pdf") do
    file = file_input(view, form, :file, [%{name: name, content: bytes, type: type}])
    render_upload(file, name)
  end

  describe "Pedidos" do
    test "labels, empty state, failure and Atualizar", %{portal: p} do
      {view, html} = live_page(p, "/orders")

      for label <- ["Pedidos", "Notas fiscais", "Sair", "Status", "Atualizar"],
          do: assert(html =~ label, label)

      assert html =~ "Nenhum pedido"

      # A new ready order appears on Atualizar, no push needed.
      o = Portal.seed(p)
      html = view |> form("#orders-filter") |> render_submit()
      assert html =~ o["reference"]
      assert has_element?(view, ~s(a[href="/orders/#{o["id"]}"]), "Ver pedido")

      Memory.fail_with(p.memory, :unavailable)
      html = view |> form("#orders-filter") |> render_submit()
      assert html =~ "Não foi possível consultar os pedidos"
      refute html =~ "Nenhum pedido"

      Memory.fail_with(p.memory, nil)
      html = view |> element("button", "Consultar novamente") |> render_click()
      assert html =~ o["reference"]
    end

    test "the status filter patches the URL", %{portal: p} do
      o = Portal.seed(p)
      to_collected(p, Portal.seed(p))
      {view, _html} = live_page(p, "/orders")

      view |> form("#orders-filter", %{"status" => "ready"}) |> render_change()
      assert_patch(view, "/orders?status=ready")
      assert has_element?(view, "#order-#{o["id"]}")
      assert view |> element("table.orders tbody") |> render() =~ "Pronto"
      refute view |> element("table.orders tbody") |> render() =~ "Arquivos retirados"

      view |> form("#orders-filter", %{"status" => ""}) |> render_change()
      assert_patch(view, "/orders")
    end

    test "Anterior/Próxima walk the keyset pages", %{portal: p} do
      refs =
        for i <- 1..25 do
          Portal.seed(p, created_at: DateTime.add(~U[2026-09-01 00:00:00.000Z], i))["reference"]
        end

      {view, html} = live_page(p, "/orders")
      assert html =~ Enum.at(refs, 0)
      refute html =~ Enum.at(refs, 20)

      html = view |> element("a", "Próxima") |> render_click()
      assert html =~ Enum.at(refs, 24)
      refute html =~ ~r/#{Enum.at(refs, 0)}</

      html = view |> element("a", "Anterior") |> render_click()
      assert html =~ Enum.at(refs, 0)
    end

    test "an invalid cursor and a forged back stack", %{portal: p} do
      Portal.seed(p)
      {_view, html} = live_page(p, "/orders?cursor=bogus")
      assert html =~ "Esta página da lista não vale mais."
      {_view, html} = live_page(p, "/orders?status=weird&voltar=%3Cx%3E,-")
      assert html =~ "IMP-"
    end
  end

  describe "Ver pedido" do
    test "legacy files have general instructions, no invented pairings or copies", %{portal: p} do
      original = Portal.seed(p)
      files = Enum.map(original["jobs"], & &1["file"])
      text = "Todas as instruções\n<script>não executar</script>\nSem parear por posição."

      legacy =
        original
        |> Map.put("jobs", [])
        |> Map.put("generalInstructions", %{"text" => text, "files" => files})

      Agent.update(p.memory.agent, &put_in(&1, [:orders, original["id"]], legacy))
      {view, html} = live_page(p, "/orders/#{original["id"]}")
      assert html =~ "Instruções gerais"
      assert html =~ "Todas as instruções"
      assert html =~ "&lt;script&gt;não executar&lt;/script&gt;"
      assert html =~ "Sem parear por posição."
      refute html =~ "<script>não executar</script>"
      refute html =~ "Cópias no total"
      refute has_element?(view, ".job")

      for file <- files do
        assert has_element?(
                 view,
                 ~s(a[href="/api/print/v1/orders/#{original["id"]}/files/#{file["id"]}"]),
                 "Baixar arquivo"
               )

        assert html =~ file["name"]
        {_p, download} = Portal.get(p, "/api/print/v1/orders/#{original["id"]}/files/#{file["id"]}")
        assert download.status == 200
        assert Base.encode16(:crypto.hash(:sha256, download.raw), case: :lower) == file["sha256"]
      end

      view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
      assert view |> element("#confirm-collect") |> render() =~ "os 2 arquivos"
      view |> element("#confirm-collect button", "Confirmar retirada") |> render_click()
      assert order_status(p, original) == "files_collected"
      assert has_element?(view, "#general-instructions", "Instruções gerais")
    end

    test "Arquivos retirados → orçamento → aprovado → impresso", %{portal: p} do
      o = Portal.seed(p)
      {view, html} = live_page(p, "/orders/#{o["id"]}")

      for text <- [
            o["reference"],
            "Revisão",
            "Apostila de Matemática",
            "Frente e verso, grampeado",
            "Lista de Física",
            "Baixar arquivo",
            "Conferi todos os arquivos desta revisão",
            "Arquivos retirados"
          ],
          do: assert(html =~ text, text)

      for job <- o["jobs"],
          do: assert(html =~ "/api/print/v1/orders/#{o["id"]}/files/#{job["file"]["id"]}")

      # The checkbox is the supplier's declaration: without it nothing happens.
      html = view |> form("#collect-form", %{}) |> render_submit()
      assert html =~ "Marque “Conferi todos os arquivos desta revisão”"
      refute has_element?(view, "#confirm-collect")

      view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
      assert has_element?(view, "#confirm-collect", "Confirmar retirada")
      view |> element("#confirm-collect button", "Voltar") |> render_click()
      refute has_element?(view, "#confirm-collect")
      assert order_status(p, o) == "ready"

      view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
      html = view |> element("#confirm-collect button", "Confirmar retirada") |> render_click()
      assert html =~ "Retirada confirmada."
      assert order_status(p, o) == "files_collected"

      for text <- ["Valor do orçamento", "Arquivo do orçamento", "Enviar orçamento"],
          do: assert(html =~ text, text)

      html = view |> form("#quote-form", %{"valor" => "abc"}) |> render_change()
      assert html =~ "Informe o valor do orçamento em reais"

      html = view |> form("#quote-form", %{"valor" => "1.234,56"}) |> render_submit()
      assert html =~ "Escolha o arquivo do orçamento"

      upload(view, "#quote-form", "orçamento.pdf", Portal.pdf("q"))
      view |> form("#quote-form", %{"valor" => "1.234,56"}) |> render_submit()
      assert view |> element("#confirm-quote") |> render() =~ "R$ 1.234,56"

      html = view |> element("#confirm-quote button", "Confirmar envio") |> render_click()
      assert html =~ "Orçamento enviado. Aguardando aprovação do Financeiro."
      assert html =~ "Aguardando aprovação do Financeiro"
      assert html =~ "Baixar orçamento"
      refute html =~ "Aprovar"

      {:ok, %{body: %{"order" => %{"currentQuote" => quote}}}} =
        PrintApi.get_order(p.memory, o["id"])

      assert quote["amountCents"] == 123_456

      :ok = Memory.decide_quote(p.memory, o["id"], :approved)
      {view, html} = live_page(p, "/orders/#{o["id"]}")
      assert html =~ "Orçamento aprovado"
      view |> element("button", "Marcar como impresso") |> render_click()
      assert has_element?(view, "#confirm-print", "Confirmar impressão")
      html = view |> element("#confirm-print button", "Confirmar impressão") |> render_click()
      assert html =~ "Impressão confirmada"
      assert order_status(p, o) == "printed"
    end

    test "a rejected quote shows the reason (escaped) and Enviar novo orçamento", %{portal: p} do
      o = Portal.seed(p)
      to_quoted(p, o)
      :ok = Memory.decide_quote(p.memory, o["id"], {:rejected, "Valor <acima> do combinado"})

      {_view, html} = live_page(p, "/orders/#{o["id"]}")
      assert html =~ "Valor &lt;acima&gt; do combinado"
      assert html =~ "Enviar novo orçamento"
    end

    test "a stale page gets 'Pedido atualizado; confira novamente'", %{portal: p} do
      o = Portal.seed(p)
      {stale, _} = live_page(p, "/orders/#{o["id"]}")
      {other, _} = live_page(p, "/orders/#{o["id"]}")

      # Another tab collects first.
      other |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
      other |> element("#confirm-collect button", "Confirmar retirada") |> render_click()

      stale |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
      html = stale |> element("#confirm-collect button", "Confirmar retirada") |> render_click()
      assert html =~ "Pedido atualizado; confira novamente."
      # The page re-read the order: the next step is on screen.
      assert html =~ "Valor do orçamento"
    end

    test "upstream silence: no false success; Repetir sends the same key and If-Match", %{
      portal: p
    } do
      o = Portal.seed(p)
      {view, _} = live_page(p, "/orders/#{o["id"]}")
      view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()

      Memory.fail_with(p.memory, :unavailable)
      html = view |> element("#confirm-collect button", "Confirmar retirada") |> render_click()
      assert html =~ "Sem resposta do sistema do Incluir"
      assert html =~ "Consultar novamente"
      assert html =~ "Repetir"
      refute html =~ "Retirada confirmada"

      Memory.fail_with(p.memory, nil)
      html = view |> element("button", "Repetir") |> render_click()
      assert html =~ "Retirada confirmada."
      assert [first, second] = FakeHono.commands(p.hono)
      assert second["idempotency-key"] == first["idempotency-key"]
      assert second["if-match"] == first["if-match"]
      assert order_status(p, o) == "files_collected"
    end

    test "Consultar novamente after a command that did land ends the intent", %{portal: p} do
      o = Portal.seed(p)
      {view, _} = live_page(p, "/orders/#{o["id"]}")
      view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
      Memory.fail_with(p.memory, :unavailable)
      view |> element("#confirm-collect button", "Confirmar retirada") |> render_click()
      Memory.fail_with(p.memory, nil)

      # It landed elsewhere (another tab, or the answer was lost).
      to_collected(p, o)
      html = view |> element("button", "Consultar novamente") |> render_click()
      refute html =~ "Repetir"
      assert html =~ "Valor do orçamento"
    end

    test "quote upload refusals: format, size and the upstream's verdict", %{portal: p} do
      o = Portal.seed(p)
      to_collected(p, o)
      {view, _} = live_page(p, "/orders/#{o["id"]}")

      assert {:error, [[_ref, :not_accepted]]} =
               upload(view, "#quote-form", "notas.txt", "texto", "text/plain")

      assert render(view) =~ "Formato não aceito"
      view |> element("button[phx-click=cancel-upload]") |> render_click()

      big = "%PDF-" <> :binary.copy("a", 5 * 1024 * 1024)
      assert {:error, [[_ref, :too_large]]} = upload(view, "#quote-form", "grande.pdf", big)
      assert render(view) =~ "O arquivo passa de 5 MB."
      view |> element("button[phx-click=cancel-upload]") |> render_click()

      # A .pdf that is not a PDF: the upstream's 415 is shown, nothing changes.
      upload(view, "#quote-form", "falso.pdf", "<html>")
      view |> form("#quote-form", %{"valor" => "10,00"}) |> render_submit()
      html = view |> element("#confirm-quote button", "Confirmar envio") |> render_click()
      assert html =~ "Formato não aceito. Envie PDF, JPEG, PNG ou WebP."
      assert order_status(p, o) == "files_collected"
    end

    test "print from a stale page after another tab printed: no second command", %{portal: p} do
      o = Portal.seed(p)
      qid = to_quoted(p, o)
      :ok = Memory.decide_quote(p.memory, o["id"], :approved)
      {view, _} = live_page(p, "/orders/#{o["id"]}")
      view |> element("button", "Marcar como impresso") |> render_click()

      {:ok, _} =
        PrintApi.mark_printed(
          p.memory,
          o["id"],
          %{revision: 1, quote_id: qid},
          pre(~s("#{o["id"]}:4"))
        )

      html = view |> element("#confirm-print button", "Confirmar impressão") |> render_click()
      assert html =~ "Pedido atualizado; confira novamente."
      assert html =~ "Impressão confirmada em"
    end

    test "unknown, foreign and malformed ids are a 404", %{portal: p} do
      for id <- [Ids.uuid(), "not-a-uuid"] do
        conn = get(Portal.conn(p), "/orders/#{id}")
        assert html_response(conn, 404) =~ "Não encontrado"
      end
    end

    test "the order page when the upstream is down offers Consultar novamente", %{portal: p} do
      o = Portal.seed(p)
      Memory.fail_with(p.memory, :unavailable)
      {view, html} = live_page(p, "/orders/#{o["id"]}")
      assert html =~ "Consultar novamente"
      refute html =~ "Repetir"
      Memory.fail_with(p.memory, nil)
      assert view |> element("button", "Consultar novamente") |> render_click() =~ o["reference"]
    end
  end

  describe "Notas fiscais" do
    setup do
      {:ok, clock} = Agent.start_link(fn -> ~U[2026-09-10 12:00:00Z] end)
      p = Portal.start(clock: fn -> Agent.get(clock, & &1) end)
      %{portal: Portal.signed_in(p), clock: clock}
    end

    defp printed_order(p, cents) do
      o = Portal.seed(p)
      qid = to_quoted(p, o, cents)
      :ok = Memory.decide_quote(p.memory, o["id"], :approved)

      {:ok, _} =
        PrintApi.mark_printed(
          p.memory,
          o["id"],
          %{revision: 1, quote_id: qid},
          pre(~s("#{o["id"]}:4"))
        )

      o
    end

    test "the open month explains its date; the closed month takes the NF", %{
      portal: p,
      clock: clock
    } do
      o = printed_order(p, 57_900)
      {view, html} = live_page(p, "/invoices?competencia=2026-09")

      for text <- ["Notas fiscais", "Competência", "Total calculado", "R$ 579,00", o["reference"]],
          do: assert(html =~ text, text)

      assert html =~ "O mês ainda não terminou. O envio da NF abre em 01/10/2026."
      refute has_element?(view, "#nf-form")

      Agent.update(clock, fn _ -> ~U[2026-10-02 12:00:00Z] end)
      p = Portal.signed_in(Portal.fresh(p))
      {view, html} = live_page(p, "/invoices")
      assert html =~ ~s(<option value="2026-09" selected)

      for text <- ["Valor total da NF", "Arquivo da NF", "Enviar NF"],
          do: assert(html =~ text, text)

      html = view |> form("#nf-form", %{"valor" => "x"}) |> render_change()
      assert html =~ "Informe o valor total da NF"

      upload(view, "#nf-form", "NF setembro.pdf", Portal.pdf("nf"))
      view |> form("#nf-form", %{"valor" => "570,00"}) |> render_submit()
      assert view |> element("#confirm-nf") |> render() =~ "R$ 570,00"
      html = view |> element("#confirm-nf button", "Confirmar envio") |> render_click()
      assert html =~ "NF enviada. Aguardando conferência do Financeiro."
      assert html =~ "Aguardando conferência do Financeiro. Enviada em"
      # Declared ≠ calculated: highlighted, never "fixed".
      assert html =~ "amount--diverges"
      assert html =~ "O valor declarado na NF é diferente do total calculado"
      assert html =~ "Baixar NF enviada"
    end

    test "switching the competence patches the URL", %{portal: p} do
      {view, _} = live_page(p, "/invoices")
      view |> form("#competence-form", %{"competencia" => "2026-07"}) |> render_change()
      assert_patch(view, "/invoices?competencia=2026-07")
      assert render(view) =~ "Nenhum pedido impresso em"
    end

    test "refusals and silence", %{portal: p, clock: clock} do
      Agent.update(clock, fn _ -> ~U[2026-10-02 12:00:00Z] end)
      p = Portal.signed_in(Portal.fresh(p))
      printed_order(p, 1000)
      {view, _} = live_page(p, "/invoices?competencia=2026-10")
      # The current month: no form.
      refute has_element?(view, "#nf-form")

      Agent.update(clock, fn _ -> ~U[2026-11-02 12:00:00Z] end)
      p = Portal.signed_in(Portal.fresh(p))
      {view, _} = live_page(p, "/invoices?competencia=2026-10")
      html = view |> form("#nf-form", %{"valor" => "10,00"}) |> render_submit()
      assert html =~ "Escolha o arquivo da NF"

      upload(view, "#nf-form", "nf.pdf", Portal.pdf("nf"))
      view |> form("#nf-form", %{"valor" => "10,00"}) |> render_submit()
      Memory.fail_with(p.memory, :unavailable)
      html = view |> element("#confirm-nf button", "Confirmar envio") |> render_click()
      assert html =~ "Sem resposta do sistema do Incluir"

      Memory.fail_with(p.memory, nil)
      html = view |> element("button", "Repetir") |> render_click()
      assert html =~ "NF enviada."
      assert [first, second] = FakeHono.commands(p.hono)
      assert second["idempotency-key"] == first["idempotency-key"]

      {view, html} = live_page(p, "/invoices?competencia=2026-08")
      assert html =~ "Nenhum pedido impresso"
      refute has_element?(view, "#nf-form")

      Memory.fail_with(p.memory, :unavailable)
      {_view, html} = live_page(p, "/invoices?competencia=2026-10")
      assert html =~ "Não foi possível consultar o fechamento"
      Memory.fail_with(p.memory, nil)

      FakeHono.misbehave(p.hono, :no_closes)
      {_view, html} = live_page(p, "/invoices")
      assert html =~ "Notas fiscais ainda indisponíveis."
      FakeHono.misbehave(p.hono, nil)
    end
  end

  describe "session" do
    test "without a session every page redirects to /login", %{portal: p} do
      anon = Portal.fresh(p)

      for path <- ["/orders", "/orders/#{Ids.uuid()}", "/invoices"] do
        assert {:error, {:redirect, %{to: "/login"}}} = live(Portal.conn(anon), path)
      end
    end

    test "logout revokes the session in the middle of a live page", %{portal: p} do
      o = Portal.seed(p)
      {view, _} = live_page(p, "/orders/#{o["id"]}")
      {_p, out} = Portal.command(p, :delete, "/api/session")
      assert out.status == 204

      # The next event finds no session: nothing runs, back to /login.
      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()

      assert order_status(p, o) == "ready"
    end

    test "an idle session expires in the middle of a live page" do
      {:ok, clock} = Agent.start_link(fn -> ~U[2026-09-10 12:00:00Z] end)
      p = Portal.start(clock: fn -> Agent.get(clock, & &1) end) |> Portal.signed_in()
      {view, _} = live_page(p, "/orders")

      Agent.update(clock, &DateTime.add(&1, 31 * 60))

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> form("#orders-filter") |> render_submit()
    end

    test "logout disconnects every live page of the session", %{portal: p} do
      {_p, %{body: %{"csrfToken" => _}}} = Portal.get(p, "/api/session")
      session_id = p.jar["__Host-print_session"]
      topic = Security.live_socket_id(session_id)
      Phoenix.PubSub.subscribe(Frame.PubSub, topic)

      {_p, %{status: 204}} = Portal.command(p, :delete, "/api/session")
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end
  end
end

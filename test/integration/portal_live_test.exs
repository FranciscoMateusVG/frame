defmodule Frame.Integration.PortalLiveTest do
  @moduledoc """
  The supplier pages of spec §7 through LiveView, the way a browser drives
  them (Phoenix.LiveViewTest): **Notas fiscais** (v2 monthly closes) and
  the session rules every page shares — against the upstream (FakeHono)
  over the real HTTP adapter. The batch screens have their own module
  (`Frame.Integration.PortalBatchLiveTest`).
  """
  use Frame.Test.PortalCase, async: true

  alias Frame.Adapters.PrintApi
  alias Frame.Adapters.PrintApi.Memory
  alias Frame.Test.BatchFixture
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

  defp upload(view, form, name, bytes, type \\ "application/pdf") do
    file = file_input(view, form, :file, [%{name: name, content: bytes, type: type}])
    render_upload(file, name)
  end

  describe "Notas fiscais" do
    setup do
      {:ok, clock} = Agent.start_link(fn -> ~U[2026-09-10 12:00:00Z] end)
      p = Portal.start(clock: fn -> Agent.get(clock, & &1) end)
      %{portal: Portal.signed_in(p), clock: clock}
    end

    # LOT-0001 collected, quoted, approved and printed now (the world's clock).
    defp printed_batch(p, cents) do
      batch = BatchFixture.batch("open")
      BatchFixture.seed(p.memory, batch)
      id = batch["id"]
      {:ok, _} = PrintApi.collect_batch(p.memory, id, pre(~s("#{id}:1")))
      file = %{name: "q.pdf", content_type: "application/pdf", bytes: Portal.pdf()}
      input = %{amount_cents: cents, file: file}
      {:ok, _} = PrintApi.submit_batch_quote(p.memory, id, input, pre(~s("#{id}:2")))
      :ok = Memory.decide_batch_quote(p.memory, id, :approved)
      {:ok, %{body: %{"batch" => approved}}} = PrintApi.get_batch(p.memory, id)
      quote = %{quote_id: approved["currentQuote"]["id"]}
      {:ok, _} = PrintApi.mark_batch_printed(p.memory, id, quote, pre(~s("#{id}:4")))
      batch
    end

    test "the open month explains its date; the closed month takes the NF", %{
      portal: p,
      clock: clock
    } do
      batch = printed_batch(p, 57_900)
      {view, html} = live_page(p, "/invoices?competencia=2026-09")

      for text <- ["Notas fiscais", "Competência", "Total calculado", "R$ 579,00", "LOT-0001"],
          do: assert(html =~ text, text)

      assert has_element?(view, ~s(a[href="/lotes/#{batch["id"]}"]), "LOT-0001")

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

    test "a v2 close lists batches and historical individual charges once each", %{
      portal: p,
      clock: clock
    } do
      Agent.update(clock, fn _ -> ~U[2026-10-02 12:00:00Z] end)
      p = Portal.signed_in(Portal.fresh(p))
      close = BatchFixture.monthly_close()
      Memory.put_batch_close(p.memory, close)
      [batch_item, legacy] = close["items"]

      {view, html} = live_page(p, "/invoices?competencia=2026-09")
      assert has_element?(view, ~s(a[href="/lotes/#{batch_item["batchId"]}"]), "LOT-0001")
      assert html =~ legacy["reference"]
      refute has_element?(view, "a", legacy["reference"])
      assert html =~ "R$ 459,00"
      assert html =~ "R$ 10,00"
      assert html =~ "R$ 469,00"
      assert has_element?(view, "#nf-form")
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
      printed_batch(p, 1000)
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

      for path <- ["/", "/lotes", "/lotes/#{Ids.uuid()}", "/invoices"] do
        assert {:error, {:redirect, %{to: "/login"}}} = live(Portal.conn(anon), path)
      end
    end

    test "logout revokes the session in the middle of a live page", %{portal: p} do
      batch = BatchFixture.batch("open")
      BatchFixture.seed(p.memory, batch)
      {view, _} = live_page(p, "/")
      {_p, out} = Portal.command(p, :delete, "/api/session")
      assert out.status == 204

      # The next event finds no session: nothing runs, back to /login.
      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()

      {:ok, %{body: %{"batch" => %{"status" => "open"}}}} =
        PrintApi.get_batch(p.memory, batch["id"])
    end

    test "an idle session expires in the middle of a live page" do
      {:ok, clock} = Agent.start_link(fn -> ~U[2026-09-10 12:00:00Z] end)
      p = Portal.start(clock: fn -> Agent.get(clock, & &1) end) |> Portal.signed_in()
      BatchFixture.seed(p.memory, BatchFixture.batch("open"))
      {view, _} = live_page(p, "/")

      Agent.update(clock, &DateTime.add(&1, 31 * 60))

      assert {:error, {:redirect, %{to: "/login"}}} =
               view |> form("#collect-form", %{"conferi" => "on"}) |> render_submit()
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

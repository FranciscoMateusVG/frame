defmodule Frame.Integration.PortalPagesTest do
  @moduledoc """
  The supplier journey of spec §7 through the server-rendered HTML, the way
  a browser drives it: forms with the hidden CSRF/ETag/Idempotency-Key
  fields the pages render.
  """
  use ExUnit.Case, async: true

  alias Frame.Adapters.PrintApi
  alias Frame.Test.FakeHono
  alias Frame.Test.Ids
  alias Frame.Test.Portal
  alias PrintApi.Memory

  setup do
    %{portal: Portal.start()}
  end

  # Hidden + named inputs of the form posting to `action`.
  defp form_fields(html, action) do
    [_, form] = Regex.run(~r{<form[^>]*action="#{Regex.escape(action)}"[^>]*>(.*?)</form>}s, html)

    for [_, attrs] <- Regex.scan(~r{<input([^>]*)>}, form),
        [_, name] <- [Regex.run(~r/name="([^"]+)"/, attrs) || [nil, nil]],
        name != nil,
        into: %{} do
      value =
        case Regex.run(~r/value="([^"]*)"/, attrs) do
          [_, v] -> v |> String.replace("&quot;", "\"") |> String.replace("&amp;", "&")
          _ -> ""
        end

      {name, value}
    end
  end

  defp browser_login(p) do
    {p, page} = Portal.get(p, "/login")
    assert page.status == 200
    fields = form_fields(page.raw, "/login")

    {p, r} =
      Portal.request(p, :post, "/login",
        form: Map.put(fields, "password", Portal.password()),
        headers: [{"origin", p.origin}]
      )

    assert {r.status, Portal.header(r, "location")} == {303, ["/orders"]}
    p
  end

  defp post_form(p, action, fields, extra \\ []) do
    Portal.request(p, :post, action, [form: fields, headers: [{"origin", p.origin}]] ++ extra)
  end

  test "without a session every page redirects to /login (no external returnTo)", %{portal: p} do
    for path <- ["/orders", "/orders/#{Ids.uuid()}", "/invoices"] do
      {_p, r} = Portal.get(p, path)
      assert {r.status, Portal.header(r, "location")} == {302, ["/login"]}, path
    end

    {_p, r} =
      Portal.request(p, :post, "/orders/#{Ids.uuid()}/collected",
        form: %{},
        headers: [{"origin", p.origin}]
      )

    assert {r.status, Portal.header(r, "location")} == {303, ["/login"]}
    {_p, r} = Portal.get(p, "/")
    assert Portal.header(r, "location") == ["/login"]
  end

  test "login page: labels, wrong password, success and Sair", %{portal: p} do
    {p, page} = Portal.get(p, "/login")
    for label <- ["Entrar", "Senha"], do: assert(page.raw =~ label)
    fields = form_fields(page.raw, "/login")

    {p, bad} = post_form(p, "/login", Map.put(fields, "password", "senha-errada-123"))
    assert bad.status == 401
    assert bad.raw =~ "Senha incorreta."
    refute bad.raw =~ "senha-errada-123"

    {_p, no_origin} =
      Portal.request(p, :post, "/login", form: Map.put(fields, "password", Portal.password()))

    assert no_origin.status == 403

    p = browser_login(p)
    Portal.seed(p)
    {p, orders} = Portal.get(p, "/orders")

    for label <- ["Pedidos", "Notas fiscais", "Sair", "Status", "Atualizar", "Anterior", "Próxima"],
        do: assert(orders.raw =~ label, label)

    logout = form_fields(orders.raw, "/logout")
    {p, out} = post_form(p, "/logout", logout)
    assert {out.status, Portal.header(out, "location")} == {303, ["/login"]}
    {_p, after_out} = Portal.get(p, "/orders")
    assert after_out.status == 302
  end

  test "Pedidos: empty state differs from failure; new orders appear on Atualizar", %{portal: p} do
    p = browser_login(p)
    {p, empty} = Portal.get(p, "/orders")
    assert empty.raw =~ "Nenhum pedido"

    Memory.fail_with(p.memory, :unavailable)
    {p, down} = Portal.get(p, "/orders")
    assert down.status == 503
    assert down.raw =~ "Não foi possível consultar os pedidos"
    refute down.raw =~ "Nenhum pedido"
    Memory.fail_with(p.memory, nil)

    o = Portal.seed(p)
    {_p, list} = Portal.get(p, "/orders?status=ready")
    assert list.raw =~ o["reference"]
    assert list.raw =~ "Ver pedido"
    assert list.raw =~ ~s(href="/orders/#{o["id"]}")
  end

  test "pagination Anterior/Próxima walks the keyset pages", %{portal: p} do
    p = browser_login(p)

    refs =
      for i <- 1..25 do
        Portal.seed(p, created_at: DateTime.add(~U[2026-09-01 00:00:00.000Z], i))["reference"]
      end

    {p, page1} = Portal.get(p, "/orders")
    assert page1.raw =~ Enum.at(refs, 0)
    refute page1.raw =~ Enum.at(refs, 20)
    [_, next] = Regex.run(~r/<a class="button" href="([^"]+)">Próxima/, page1.raw)
    {p, page2} = Portal.get(p, String.replace(next, "&amp;", "&"))
    assert page2.raw =~ Enum.at(refs, 24)
    refute page2.raw =~ ~r/#{Enum.at(refs, 0)}</
    [_, prev] = Regex.run(~r/<a class="button" href="([^"]+)">Anterior/, page2.raw)
    {_p, back} = Portal.get(p, String.replace(prev, "&amp;", "&"))
    assert back.raw =~ Enum.at(refs, 0)
  end

  test "Ver pedido → Arquivos retirados → orçamento → aprovado → impresso", %{portal: p} do
    p = browser_login(p)
    o = Portal.seed(p)
    path = "/orders/#{o["id"]}"

    {p, page} = Portal.get(p, path)

    for text <- [
          o["reference"],
          "Revisão",
          "Apostila de Matemática",
          "Frente e verso, grampeado",
          "Lista de Física",
          "Baixar arquivo",
          "Conferi todos os arquivos desta revisão",
          "Arquivos retirados",
          "Confirmar retirada",
          "Voltar"
        ],
        do: assert(page.raw =~ text, text)

    for job <- o["jobs"],
        do: assert(page.raw =~ "/api/print/v1/orders/#{o["id"]}/files/#{job["file"]["id"]}")

    collect = form_fields(page.raw, path <> "/collected")
    # The checkbox is the supplier's declaration: without it nothing happens.
    {p, unchecked} = post_form(p, path <> "/collected", Map.delete(collect, "conferi"))
    assert unchecked.status == 400
    assert unchecked.raw =~ "Conferi todos os arquivos"

    {p, done} = post_form(p, path <> "/collected", Map.put(collect, "conferi", "on"))
    assert {done.status, Portal.header(done, "location")} == {303, [path <> "?feito=collected"]}
    # Double submit of the same form: replayed, not an error.
    {p, twice} = post_form(p, path <> "/collected", Map.put(collect, "conferi", "on"))
    assert twice.status == 303

    {p, page} = Portal.get(p, path <> "?feito=collected")
    assert page.raw =~ "Retirada confirmada."

    for text <- [
          "Valor do orçamento",
          "Arquivo do orçamento",
          "Enviar orçamento",
          "Confirmar envio"
        ],
        do: assert(page.raw =~ text, text)

    quote = form_fields(page.raw, path <> "/quotes")
    fields = quote |> Map.delete("file") |> Map.put("valor", "1.234,56") |> Enum.to_list()

    {p, bad_amount} =
      Portal.request(p, :post, path <> "/quotes",
        multipart:
          {List.keyreplace(fields, "valor", 0, {"valor", "abc"}),
           {"o.pdf", "application/pdf", Portal.pdf("q")}},
        headers: [{"origin", p.origin}]
      )

    assert bad_amount.status == 400
    assert bad_amount.raw =~ "Informe o valor do orçamento"

    {p, sent} =
      Portal.request(p, :post, path <> "/quotes",
        multipart: {fields, {"orçamento.pdf", "application/pdf", Portal.pdf("q")}},
        headers: [{"origin", p.origin}]
      )

    assert {sent.status, Portal.header(sent, "location")} == {303, [path <> "?feito=quote"]}
    {p, page} = Portal.get(p, path)
    assert page.raw =~ "Aguardando aprovação do Financeiro"
    assert page.raw =~ "R$ 1.234,56"
    assert page.raw =~ "Baixar orçamento"
    refute page.raw =~ "Aprovar"

    {:ok, %{body: %{"order" => %{"currentQuote" => %{"amountCents" => 123_456}}}}} =
      PrintApi.get_order(p.memory, o["id"])

    :ok = Memory.decide_quote(p.memory, o["id"], :approved)
    {p, page} = Portal.get(p, path)

    for text <- ["Orçamento aprovado", "Marcar como impresso", "Confirmar impressão"],
        do: assert(page.raw =~ text)

    printed = form_fields(page.raw, path <> "/printed")
    {p, ok} = post_form(p, path <> "/printed", printed)
    assert ok.status == 303
    {_p, page} = Portal.get(p, path)
    assert page.raw =~ "Impressão confirmada em"
  end

  test "rejected quote shows the reason and Enviar novo orçamento", %{portal: p} do
    p = browser_login(p)
    o = Portal.seed(p)
    api = p.memory

    {:ok, _} =
      PrintApi.collect(api, o["id"], %{revision: 1}, %{
        if_match: ~s("#{o["id"]}:1"),
        idempotency_key: Ids.uuid()
      })

    file = %{name: "q.pdf", content_type: "application/pdf", bytes: Portal.pdf()}

    {:ok, _} =
      PrintApi.submit_quote(
        api,
        o["id"],
        %{amount_cents: 100, order_revision: 1, file: file},
        %{if_match: ~s("#{o["id"]}:2"), idempotency_key: Ids.uuid()}
      )

    :ok = Memory.decide_quote(api, o["id"], {:rejected, "Valor <acima> do combinado"})

    {_p, page} = Portal.get(p, "/orders/#{o["id"]}")
    assert page.raw =~ "Valor &lt;acima&gt; do combinado"
    assert page.raw =~ "Enviar novo orçamento"
  end

  test "a stale page gets 'Pedido atualizado; confira novamente'", %{portal: p} do
    p = browser_login(p)
    o = Portal.seed(p)
    path = "/orders/#{o["id"]}"
    {p, page} = Portal.get(p, path)
    stale = form_fields(page.raw, path <> "/collected") |> Map.put("conferi", "on")

    # Another tab collects first.
    {p, other} = Portal.get(p, path)

    {p, _} =
      post_form(
        p,
        path <> "/collected",
        form_fields(other.raw, path <> "/collected")
        |> Map.put("conferi", "on")
        |> Map.put("idempotency_key", Ids.uuid())
      )

    {_p, r} =
      post_form(p, path <> "/collected", Map.put(stale, "idempotency_key", Ids.uuid()))

    assert r.status == 412
    assert r.raw =~ "Pedido atualizado; confira novamente."
  end

  test "upstream silence: no false success, Consultar novamente + Repetir with the same key", %{
    portal: p
  } do
    p = browser_login(p)
    o = Portal.seed(p)
    path = "/orders/#{o["id"]}"
    {p, page} = Portal.get(p, path)
    fields = form_fields(page.raw, path <> "/collected") |> Map.put("conferi", "on")

    Memory.fail_with(p.memory, :unavailable)
    {p, r} = post_form(p, path <> "/collected", fields)
    assert r.status == 503
    assert r.raw =~ "Consultar novamente"
    assert r.raw =~ "Repetir"
    refute r.raw =~ "Retirada confirmada"
    retry = form_fields(r.raw, path <> "/collected")
    assert retry["idempotency_key"] == fields["idempotency_key"]
    assert retry["if_match"] == fields["if_match"]

    Memory.fail_with(p.memory, nil)
    {_p, ok} = post_form(p, path <> "/collected", retry)
    assert ok.status == 303
  end

  test "CSRF and Origin are enforced on every form", %{portal: p} do
    p = browser_login(p)
    o = Portal.seed(p)
    path = "/orders/#{o["id"]}"
    {p, page} = Portal.get(p, path)
    fields = form_fields(page.raw, path <> "/collected") |> Map.put("conferi", "on")

    {p, r} = post_form(p, path <> "/collected", Map.put(fields, "_csrf", "forged"))
    assert r.status == 403

    {p, r} =
      Portal.request(p, :post, path <> "/collected",
        form: fields,
        headers: [{"origin", "http://evil.example"}]
      )

    assert r.status == 403

    {_p, r} =
      Portal.request(p, :post, "/logout", form: %{"_csrf" => "x"}, headers: [{"origin", p.origin}])

    assert r.status == 403

    {:ok, %{body: %{"order" => %{"status" => "ready"}}}} =
      PrintApi.get_order(p.memory, o["id"])
  end

  test "Notas fiscais: open month explains the date; closed month offers Enviar NF" do
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-09-10 12:00:00Z] end)
    p = Portal.start(clock: fn -> Agent.get(clock, & &1) end)
    p = browser_login(p)
    o = Portal.seed(p)
    api = p.memory
    pre = fn etag -> %{if_match: etag, idempotency_key: Ids.uuid()} end

    {:ok, _} =
      PrintApi.collect(api, o["id"], %{revision: 1}, pre.(~s("#{o["id"]}:1")))

    file = %{name: "q.pdf", content_type: "application/pdf", bytes: Portal.pdf()}

    {:ok, q} =
      PrintApi.submit_quote(
        api,
        o["id"],
        %{amount_cents: 57_900, order_revision: 1, file: file},
        pre.(~s("#{o["id"]}:2"))
      )

    :ok = Memory.decide_quote(api, o["id"], :approved)
    qid = q.body["order"]["currentQuote"]["id"]

    {:ok, _} =
      PrintApi.mark_printed(
        api,
        o["id"],
        %{revision: 1, quote_id: qid},
        pre.(~s("#{o["id"]}:4"))
      )

    {p, page} = Portal.get(p, "/invoices?competencia=2026-09")

    for text <- [
          "Notas fiscais",
          "Competência",
          "Total calculado",
          "R$ 579,00",
          o["reference"],
          "01/10/2026"
        ],
        do: assert(page.raw =~ text, text)

    refute page.raw =~ "Enviar NF"
    assert page.raw =~ "O mês ainda não terminou"

    Agent.update(clock, fn _ -> ~U[2026-10-02 12:00:00Z] end)
    # Three weeks later the 8 h session is long gone.
    {p, expired} = Portal.get(p, "/invoices")
    assert expired.status == 302
    p = browser_login(Portal.fresh(p))
    {p, page} = Portal.get(p, "/invoices")
    assert page.raw =~ ~s(<option value="2026-09" selected>)

    for text <- ["Valor total da NF", "Arquivo da NF", "Enviar NF"],
        do: assert(page.raw =~ text, text)

    fields =
      form_fields(page.raw, "/invoices/2026-09") |> Map.delete("file") |> Map.put("valor", "570,00")

    {p, sent} =
      Portal.request(p, :post, "/invoices/2026-09",
        multipart: {Enum.to_list(fields), {"NF setembro.pdf", "application/pdf", Portal.pdf("nf")}},
        headers: [{"origin", p.origin}]
      )

    assert {sent.status, Portal.header(sent, "location")} ==
             {303, ["/invoices?competencia=2026-09&feito=nf"]}

    {_p, page} = Portal.get(p, "/invoices?competencia=2026-09&feito=nf")
    assert page.raw =~ "Aguardando conferência"
    assert page.raw =~ "diferente do total calculado"
    assert page.raw =~ "Baixar NF enviada"
  end

  test "Notas fiscais ainda indisponíveis when the upstream lacks the close routes", %{portal: p} do
    p = browser_login(p)
    FakeHono.misbehave(p.hono, :no_closes)
    {_p, page} = Portal.get(p, "/invoices?competencia=2026-09")
    assert page.status == 200
    assert page.raw =~ "Notas fiscais ainda indisponíveis."
    refute page.raw =~ "Enviar NF"
  end

  test "404 page and static assets", %{portal: p} do
    {_p, r} = Portal.get(p, "/nada")
    assert r.status == 404
    assert r.raw =~ "Não encontrado"
    {_p, css} = Portal.get(p, "/assets/app.css")
    assert css.status == 200
    {_p, missing} = Portal.get(p, "/assets/x.js")
    assert missing.status == 404
  end
end

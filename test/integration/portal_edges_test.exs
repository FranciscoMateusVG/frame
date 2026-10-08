defmodule Frame.Integration.PortalEdgesTest do
  @moduledoc """
  Edge and failure paths of the HTML pages and the multipart/IP plumbing,
  through the running portal.
  """
  use ExUnit.Case, async: true

  alias Frame.Adapters.PrintApi
  alias Frame.Adapters.PrintApi.Memory
  alias Frame.Test.FakeHono
  alias Frame.Test.Ids
  alias Frame.Test.Portal

  setup do
    %{portal: Portal.start()}
  end

  defp signed_in(p) do
    {p, page} = Portal.get(p, "/login")
    [_, csrf] = Regex.run(~r/name="_csrf" value="([^"]+)"/, page.raw)

    {p, r} =
      Portal.request(p, :post, "/login",
        form: %{"_csrf" => csrf, "password" => Portal.password()},
        headers: [{"origin", p.origin}]
      )

    assert r.status == 303
    {p, orders} = Portal.get(p, "/orders")
    [_, csrf] = Regex.run(~r/name="_csrf" value="([^"]+)"/, orders.raw)
    %{p | csrf: csrf}
  end

  defp hidden(html, action) do
    [_, form] = Regex.run(~r{<form[^>]*action="#{Regex.escape(action)}"[^>]*>(.*?)</form>}s, html)

    for [_, name, value] <-
          Regex.scan(~r/<input type="hidden" name="([^"]+)" value="([^"]*)"/, form),
        into: %{},
        do: {name, String.replace(value, "&quot;", "\"")}
  end

  defp post(p, path, opts),
    do: Portal.request(p, :post, path, [headers: [{"origin", p.origin}]] ++ opts)

  defp to_collected(p, o) do
    pre = %{if_match: ~s("#{o["id"]}:1"), idempotency_key: Ids.uuid()}
    {:ok, _} = PrintApi.collect(p.memory, o["id"], %{revision: 1}, pre)
  end

  test "signed-in redirects, unknown routes and methods", %{portal: p} do
    p = signed_in(p)
    {_p, r} = Portal.get(p, "/")
    assert Portal.header(r, "location") == ["/orders"]
    {_p, r} = Portal.get(p, "/login")
    assert Portal.header(r, "location") == ["/orders"]
    {_p, r} = Portal.request(p, :put, "/orders")
    assert {r.status, Portal.header(r, "allow")} == {405, ["GET, POST"]}

    {_p, r} =
      Portal.request(p, :post, "/orders/#{Ids.uuid()}/delete", headers: [{"origin", p.origin}])

    assert r.status == 404
    {_p, r} = Portal.get(p, "/orders/not-a-uuid")
    assert r.status == 404
    {_p, r} = Portal.get(p, "/orders/#{Ids.uuid()}")
    assert r.status == 404
  end

  test "login/logout refusals", %{portal: p} do
    {_p, r} = post(p, "/login", form: %{"_csrf" => "x", "password" => Portal.password()})
    assert r.status == 403
    {_p, r} = post(p, "/login", raw: {"text/plain", "password=x"})
    assert r.status == 403
    {_p, r} = post(p, "/logout", form: %{"_csrf" => "x"})
    assert {r.status, Portal.header(r, "location")} == {303, ["/login"]}
    {_p, r} = Portal.request(p, :post, "/logout", form: %{})
    assert r.status == 403
  end

  test "orders page: invalid cursor, unknown filter, bad back stack", %{portal: p} do
    p = signed_in(p)
    Portal.seed(p)
    {_p, r} = Portal.get(p, "/orders?cursor=bogus")
    assert r.raw =~ "Esta página da lista não vale mais."
    {_p, r} = Portal.get(p, "/orders?status=weird&voltar=%3Cx%3E,-")
    assert r.status == 200
    assert r.raw =~ "IMP-"
  end

  test "order page when the upstream is down: retry page", %{portal: p} do
    p = signed_in(p)
    o = Portal.seed(p)
    Memory.fail_with(p.memory, :unavailable)
    {_p, r} = Portal.get(p, "/orders/#{o["id"]}")
    assert r.status == 503
    assert r.raw =~ "Consultar novamente"
    refute r.raw =~ "Repetir"
  end

  test "quote form: missing file, upstream 415, oversize, silence → retry without resend", %{
    portal: p
  } do
    p = signed_in(p)
    o = Portal.seed(p)
    to_collected(p, o)
    path = "/orders/#{o["id"]}"
    {p, page} = Portal.get(p, path)
    fields = hidden(page.raw, path <> "/quotes") |> Map.put("valor", "100,00") |> Enum.to_list()

    {p, r} = post(p, path <> "/quotes", multipart: {fields, nil})
    assert r.status == 400

    {p, r} = post(p, path <> "/quotes", multipart: {fields, {"x.pdf", "application/pdf", ""}})
    assert {r.status, r.raw =~ "Escolha o arquivo do orçamento"} == {400, true}

    {p, r} = post(p, path <> "/quotes", multipart: {fields, {"x.pdf", "application/pdf", "<html>"}})
    assert r.status == 415
    assert r.raw =~ "Formato não aceito"

    big = {"b.pdf", "application/pdf", "%PDF-" <> :binary.copy("a", 5 * 1024 * 1024)}
    {p, r} = post(p, path <> "/quotes", multipart: {fields, big})
    assert r.status == 413

    huge = {"b.pdf", "application/pdf", :binary.copy("a", 6 * 1024 * 1024)}
    {p, r} = post(p, path <> "/quotes", multipart: {fields, huge})
    assert r.status == 413
    assert r.raw =~ "5 MB"

    Memory.fail_with(p.memory, :unavailable)

    {_p, r} =
      post(p, path <> "/quotes", multipart: {fields, {"o.pdf", "application/pdf", Portal.pdf()}})

    assert r.status == 503
    assert r.raw =~ "chave="
    refute r.raw =~ "Repetir"
  end

  test "printed form with a forged quote id; invalid preconditions", %{portal: p} do
    p = signed_in(p)
    o = Portal.seed(p)
    path = "/orders/#{o["id"]}"
    {p, page} = Portal.get(p, path)
    fields = hidden(page.raw, path <> "/collected")

    {p, r} = post(p, path <> "/printed", form: Map.put(fields, "quote_id", "x"))
    assert r.status == 400

    {p, r} =
      post(p, path <> "/collected",
        form: Map.merge(fields, %{"conferi" => "on", "if_match" => "bad"})
      )

    assert r.status == 400
    {_p, r} = post(p, path <> "/printed", form: Map.put(fields, "quote_id", Ids.uuid()))
    assert r.status == 409
    assert r.raw =~ "não está mais disponível"
  end

  test "invoice form: refusals and failures", %{portal: p} do
    p = signed_in(p)
    {p, page} = Portal.get(p, "/invoices")
    assert page.status == 200
    action = "/invoices/2026-09"

    fields = [
      {"_csrf", p.csrf},
      {"if_match", ~s("month:2026-09:0")},
      {"idempotency_key", Ids.uuid()},
      {"valor", "10,00"}
    ]

    nf = {"nf.pdf", "application/pdf", Portal.pdf("nf")}

    {p, r} = post(p, action, multipart: {fields, nf})
    assert r.status == 409
    assert r.raw =~ "Não há pedidos impressos"
    {p, r} = post(p, action, multipart: {List.keyreplace(fields, "valor", 0, {"valor", "x"}), nf})
    assert {r.status, r.raw =~ "valor total da NF"} == {400, true}
    {p, r} = post(p, action, multipart: {fields, {"nf.pdf", "application/pdf", ""}})
    assert r.status == 400
    {p, r} = post(p, action, multipart: {List.keyreplace(fields, "_csrf", 0, {"_csrf", "x"}), nf})
    assert r.status == 403
    {p, r} = post(p, "/invoices/2026-13", multipart: {fields, nf})
    assert r.status == 404
    {p, r} = post(p, action, multipart: {List.keydelete(fields, "if_match", 0), nf})
    assert r.status == 400

    {p, r} =
      post(p, action,
        multipart: {fields, {"big.pdf", "application/pdf", :binary.copy("a", 6 * 1024 * 1024)}}
      )

    assert r.status == 413

    Memory.fail_with(p.memory, :unavailable)
    {p, r} = post(p, action, multipart: {fields, nf})
    assert r.status == 503
    assert r.raw =~ "Consultar novamente"
    {_p, r} = Portal.get(p, "/invoices?competencia=2026-09")
    assert r.status == 503
    assert r.raw =~ "Não foi possível consultar o fechamento"
  end

  test "multipart edge cases are 400, never a crash", %{portal: p} do
    {p, _} = Portal.login(p)
    o = Portal.seed(p)
    path = "/api/print/v1/orders/#{o["id"]}/quotes"
    pre = [{"if-match", ~s("#{o["id"]}:1")}, {"idempotency-key", Ids.uuid()}]

    bodies = [
      {"multipart/form-data", "--x\r\n"},
      {"multipart/form-data; boundary=x",
       "--x\r\ncontent-disposition: form-data\r\n\r\nv\r\n--x--\r\n"},
      {"multipart/form-data; boundary=x",
       "--x\r\ncontent-disposition: form-data; name=\"a\"\r\n\r\n" <>
         <<0xFF, 0xFE>> <> "\r\n--x--\r\n"},
      {"multipart/form-data; boundary=x",
       Enum.map_join(1..9, fn i ->
         "--x\r\ncontent-disposition: form-data; name=\"f#{i}\"\r\n\r\nv\r\n"
       end) <> "--x--\r\n"},
      {"multipart/form-data; boundary=x",
       "--x\r\ncontent-disposition: form-data; name=\"amountCents\"\r\n\r\n1"}
    ]

    for {type, body} <- bodies do
      {_p, r} = Portal.command(p, :post, path, raw: {type, body}, headers: pre)
      assert r.status == 400, "#{r.status} #{r.raw} #{inspect(body)}"
    end
  end

  test "an oversized chunked upload (no Content-Length) is cut at the cap", %{portal: p} do
    {p, _} = Portal.login(p)
    o = Portal.seed(p)
    boundary = "cap"

    head =
      "--#{boundary}\r\ncontent-disposition: form-data; name=\"file\"; filename=\"a.pdf\"\r\n\r\n"

    chunk = :binary.copy("a", 1024 * 1024)
    stream = Stream.concat([[head], Stream.repeatedly(fn -> chunk end) |> Stream.take(7)])

    headers = [
      {"origin", p.origin},
      {"x-csrf-token", p.csrf},
      {"cookie", "__Host-print_session=#{p.jar["__Host-print_session"]}"},
      {"content-type", "multipart/form-data; boundary=#{boundary}"},
      {"if-match", ~s("#{o["id"]}:1")},
      {"idempotency-key", Ids.uuid()}
    ]

    req =
      Finch.build(
        :post,
        "http://127.0.0.1:#{p.port}/api/print/v1/orders/#{o["id"]}/quotes",
        headers,
        {:stream, stream}
      )

    case Finch.request(req, p.finch) do
      {:ok, resp} -> assert resp.status == 413
      # The portal may answer and close before the client finishes sending.
      {:error, _closed} -> :ok
    end

    assert FakeHono.request_count(p.hono) == 0
  end

  test "IPv6 and malformed X-Forwarded-For from a trusted proxy" do
    {:ok, trusted} = Frame.Config.cidrs("127.0.0.0/8, ::1/128")
    p = Portal.start(trusted_proxies: trusted, limits: %{per_ip: 1})
    {_p, r} = Portal.login(p, "senha-errada-123")
    assert r.status == 401

    fresh = Portal.fresh(p)
    {fresh, %{body: %{"csrfToken" => csrf}}} = Portal.get(fresh, "/api/session")

    login = fn xff ->
      Portal.request(fresh, :post, "/api/session",
        json: %{password: Portal.password()},
        headers: [{"origin", p.origin}, {"x-csrf-token", csrf}, {"x-forwarded-for", xff}]
      )
    end

    # Garbage in XFF falls back to the peer, which is already blocked.
    {_p, r} = login.("not-an-ip")
    assert r.status == 429
    {_p, r} = login.("2001:db8::1, 127.0.0.1")
    assert r.status == 200
  end
end

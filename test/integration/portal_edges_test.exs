defmodule Frame.Integration.PortalEdgesTest do
  @moduledoc """
  The browser's controllers (login, logout, redirects), unknown routes and
  methods, and the edge cases of the multipart/IP plumbing of the JSON API.
  """
  use Frame.Test.PortalCase, async: true

  alias Frame.Test.FakeHono
  alias Frame.Web.Edge

  setup do
    %{portal: Portal.start()}
  end

  defp login_form(p) do
    {p, page} = Portal.get(p, "/login")
    assert page.status == 200
    [_, csrf] = Regex.run(~r/name="_csrf" value="([^"]+)"/, page.raw)
    {p, page, csrf}
  end

  defp send_post(p, path, opts),
    do: Portal.request(p, :post, path, [headers: [{"origin", p.origin}]] ++ opts)

  test "login page: labels, wrong password, no Origin, success and Sair", %{portal: p} do
    {p, page, csrf} = login_form(p)
    for label <- ["Entrar", "Senha"], do: assert(page.raw =~ label)
    assert Portal.header(page, "referrer-policy") == ["same-origin"]
    # The login page loads no script and opens no socket.
    refute page.raw =~ "<script"

    {p, bad} = send_post(p, "/login", form: %{"_csrf" => csrf, "password" => "senha-errada-123"})
    assert bad.status == 401
    assert bad.raw =~ "Senha incorreta."
    refute bad.raw =~ "senha-errada-123"

    {p, no_origin} =
      Portal.request(p, :post, "/login", form: %{"_csrf" => csrf, "password" => Portal.password()})

    assert no_origin.status == 403

    {p, ok} = send_post(p, "/login", form: %{"_csrf" => csrf, "password" => Portal.password()})
    assert {ok.status, Portal.header(ok, "location")} == {303, ["/orders"]}
    assert p.jar["__Host-print_session"]
    refute p.jar["__Host-print_presession"]

    {p, orders} = Portal.get(p, "/orders")
    assert orders.status == 200
    assert orders.raw =~ ~s(<meta name="csrf-token")
    assert orders.raw =~ ~s(src="/assets/phoenix_live_view.min.js")
    [_, csrf] = Regex.run(~r/name="_csrf" value="([^"]+)"/, orders.raw)

    {p, out} = send_post(p, "/logout", form: %{"_csrf" => csrf})
    assert {out.status, Portal.header(out, "location")} == {303, ["/login"]}
    {_p, after_out} = Portal.get(p, "/orders")
    assert {after_out.status, Portal.header(after_out, "location")} == {302, ["/login"]}
  end

  test "login is rate limited per address with Retry-After", %{portal: p} do
    p = Portal.from_ip(p, {203, 0, 113, 9})
    {p, _page, csrf} = login_form(p)

    statuses =
      for _ <- 1..6 do
        {_p, r} = send_post(p, "/login", form: %{"_csrf" => csrf, "password" => "senha-errada-123"})
        r
      end

    assert Enum.map(statuses, & &1.status) == [401, 401, 401, 401, 401, 429]
    assert [_] = Portal.header(List.last(statuses), "retry-after")
    assert List.last(statuses).raw =~ "Muitas tentativas"
  end

  test "signed-in redirects, unknown routes and methods", %{portal: p} do
    {_p, r} = Portal.get(p, "/")
    assert {r.status, Portal.header(r, "location")} == {302, ["/login"]}

    p = Portal.signed_in(p)
    {_p, r} = Portal.get(p, "/")
    assert Portal.header(r, "location") == ["/orders"]
    {_p, r} = Portal.get(p, "/login")
    assert Portal.header(r, "location") == ["/orders"]

    {_p, r} = Portal.request(p, :put, "/orders")
    assert {r.status, Portal.header(r, "allow")} == {405, ["GET"]}
    {_p, r} = Portal.request(p, :get, "/logout")
    assert {r.status, Portal.header(r, "allow")} == {405, ["POST"]}

    # The old form endpoints are gone: commands run over the socket.
    {_p, r} = send_post(p, "/orders/#{Ids.uuid()}/collected", form: %{})
    assert r.status == 404
    {_p, r} = Portal.get(p, "/nada")
    assert r.status == 404
    assert r.raw =~ "Não encontrado"
    {_p, r} = Portal.get(p, "/assets/secret.txt")
    assert r.status == 404
  end

  test "assets are served with their types", %{portal: p} do
    for {file, type} <- [
          {"app.css", "text/css"},
          {"app.js", "text/javascript"},
          {"phoenix.min.js", "text/javascript"},
          {"phoenix_live_view.min.js", "text/javascript"}
        ] do
      {_p, r} = Portal.get(p, "/assets/#{file}")
      assert r.status == 200, file
      assert [content_type] = Portal.header(r, "content-type")
      assert content_type =~ type
    end
  end

  test "the edge is a plain plug: hardening headers and request id on any conn", %{portal: p} do
    conn =
      Phoenix.ConnTest.build_conn(:get, "/assets/app.css")
      |> Plug.Conn.put_private(:frame_deps, p.deps)
      |> Edge.call(Edge.init([]))

    assert conn.status == 200
    assert [_] = Plug.Conn.get_resp_header(conn, "x-request-id")
    assert Plug.Conn.get_resp_header(conn, "x-frame-options") == ["DENY"]
    [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")
    assert csp =~ "script-src 'self'"
    assert csp =~ "connect-src 'self'"
  end

  test "login/logout refusals", %{portal: p} do
    {_p, r} = send_post(p, "/login", form: %{"_csrf" => "x", "password" => Portal.password()})
    assert r.status == 403
    {_p, r} = send_post(p, "/login", raw: {"text/plain", "password=x"})
    assert r.status == 403
    {_p, r} = send_post(p, "/logout", form: %{"_csrf" => "x"})
    assert {r.status, Portal.header(r, "location")} == {303, ["/login"]}
    {_p, r} = Portal.request(p, :post, "/logout", form: %{})
    assert r.status == 403

    p = Portal.signed_in(p)
    {_p, r} = send_post(p, "/logout", form: %{"_csrf" => "forged"})
    assert r.status == 403
    {_p, r} = Portal.request(p, :post, "/logout", form: %{"_csrf" => p.csrf})
    assert r.status == 403
    {_p, r} = Portal.get(p, "/orders")
    assert r.status == 200
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

  test "an oversized upload without Content-Length is cut at the cap", %{portal: p} do
    {p, _} = Portal.login(p)
    o = Portal.seed(p)
    boundary = "cap"

    body =
      ~s(--#{boundary}\r\ncontent-disposition: form-data; name="file"; filename="a.pdf"\r\n\r\n) <>
        :binary.copy("a", 7 * 1024 * 1024)

    {_p, r} =
      Portal.command(p, :post, "/api/print/v1/orders/#{o["id"]}/quotes",
        raw: {"multipart/form-data; boundary=#{boundary}", body},
        headers: [{"if-match", ~s("#{o["id"]}:1")}, {"idempotency-key", Ids.uuid()}]
      )

    assert r.status == 413
    assert FakeHono.request_count(p.hono) == 0
  end

  test "a declared Content-Length over the cap is refused before reading", %{portal: p} do
    {p, _} = Portal.login(p)
    o = Portal.seed(p)

    {_p, r} =
      Portal.command(p, :post, "/api/print/v1/orders/#{o["id"]}/quotes",
        raw: {"multipart/form-data; boundary=x", "--x--\r\n"},
        headers: [
          {"content-length", "#{6 * 1024 * 1024}"},
          {"if-match", ~s("#{o["id"]}:1")},
          {"idempotency-key", Ids.uuid()}
        ]
      )

    assert r.status == 413
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

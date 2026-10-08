defmodule Frame.Integration.PortalApiTest do
  @moduledoc """
  Black-box tests of the portal's JSON API (spec §4.5, §5, §8): real Bandit,
  real HTTP adapter, real session store and limiter, fake Hono over HTTP.
  """
  use ExUnit.Case, async: true

  alias Frame.Adapters.PrintApi.Memory
  alias Frame.Domain.Competence
  alias Frame.Domain.Session
  alias Frame.Test.FakeHono
  alias Frame.Test.Ids
  alias Frame.Test.Portal

  setup do
    %{portal: Portal.start()}
  end

  defp code(resp), do: resp.body["error"]["code"]

  describe "session" do
    test "GET /api/session issues a host-only pre-session cookie and a CSRF token", %{portal: p} do
      {p, resp} = Portal.get(p, "/api/session")
      assert resp.status == 200
      assert %{"authenticated" => false, "csrfToken" => csrf, "expiresAt" => nil} = resp.body
      assert byte_size(csrf) >= 43
      assert [cookie] = Portal.header(resp, "set-cookie")
      assert cookie =~ ~r/^__Host-print_presession=[A-Za-z0-9_-]{43};/
      for flag <- ["path=/", "secure", "HttpOnly", "SameSite=Lax"], do: assert(cookie =~ flag)
      refute cookie =~ ~r/domain/i
      assert Portal.header(resp, "cache-control") == ["no-store"]

      # Same browser: same pre-session, no new cookie.
      {_p, again} = Portal.get(p, "/api/session")
      assert again.body["csrfToken"] == csrf
      assert Portal.header(again, "set-cookie") == []
    end

    test "login rotates: new session cookie, new CSRF token, pre-session dropped", %{portal: p} do
      {p, pre} = Portal.get(p, "/api/session")
      pre_cookie = p.jar["__Host-print_presession"]
      {p, resp} = Portal.login(p)
      assert resp.status == 200
      assert %{"authenticated" => true, "csrfToken" => csrf, "expiresAt" => expires} = resp.body
      assert csrf != pre.body["csrfToken"]
      assert {:ok, _, 0} = DateTime.from_iso8601(expires)
      assert p.jar["__Host-print_session"] not in [nil, pre_cookie]
      refute Map.has_key?(p.jar, "__Host-print_presession")

      [session_cookie] =
        resp
        |> Portal.header("set-cookie")
        |> Enum.filter(&String.starts_with?(&1, "__Host-print_session"))

      for flag <- ["path=/", "secure", "HttpOnly", "SameSite=Lax"],
          do: assert(session_cookie =~ flag)

      {_p, me} = Portal.get(p, "/api/session")
      assert me.body["authenticated"] == true
      assert me.body["csrfToken"] == csrf

      # The old pre-session cannot be replayed to log in again.
      replay = %{p | jar: %{"__Host-print_presession" => pre_cookie}}

      {_p, r} =
        Portal.request(replay, :post, "/api/session",
          json: %{password: Portal.password()},
          headers: [{"origin", p.origin}, {"x-csrf-token", pre.body["csrfToken"]}]
        )

      assert {r.status, code(r)} == {403, "CSRF_FAILED"}
    end

    test "wrong password: 401 INVALID_CREDENTIALS, nothing echoed", %{portal: p} do
      {_p, resp} = Portal.login(p, "senha-errada-123")
      assert {resp.status, code(resp)} == {401, "INVALID_CREDENTIALS"}
      refute resp.raw =~ "senha-errada-123"
    end

    test "login requires exact Origin, the pre-session and its CSRF token", %{portal: p} do
      {p, %{body: %{"csrfToken" => csrf}}} = Portal.get(p, "/api/session")
      body = [json: %{password: Portal.password()}]

      for headers <- [
            [{"x-csrf-token", csrf}],
            [{"origin", "http://evil.example"}, {"x-csrf-token", csrf}],
            [{"origin", p.origin <> "/"}, {"x-csrf-token", csrf}],
            [{"origin", p.origin}],
            [{"origin", p.origin}, {"x-csrf-token", csrf <> "x"}]
          ] do
        {_p, r} = Portal.request(p, :post, "/api/session", [headers: headers] ++ body)
        assert {r.status, code(r)} == {403, "CSRF_FAILED"}, inspect(headers)
      end

      {_p, r} =
        Portal.request(
          Portal.fresh(p),
          :post,
          "/api/session",
          [headers: [{"origin", p.origin}, {"x-csrf-token", csrf}]] ++ body
        )

      assert {r.status, code(r)} == {403, "CSRF_FAILED"}
    end

    test "malformed login bodies are 400 without echo", %{portal: p} do
      {p, %{body: %{"csrfToken" => csrf}}} = Portal.get(p, "/api/session")
      h = [{"origin", p.origin}, {"x-csrf-token", csrf}]

      for opts <- [
            [raw: {"application/json", "\"senha\""}],
            [raw: {"application/json", "{\"password\":"}],
            [raw: {"application/json", "[1]"}],
            [json: %{password: "x", role: "admin"}],
            [form: %{password: "x"}]
          ] do
        {_p, r} = Portal.request(p, :post, "/api/session", [headers: h] ++ opts)
        assert {r.status, code(r)} == {400, "INVALID_REQUEST"}, inspect(opts)
      end
    end

    test "the 6th invalid attempt is rate limited with Retry-After; XFF does not bypass", %{
      portal: p
    } do
      for _ <- 1..5 do
        {_p, r} = Portal.login(Portal.fresh(p), "senha-errada-123")
        assert r.status == 401
      end

      {_p, r} = Portal.login(Portal.fresh(p), "senha-errada-123")
      assert {r.status, code(r)} == {429, "RATE_LIMITED"}
      assert [retry] = Portal.header(r, "retry-after")
      assert String.to_integer(retry) in 1..900

      # Even the right password, even with a forged X-Forwarded-For.
      fresh = Portal.fresh(p)
      {fresh, %{body: %{"csrfToken" => csrf}}} = Portal.get(fresh, "/api/session")

      {_p, r} =
        Portal.request(fresh, :post, "/api/session",
          json: %{password: Portal.password()},
          headers: [{"origin", p.origin}, {"x-csrf-token", csrf}, {"x-forwarded-for", "9.9.9.9"}]
        )

      assert {r.status, code(r)} == {429, "RATE_LIMITED"}
    end

    test "X-Forwarded-For is honoured only from a trusted proxy" do
      {:ok, trusted} = Frame.Config.cidrs("127.0.0.1/32")
      p = Portal.start(trusted_proxies: trusted, limits: %{per_ip: 2})

      for _ <- 1..2 do
        {_p, r} = Portal.login(Portal.fresh(p), "senha-errada-123")
        assert r.status == 401
      end

      # Behind the trusted proxy, another client address is another bucket.
      fresh = Portal.fresh(p)
      {fresh, %{body: %{"csrfToken" => csrf}}} = Portal.get(fresh, "/api/session")

      {_p, r} =
        Portal.request(fresh, :post, "/api/session",
          json: %{password: Portal.password()},
          headers: [
            {"origin", p.origin},
            {"x-csrf-token", csrf},
            {"x-forwarded-for", "203.0.113.7"}
          ]
        )

      assert r.status == 200
    end

    test "logout revokes immediately; repeating it reveals nothing", %{portal: p} do
      {p, _} = Portal.login(p)
      {p, r} = Portal.command(p, :delete, "/api/session")
      assert r.status == 204
      {_p, r} = Portal.get(p, "/api/print/v1/orders")
      assert {r.status, code(r)} == {401, "UNAUTHENTICATED"}
      {_p, r} = Portal.command(p, :delete, "/api/session")
      assert r.status == 204
      {_p, r} = Portal.request(p, :delete, "/api/session")
      assert {r.status, code(r)} == {403, "CSRF_FAILED"}
    end

    test "logout with a session but without its CSRF token is refused", %{portal: p} do
      {p, _} = Portal.login(p)
      {_p, r} = Portal.request(p, :delete, "/api/session", headers: [{"origin", p.origin}])
      assert {r.status, code(r)} == {403, "CSRF_FAILED"}
      {_p, still} = Portal.get(p, "/api/print/v1/orders")
      assert still.status == 200
    end

    test "idle and absolute expiry (shortened policy)" do
      {:ok, clock} = Agent.start_link(fn -> ~U[2026-10-08 12:00:00Z] end)
      policy = Session.policy(idle_seconds: 60, absolute_seconds: 150)
      p = Portal.start(clock: fn -> Agent.get(clock, & &1) end, session_policy: policy)
      {p, _} = Portal.login(p)
      advance = fn s -> Agent.update(clock, &DateTime.add(&1, s)) end

      advance.(50)
      assert {_, %{status: 200}} = Portal.get(p, "/api/print/v1/orders")
      advance.(50)
      assert {_, %{status: 200}} = Portal.get(p, "/api/print/v1/orders")
      advance.(55)
      assert {_, %{status: 401}} = Portal.get(p, "/api/print/v1/orders")

      {p, _} = Portal.login(Portal.fresh(p))
      advance.(61)
      assert {_, %{status: 401}} = Portal.get(p, "/api/print/v1/orders")
      assert {_, %{body: %{"authenticated" => false}}} = Portal.get(p, "/api/session")
    end

    test "unsupported methods on /api/session", %{portal: p} do
      {_p, r} = Portal.request(p, :put, "/api/session")
      assert {r.status, code(r)} == {405, "METHOD_NOT_ALLOWED"}
    end
  end

  describe "/api/print/v1" do
    setup %{portal: p} do
      {p, _} = Portal.login(p)
      %{portal: p, order: Portal.seed(p)}
    end

    test "requires a session", %{portal: p} do
      {_p, r} = Portal.get(Portal.fresh(p), "/api/print/v1/orders")
      assert {r.status, code(r)} == {401, "UNAUTHENTICATED"}
    end

    test "lists and reads orders with the ETag", %{portal: p, order: o} do
      {_p, r} = Portal.get(p, "/api/print/v1/orders?status=ready&limit=5")
      assert r.status == 200
      assert [%{"id" => id, "status" => "ready"}] = r.body["items"]
      assert id == o["id"]

      {_p, r} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}")
      assert r.status == 200
      assert Portal.header(r, "etag") == [~s("#{o["id"]}:1")]
      assert r.body["order"]["jobs"] |> Enum.map(& &1["copies"]) == [2, 7]

      for q <- ["?limit=0", "?limit=101", "?status=awaiting_readiness"] do
        {_p, r} = Portal.get(p, "/api/print/v1/orders" <> q)
        assert {r.status, code(r)} == {400, "INVALID_REQUEST"}, q
      end

      {_p, r} = Portal.get(p, "/api/print/v1/orders?cursor=bogus")
      assert {r.status, code(r)} == {400, "INVALID_CURSOR"}
    end

    test "unknown ids are 404; unlisted methods 405; unknown routes 404", %{portal: p, order: o} do
      {_p, r} = Portal.get(p, "/api/print/v1/orders/#{Ids.uuid()}")
      assert {r.status, code(r)} == {404, "NOT_FOUND"}
      {_p, r} = Portal.get(p, "/api/print/v1/orders/..%2F..%2Fadmin")
      assert r.status == 404
      {_p, r} = Portal.command(p, :delete, "/api/print/v1/orders/#{o["id"]}")
      assert {r.status, code(r)} == {405, "METHOD_NOT_ALLOWED"}
      assert Portal.header(r, "allow") == ["GET"]
      {_p, r} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}/collected")
      assert r.status == 405
      {_p, r} = Portal.get(p, "/api/print/v1/admin")
      assert r.status == 404
      {_p, r} = Portal.get(p, "/api/print/v2/orders")
      assert r.status == 404
    end

    test "downloads stream the right bytes with safe headers; GET does not collect", %{
      portal: p,
      order: o
    } do
      [j1, j2] = o["jobs"]
      {_p, r} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}/files/#{j2["file"]["id"]}")
      assert r.status == 200
      assert :crypto.hash(:sha256, r.raw) |> Base.encode16(case: :lower) == j2["file"]["sha256"]
      assert Portal.header(r, "content-type") == ["application/pdf"]
      assert Portal.header(r, "content-length") == ["#{byte_size(r.raw)}"]
      assert Portal.header(r, "x-content-type-options") == ["nosniff"]
      assert Portal.header(r, "cache-control") == ["private, no-store"]
      assert [disposition] = Portal.header(r, "content-disposition")
      assert disposition =~ ~s(attachment; filename=")
      assert disposition =~ "filename*=UTF-8''f%C3%ADsica%20final.pdf"

      {_p, r1} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}/files/#{j1["file"]["id"]}")
      assert :crypto.hash(:sha256, r1.raw) |> Base.encode16(case: :lower) == j1["file"]["sha256"]

      {_p, r} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}")
      assert r.body["order"]["status"] == "ready"

      other = Portal.seed(p)
      {_p, r} = Portal.get(p, "/api/print/v1/orders/#{other["id"]}/files/#{j1["file"]["id"]}")
      assert {r.status, code(r)} == {404, "NOT_FOUND"}
    end

    test "full journey: collect → quote → approval (staff) → printed → close", %{
      portal: p,
      order: o
    } do
      etag = ~s("#{o["id"]}:1")
      key = Ids.uuid()

      collect = fn p, key, etag ->
        Portal.command(p, :post, "/api/print/v1/orders/#{o["id"]}/collected",
          json: %{revision: 1},
          headers: [{"if-match", etag}, {"idempotency-key", key}]
        )
      end

      {p, r} = collect.(p, key, etag)
      assert r.status == 200
      assert Portal.header(r, "etag") == [~s("#{o["id"]}:2")]
      assert r.body["order"]["status"] == "files_collected"

      # Double click: same key → original answer, flagged as replay.
      {p, again} = collect.(p, key, etag)
      assert {again.status, again.body} == {200, r.body}
      assert Portal.header(again, "idempotency-replayed") == ["true"]

      # Another tab with the stale ETag and a new key: 412.
      {p, stale} = collect.(p, Ids.uuid(), etag)
      assert {stale.status, code(stale)} == {412, "VERSION_MISMATCH"}
      # Same key, different intent: 409.
      {p, conflict} = collect.(p, key, ~s("#{o["id"]}:2"))
      assert {conflict.status, code(conflict)} == {409, "IDEMPOTENCY_CONFLICT"}

      # Printing before an approved quote: 409.
      {p, early} =
        Portal.command(p, :post, "/api/print/v1/orders/#{o["id"]}/printed",
          json: %{revision: 1, quoteId: Ids.uuid()},
          headers: [{"if-match", ~s("#{o["id"]}:2")}, {"idempotency-key", Ids.uuid()}]
        )

      assert {early.status, code(early)} == {409, "INVALID_STATE"}

      {p, q} =
        Portal.command(p, :post, "/api/print/v1/orders/#{o["id"]}/quotes",
          multipart:
            {[{"amountCents", "45900"}, {"orderRevision", "1"}],
             {"orçamento.pdf", "application/pdf", Portal.pdf("q")}},
          headers: [{"if-match", ~s("#{o["id"]}:2")}, {"idempotency-key", Ids.uuid()}]
        )

      assert q.status == 201
      quote = q.body["order"]["currentQuote"]
      assert {quote["amountCents"], quote["decision"]} == {45_900, "pending"}

      {p, doc} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}/quotes/#{quote["id"]}/file")
      assert doc.raw == Portal.pdf("q")

      :ok = Memory.decide_quote(p.memory, o["id"], :approved)
      {p, current} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}")
      [etag] = Portal.header(current, "etag")

      {p, printed} =
        Portal.command(p, :post, "/api/print/v1/orders/#{o["id"]}/printed",
          json: %{revision: 1, quoteId: quote["id"]},
          headers: [{"if-match", etag}, {"idempotency-key", Ids.uuid()}]
        )

      assert printed.status == 200
      assert printed.body["order"]["status"] == "printed"

      competence =
        Competence.containing(DateTime.utc_now())
        |> Competence.to_string()

      {p, close} = Portal.get(p, "/api/print/v1/monthly-closes/#{competence}")
      assert close.status == 200
      assert close.body["close"]["expectedTotalCents"] == 45_900
      assert close.body["close"]["periodClosed"] == false
      [close_etag] = Portal.header(close, "etag")

      {_p, open} =
        Portal.command(p, :post, "/api/print/v1/monthly-closes/#{competence}/invoice",
          multipart:
            {[{"declaredTotalCents", "45900"}], {"nf.pdf", "application/pdf", Portal.pdf("nf")}},
          headers: [{"if-match", close_etag}, {"idempotency-key", Ids.uuid()}]
        )

      assert {open.status, code(open)} == {409, "PERIOD_OPEN"}
    end

    test "commands need Origin + CSRF; body checked before preconditions", %{portal: p, order: o} do
      path = "/api/print/v1/orders/#{o["id"]}/collected"
      pre = [{"if-match", ~s("#{o["id"]}:1")}, {"idempotency-key", Ids.uuid()}]

      {_p, r} =
        Portal.request(p, :post, path,
          json: %{revision: 1},
          headers: [{"x-csrf-token", p.csrf} | pre]
        )

      assert {r.status, code(r)} == {403, "CSRF_FAILED"}

      {_p, r} =
        Portal.request(p, :post, path, json: %{revision: 1}, headers: [{"origin", p.origin} | pre])

      assert {r.status, code(r)} == {403, "CSRF_FAILED"}
      {_p, r} = Portal.command(p, :post, path, json: %{revision: "1"}, headers: pre)
      assert {r.status, code(r)} == {400, "INVALID_REQUEST"}
      {_p, r} = Portal.command(p, :post, path, raw: {"application/json", "1"}, headers: pre)
      assert {r.status, code(r)} == {400, "INVALID_REQUEST"}
      {_p, r} = Portal.command(p, :post, path, json: %{revision: 1})
      assert {r.status, code(r)} == {428, "PRECONDITION_REQUIRED"}
      # A browser never sends credentials in Authorization: refused, not relayed.
      count = FakeHono.request_count(p.hono)

      {_p, r} =
        Portal.command(p, :post, path,
          json: %{revision: 1},
          headers: [{"authorization", "Bearer " <> p.hono.token} | pre]
        )

      assert {r.status, code(r)} == {400, "INVALID_REQUEST"}

      for path <- ["/api/print/v1/orders", "/api/session"] do
        {_p, r} = Portal.get(p, path, headers: [{"authorization", "Bearer x"}])
        assert {r.status, code(r)} == {400, "INVALID_REQUEST"}, path
      end

      assert FakeHono.request_count(p.hono) == count
      {_p, ok} = Portal.command(p, :post, path, json: %{revision: 1}, headers: pre)
      assert ok.status == 200
      refute Enum.any?(FakeHono.last_headers(p.hono), fn {k, _} -> k == "cookie" end)
    end

    test "uploads: duplicate fields, missing file and oversize are refused", %{portal: p, order: o} do
      path = "/api/print/v1/orders/#{o["id"]}/quotes"
      pre = [{"if-match", ~s("#{o["id"]}:1")}, {"idempotency-key", Ids.uuid()}]
      file = {"q.pdf", "application/pdf", Portal.pdf()}

      {_p, r} =
        Portal.command(p, :post, path,
          multipart: {[{"amountCents", "1"}, {"amountCents", "2"}, {"orderRevision", "1"}], file},
          headers: pre
        )

      assert {r.status, code(r)} == {400, "INVALID_REQUEST"}

      {_p, r} =
        Portal.command(p, :post, path,
          multipart: {[{"amountCents", "1"}, {"orderRevision", "1"}], nil},
          headers: pre
        )

      assert {r.status, code(r)} == {400, "INVALID_REQUEST"}

      {_p, r} =
        Portal.command(p, :post, path,
          multipart: {[{"amountCents", "1"}, {"orderRevision", "1"}, {"extra", "x"}], file},
          headers: pre
        )

      assert {r.status, code(r)} == {400, "INVALID_REQUEST"}

      {_p, r} =
        Portal.command(p, :post, path,
          multipart: {[{"amountCents", "1,5"}, {"orderRevision", "1"}], file},
          headers: pre
        )

      assert {r.status, code(r)} == {400, "INVALID_REQUEST"}

      big = {"big.pdf", "application/pdf", Portal.pdf(:binary.copy("a", 5 * 1024 * 1024 + 1))}

      {_p, r} =
        Portal.command(p, :post, path,
          multipart: {[{"amountCents", "1"}, {"orderRevision", "1"}], big},
          headers: pre
        )

      assert {r.status, code(r)} == {413, "FILE_TOO_LARGE"}

      huge = {"huge.pdf", "application/pdf", :binary.copy("a", 6 * 1024 * 1024)}

      {_p, r} =
        Portal.command(p, :post, path,
          multipart: {[{"amountCents", "1"}, {"orderRevision", "1"}], huge},
          headers: pre
        )

      assert {r.status, code(r)} == {413, "FILE_TOO_LARGE"}

      {_p, r} = Portal.command(p, :post, path, raw: {"multipart/form-data", "x"}, headers: pre)
      assert {r.status, code(r)} == {400, "INVALID_REQUEST"}
    end

    test "monthly closes: invalid competence 400, PR C missing upstream relays 404", %{portal: p} do
      {_p, r} = Portal.get(p, "/api/print/v1/monthly-closes/2026-13")
      assert {r.status, code(r)} == {400, "INVALID_COMPETENCE"}
      {_p, r} = Portal.get(p, "/api/print/v1/monthly-closes/2026-09/invoice")
      assert {r.status, code(r)} == {404, "NOT_FOUND"}
      {_p, r} = Portal.get(p, "/api/print/v1/monthly-closes/2026-09")
      assert r.status == 200
      assert Portal.header(r, "etag") == [~s("month:2026-09:0")]
    end

    test "upstream down, token refused or misconfigured → 503 UPSTREAM_UNAVAILABLE", %{
      portal: p,
      order: o
    } do
      for failure <- [:unavailable, :unauthorized, :not_configured] do
        Memory.fail_with(p.memory, failure)
        {_p, r} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}")
        assert {r.status, code(r)} == {503, "UPSTREAM_UNAVAILABLE"}, inspect(failure)

        {_p, r} =
          Portal.get(p, "/api/print/v1/orders/#{o["id"]}/files/#{hd(o["jobs"])["file"]["id"]}")

        assert {r.status, code(r)} == {503, "UPSTREAM_UNAVAILABLE"}, inspect(failure)
      end

      Memory.fail_with(p.memory, nil)
      # The session survived: no re-login demanded.
      {_p, r} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}")
      assert r.status == 200
    end

    test "a wrong service token never asks the supplier to log in again" do
      p = Portal.start(token: String.duplicate("z", 48))
      {p, _} = Portal.login(p)
      {_p, r} = Portal.get(p, "/api/print/v1/orders")
      assert {r.status, code(r)} == {503, "UPSTREAM_UNAVAILABLE"}
      {_p, r} = Portal.get(p, "/readyz")
      assert r.status == 503
    end

    test "after an upstream timeout: 503, then the same key replays the persisted result" do
      p = Portal.start(timeout_ms: 1_000)
      {p, _} = Portal.login(p)
      o = Portal.seed(p)
      key = Ids.uuid()
      pre = [{"if-match", ~s("#{o["id"]}:1")}, {"idempotency-key", key}]
      path = "/api/print/v1/orders/#{o["id"]}/collected"

      FakeHono.misbehave(p.hono, :slow)
      {_p, r} = Portal.command(p, :post, path, json: %{revision: 1}, headers: pre)
      # No false success: the portal could not confirm.
      assert {r.status, code(r)} == {503, "UPSTREAM_UNAVAILABLE"}
      # ...but the upstream did apply it (it answers after 1.5 s).
      Process.sleep(700)
      FakeHono.misbehave(p.hono, nil)

      {_p, now} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}")
      assert now.body["order"]["status"] == "files_collected"
      {_p, again} = Portal.command(p, :post, path, json: %{revision: 1}, headers: pre)
      assert again.status == 200
      assert Portal.header(again, "idempotency-replayed") == ["true"]
    end
  end

  test "health and readiness", %{portal: p} do
    {_p, r} = Portal.get(p, "/healthz")
    assert {r.status, r.raw} == {200, "ok"}
    {_p, r} = Portal.get(p, "/readyz")
    assert {r.status, r.body} == {200, %{"ready" => true}}
    Memory.fail_with(p.memory, :unavailable)
    {_p, r} = Portal.get(p, "/readyz")
    assert {r.status, r.body} == {503, %{"ready" => false}}
  end

  test "hardening headers on every response; request id; no CORS", %{portal: p} do
    {_p, r} = Portal.get(p, "/api/session", headers: [{"origin", "http://evil.example"}])
    assert [_] = Portal.header(r, "x-request-id")
    assert Portal.header(r, "x-frame-options") == ["DENY"]
    # Regression: with `no-referrer`, Chromium sends `Origin: null` on
    # same-origin form posts and every HTML form was refused (403).
    # `same-origin` keeps the real Origin and leaks nothing cross-site.
    assert Portal.header(r, "referrer-policy") == ["same-origin"]
    assert [csp] = Portal.header(r, "content-security-policy")
    assert csp =~ "frame-ancestors 'none'"
    assert Portal.header(r, "access-control-allow-origin") == []
  end
end

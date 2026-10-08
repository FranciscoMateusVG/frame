defmodule Frame.Integration.ConfidentialityTest do
  @moduledoc """
  Spec §8 case 13: with a real span exporter and the production logger
  captured, markers of the password, service token, CSRF tokens, session
  ids, print instructions, file names and document bytes never appear in
  spans, logs or error responses — for valid, malformed, scalar and failing
  requests (400/401/403/404/413/429/500/503).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Frame.Adapters.PrintApi.Memory
  alias Frame.Observability.Observability
  alias Frame.Observability.OtelLogger
  alias Frame.Test.Ids
  alias Frame.Test.Portal

  defmodule RaisingApi do
    @moduledoc false
    # A PrintApi whose every call crashes (forces the portal's 500 path).
    defstruct []
    def list_orders(_api, _q), do: raise("MARKER-crash-detail")
    def get_order(_api, _id), do: raise("MARKER-crash-detail")
  end

  setup_all do
    obs = Frame.Test.Observability.create_test_observability()
    on_exit(fn -> Frame.Test.Observability.shutdown(obs) end)
    %{obs: obs}
  end

  setup %{obs: obs} do
    Frame.Test.Observability.reset(obs)

    observability = %Observability{
      logger: OtelLogger.new("print-portal"),
      tracer: obs.observability.tracer
    }

    %{portal: Portal.start(observability: observability)}
  end

  @instructions "MARKERINSTRUCAO frente e verso"
  @filename "MARKERARQUIVO.pdf"
  @doc_bytes "%PDF-1.4 MARKERCONTEUDO"

  test "no secret or content marker leaks into spans, logs or error bodies", %{portal: p, obs: obs} do
    log =
      capture_log([level: :debug], fn ->
        o =
          Memory.seed_order(p.memory, [
            %{
              title: "Trabalho",
              copies: 1,
              instructions: @instructions,
              file_name: @filename,
              bytes: @doc_bytes
            }
          ])

        # 401 wrong password, then 6 more for 429.
        {_p, r1} = Portal.login(Portal.fresh(p), "MARKERSENHAERRADA")
        # 400: scalar, truncated, unknown field — all carrying the password.
        {p0, %{body: %{"csrfToken" => pre_csrf}}} = Portal.get(Portal.fresh(p), "/api/session")
        h = [{"origin", p.origin}, {"x-csrf-token", pre_csrf}]

        {_p, r2} =
          Portal.request(p0, :post, "/api/session",
            headers: h,
            raw: {"application/json", ~s("#{Portal.password()}")}
          )

        {_p, r3} =
          Portal.request(p0, :post, "/api/session",
            headers: h,
            raw: {"application/json", ~s({"password":"#{Portal.password()})}
          )

        {_p, r4} =
          Portal.request(p0, :post, "/api/session",
            headers: h,
            json: %{password: Portal.password(), x: 1}
          )

        # 403: wrong CSRF with the password in the body.
        {_p, r5} =
          Portal.request(p0, :post, "/api/session",
            headers: [{"origin", p.origin}, {"x-csrf-token", "MARKERCSRF"}],
            json: %{password: Portal.password()}
          )

        {p, ok} = Portal.login(p)
        assert ok.status == 200
        {_p, r6} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}")

        {_p, r7} =
          Portal.get(p, "/api/print/v1/orders/#{o["id"]}/files/#{hd(o["jobs"])["file"]["id"]}")

        # 413 oversize upload, 404 unknown order.
        big = {@filename, "application/pdf", @doc_bytes <> :binary.copy("a", 6 * 1024 * 1024)}

        {_p, r8} =
          Portal.command(p, :post, "/api/print/v1/orders/#{o["id"]}/quotes",
            multipart: {[{"amountCents", "1"}, {"orderRevision", "1"}], big},
            headers: [{"if-match", "\"x:1\""}, {"idempotency-key", Ids.uuid()}]
          )

        {_p, r9} = Portal.get(p, "/api/print/v1/orders/#{Ids.uuid()}")
        # 503 upstream down.
        Memory.fail_with(p.memory, :unauthorized)
        {_p, r10} = Portal.get(p, "/api/print/v1/orders/#{o["id"]}")
        Memory.fail_with(p.memory, nil)
        # A real quote upload (success path) with marker file name and bytes.
        {_p, _} =
          Portal.command(p, :post, "/api/print/v1/orders/#{o["id"]}/collected",
            json: %{revision: 1},
            headers: [{"if-match", ~s("#{o["id"]}:1")}, {"idempotency-key", Ids.uuid()}]
          )

        {_p, r11} =
          Portal.command(p, :post, "/api/print/v1/orders/#{o["id"]}/quotes",
            multipart:
              {[{"amountCents", "45900"}, {"orderRevision", "1"}],
               {@filename, "application/pdf", @doc_bytes}},
            headers: [{"if-match", ~s("#{o["id"]}:2")}, {"idempotency-key", Ids.uuid()}]
          )

        assert r11.status == 201
        # 429.
        rs = for _ <- 1..6, do: Portal.login(Portal.fresh(p), "MARKERSENHAERRADA") |> elem(1)
        # HTML login failure.
        {pl, page} = Portal.get(Portal.fresh(p), "/login")
        [_, csrf] = Regex.run(~r/name="_csrf" value="([^"]+)"/, page.raw)

        {_p, r12} =
          Portal.request(pl, :post, "/login",
            form: %{"_csrf" => csrf, "password" => "MARKERSENHAERRADA"},
            headers: [{"origin", p.origin}]
          )

        send(self(), {:responses, [r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r12 | rs]})
        send(self(), {:session, p.jar["__Host-print_session"], p.csrf, pre_csrf})
      end)

    assert_received {:responses, responses}
    assert_received {:session, session_id, csrf, pre_csrf}

    statuses = responses |> Enum.map(& &1.status) |> MapSet.new()
    for s <- [400, 401, 403, 404, 413, 429, 503], do: assert(s in statuses, "missing #{s}")

    spans = Frame.Test.Observability.get_spans(obs)
    assert spans != []
    span_text = inspect(spans, limit: :infinity, printable_limit: :infinity)

    secrets = [
      Portal.password(),
      p.hono.token,
      "MARKERSENHAERRADA",
      "MARKERCSRF",
      session_id,
      csrf,
      pre_csrf,
      "MARKERINSTRUCAO",
      "MARKERARQUIVO",
      "MARKERCONTEUDO"
    ]

    for secret <- secrets do
      refute span_text =~ secret, "span leaks #{inspect(secret)}"
      refute log =~ secret, "log leaks #{inspect(secret)}"
    end

    # Error bodies never echo input.
    for r <- responses, r.status >= 400 do
      for secret <- secrets,
          do: refute(r.raw =~ secret, "#{r.status} body leaks #{inspect(secret)}")
    end

    # Spans exist for each layer: server, use case, adapter.
    names = Enum.map(spans, & &1.name)

    for name <- [
          "HTTP GET /api/print/v1/orders/:id",
          "getOrder",
          "http.print_api.getOrder",
          "logIn",
          "submitQuote"
        ],
        do: assert(name in names, name)

    assert log =~ "http.request"
    assert log =~ "order.quote_submitted"
  end

  test "an unexpected crash is a 500 INTERNAL without details", %{obs: obs} do
    p =
      Portal.start(
        observability: %Observability{logger: OtelLogger.new(), tracer: obs.observability.tracer}
      )

    {p, _} = Portal.login(p)
    deps = %{p.deps | print_api: %RaisingApi{}}
    p2 = restart_with(p, deps)

    log =
      capture_log(fn ->
        {_p, r} = Portal.get(p2, "/api/print/v1/orders")
        assert r.status == 500
        assert r.body["error"]["code"] == "INTERNAL"
        refute r.raw =~ "MARKER"
      end)

    refute log =~ "MARKER-crash-detail"
  end

  # Same session store (so the session cookie stays valid), new router deps.
  defp restart_with(p, deps) do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    {:ok, _} =
      Bandit.start_link(
        plug: {Frame.Http.Router, deps},
        port: port,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    %{p | port: port}
  end
end

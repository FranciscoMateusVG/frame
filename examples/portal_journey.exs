# The supplier journey through the use cases, against the in-memory fake of
# the Incluir API: log in, see the queue, collect files, quote, (Financeiro
# approves), print, and read the monthly close. No network, no database.
#
#   mix run --no-start examples/portal_journey.exs

alias Frame.Adapters.LoginLimiter
alias Frame.Adapters.PrintApi
alias Frame.Adapters.SessionStore
alias Frame.Observability.ConsoleLogger
alias Frame.Observability.Observability
alias Frame.UseCases

uuid = fn ->
  <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

  <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
    Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

  "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
end

api = PrintApi.Memory.new()

deps = %{
  print_api: api,
  session_store: SessionStore.Memory.new(),
  login_limiter: LoginLimiter.Memory.new(),
  password: "a-shared-password-of-the-print-shop",
  clock: &DateTime.utc_now/0,
  observability: %Observability{logger: ConsoleLogger.new(), tracer: Frame.noop_tracer()}
}

pdf = "%PDF-1.4\n%example\n"

order =
  PrintApi.Memory.seed_order(api, [
    %{
      title: "Apostila de Matemática",
      copies: 2,
      instructions: "Frente e verso, grampeado",
      file_name: "matematica.pdf",
      bytes: pdf <> "m"
    },
    %{
      title: "Lista de Física",
      copies: 7,
      instructions: "Só frente, colorido",
      file_name: "fisica.pdf",
      bytes: pdf <> "f"
    }
  ])

{:error, %{code: "INVALID_CREDENTIALS"}} =
  UseCases.LogIn.log_in(deps, %{password: "wrong", client_ip: "203.0.113.1", revoke: []})

{:ok, session} =
  UseCases.LogIn.log_in(deps, %{password: deps.password, client_ip: "203.0.113.1", revoke: []})

true = session.authenticated

{:ok, %{status: 200, body: %{"items" => [summary]}}} = UseCases.ListOrders.list_orders(deps, %{})
IO.puts("Queue: #{summary["reference"]} #{summary["title"]} (#{summary["status"]})")

pre = fn etag -> %{if_match: etag, idempotency_key: uuid.()} end
id = order["id"]

{:ok, %{status: 200, etag: etag}} =
  UseCases.CollectFiles.collect_files(deps, id, %{revision: 1}, pre.(~s("#{id}:1")))

{:ok, %{status: 201, body: %{"order" => %{"currentQuote" => quote}}}} =
  UseCases.SubmitQuote.submit_quote(
    deps,
    id,
    %{amount_cents: 45_900, order_revision: 1, file: %{name: "orcamento.pdf", bytes: pdf <> "q"}},
    pre.(etag)
  )

:ok = PrintApi.Memory.decide_quote(api, id, :approved)
{:ok, %{etag: etag}} = UseCases.GetOrder.get_order(deps, id)

{:ok, %{status: 200, body: %{"order" => printed}}} =
  UseCases.MarkPrinted.mark_printed(deps, id, %{revision: 1, quote_id: quote["id"]}, pre.(etag))

IO.puts(
  "#{printed["reference"]} is #{printed["status"]}: #{Frame.Domain.Money.format_brl(printed["approvedAmountCents"])}"
)

competence =
  DateTime.utc_now() |> Frame.Domain.Competence.containing() |> Frame.Domain.Competence.to_string()

{:ok, %{body: %{"close" => close}}} = UseCases.GetMonthlyClose.get_monthly_close(deps, competence)

IO.puts(
  "Close #{competence}: #{length(close["items"])} item(s), total #{Frame.Domain.Money.format_brl(close["expectedTotalCents"])}"
)

:ok = UseCases.LogOut.log_out(deps, session.id)
:error = SessionStore.fetch(deps.session_store, session.id, :authenticated)
IO.puts("Logged out.")

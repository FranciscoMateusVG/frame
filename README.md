# Portal da gráfica (Elixir)

The print shop's portal for Programa Incluir: a BFF plus LiveView pages.
The supplier signs in with the shared password, sees approved print orders,
downloads the files with their instructions, confirms collection, sends a
quote, prints once Financeiro approves it, and sends the monthly NF.

It is the Elixir implementation of spec `print-portal.md` (aperture-zi0fy)
§4.5/§5/§7/§10, built on the `frame-elixir` skeleton. This is the
implementation that runs in production.

- **Upstream:** only the Incluir Hono service API `/api/print-portal/v1`,
  with a server-only bearer token. Frozen contract:
  `test/fixtures/print-portal-v1.schema.json`, plus fixtures copied from
  monorepo-incluir PR B (orders) and PR C (monthly closes).
- **No database, no object storage.** Sessions and login limits are
  in-memory, single replica (§5). A restart signs everyone out by design.
- **Stack:** Phoenix + LiveView on Bandit, Finch (HTTP client, never
  follows redirects), Elixir's built-in `JSON`, and the OpenTelemetry API.
  No asset build: Phoenix/LiveView JS come from their packages, plus
  `priv/static/app.{css,js}`.

## Run it

```bash
mix setup                      # deps + git hooks
mix check                      # the gate (see below)

# local, against the in-memory fake (see examples/)
MIX_ENV=test mix run --no-start examples/portal_journey.exs

# production release / container
MIX_ENV=prod mix release print_portal
docker build -t print-portal-elixir .
```

Runtime configuration comes only from the environment, read once at boot.
The release refuses to start if any value is missing or invalid; see
`lib/frame/config.ex` and `.env.example`:

| Variable | |
|---|---|
| `PRINT_PORTAL_PASSWORD` | shared supplier password, ≥ 16 chars |
| `INCLUIR_PRINT_SERVICE_TOKEN` | bearer token for `/api/print-portal/v1` (Incluir keeps only its SHA-256) |
| `INCLUIR_PRINT_API_ORIGIN` | Hono origin of this environment (`http(s)://host[:port]`) |
| `PRINT_PORTAL_ORIGIN` | exact public origin, e.g. `https://grafica.programaincluir.org` |
| `PORT` | default 4000 |
| `PRINT_PORTAL_TRUSTED_PROXIES` | CIDRs whose `X-Forwarded-For` is honoured (Traefik) |
| `PRINT_PORTAL_SESSION_IDLE_SECONDS` / `…_ABSOLUTE_SECONDS` | can only shorten 30 min / 8 h (isolated tests) |
| `PRINT_PORTAL_UPSTREAM_TIMEOUT_MS` | 1000–60000, default 15000 |

## Routes

HTML: `/login` and `/logout` (controllers: they set and drop the cookies),
and the LiveViews `/orders`, `/orders/:id`, `/invoices`. Their commands
(collect, quote, print, NF) run over the LiveView socket through the same
use cases as the JSON API, with a server-side Idempotency-Key per intent and
the If-Match of the order on screen; quote/NF files are LiveView uploads
(5 MB cap). The socket accepts only the exact `PRINT_PORTAL_ORIGIN`, needs
the page's masked CSRF token and re-checks the server session on every
event. `/healthz` is liveness and `/readyz` checks that the upstream accepts
the token.

JSON (identical across the three portals):

- `GET|POST|DELETE /api/session`
- `/api/print/v1/…`: the ten §4.3 routes, authenticated by the session
  cookie. Commands need the exact `Origin`, `X-CSRF-Token`, `If-Match` and
  `Idempotency-Key`.

## Architecture

```
lib/frame/
├── application.ex   composition root: the only module naming concrete adapters
├── config.ex        env → Config (fail closed)
├── domain/          pure: Order, Close, Contract (frozen DTO validator), Competence,
│                    Money, Document, Requests (boundary parsers), Session, LoginThrottle
├── use_cases/       one per operation, each in one span: LogIn, LogOut, EstablishSession,
│                    ListOrders, GetOrder, CollectFiles, SubmitQuote, MarkPrinted,
│                    DownloadDocument, GetMonthlyClose, SubmitInvoice (+ UpstreamCall)
├── adapters/        ports + implementations
│   ├── print_api.ex          → print_api/http.ex (Finch), print_api/memory.ex (fake Hono)
│   ├── session_store.ex      → session_store/memory.ex (ETS, bounded)
│   └── login_limiter.ex      → login_limiter/memory.ex
├── web.ex           `use Frame.Web, :controller | :live_view | :html`
├── web/             the Phoenix edge: Endpoint (+ OriginGuard), Edge (span, access
│                    log, headers, assets, rescue), Router, controllers/ (Session,
│                    Print, Login, Health, Fallback), live/ (Orders, Order,
│                    Invoices), LiveAuth, SessionCookieStore, BrowserSession,
│                    Security, Multipart (strict), Reply, Intent, Components,
│                    Layouts, LiveTelemetry
├── errors/          PortalError
└── observability/   Logger port + Console/Noop/Otel loggers, Tracer, CrashReports
                     (crash reports reduced to the exception type)
```

`mix frame.depcruise` enforces these rules:
- `domain/` depends on nothing else.
- Use cases and the web edge never depend on concrete adapters.
- Nothing below the edge depends on `web/`, Phoenix or LiveView.
- Production code uses only the OTel API, never the SDK.
- No cycles.

## Tests

All tests go through real boundaries:

- `test/unit/print_api.memory_test.exs` and
  `test/integration/print_api.http_test.exs` run the **same conformance
  suite** (`test/helpers/print_api.conformance.ex`) against the in-memory
  fake and against the real Finch adapter talking over real sockets to
  `FakeHono` (a Bandit server backed by the fake). The HTTP-only cases cover
  redirects, timeouts, oversized and off-contract bodies, and truncated
  downloads.
- The portal tests are the Phoenix way — `Phoenix.ConnTest` and
  `Phoenix.LiveViewTest`, `async: true` — on **one shared setup**
  (`test_helper.exs`: one FakeHono listener, Finch, PubSub, the endpoint).
  Each test gets its own world (`Frame.Test.Portal.start/1`: a FakeHono
  tenant with its own token and in-memory upstream, its own session store
  and limiter), passed to the endpoint per conn, so nothing is shared
  between tests while the portal still talks to the upstream through the
  real HTTP adapter over a real socket.
  - `portal_api_test.exs`: the JSON API (sessions, cookie flags,
    CSRF/Origin, rate limit, trusted XFF, TTLs, the full journey,
    idempotent replay, 412/409, upload limits, 503 mapping).
  - `portal_live_test.exs`: every page flow (filters, pagination, the
    confirmations, uploads via `file_input`/`render_upload`, stale pages,
    silence + Repetir with the same key, session revoked or expired in the
    middle of a live page).
  - `portal_edges_test.exs`: login/logout controllers, 404/405, assets,
    multipart and XFF edge cases.
  - `application_test.exs`: the production children on a real port,
    including the websocket Origin gate (none/foreign → 403, exact → 101).
- `confidentiality_test.exs` (§8 case 13) uses the real SDK exporter and the
  production logger. It checks that passwords, tokens, CSRF tokens,
  instructions, file names and document bytes never reach spans, logs or
  error bodies — through the JSON API and through the LiveView pages, and
  for a LiveView that crashes mid-event.
- `contract_test.exs` validates every frozen fixture body and checks the
  validator against the schema's property and required sets.

The cross-language black-box suite lives in monorepo-incluir (the tester's
PR) and runs against `PORTAL_BASE_URL` + `HONO_BASE_URL`.

## The gate

`mix check`, run by the pre-push hook. Never bypass it.

```
mix lint                         format --check-formatted + credo --strict
mix frame.lint_structure         folder/file layout
mix typecheck                    compile --force --warnings-as-errors
mix frame.depcruise              architecture rules
mix test.coverage                all tests + per-module coverage thresholds
mix run examples/*.exs           examples run cleanly
mix frame.verify_hooks           git hooks installed
```

Deploy and rollback: see [`DEPLOY.md`](DEPLOY.md). Benchmark commands: see
[`BENCHMARK.md`](BENCHMARK.md).

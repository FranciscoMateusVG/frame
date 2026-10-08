# Print-shop portal — benchmark notes (TypeScript)

What to measure for the TS / Rust / Elixir comparison is **the portal only**.
This repository also contains the frame's Cat example (Postgres, Kysely,
Testcontainers); it is not part of the portal and is excluded by every
command below.

## The portal, file by file

| Group | Pattern |
|---|---|
| domain | `src/domain/{money,monthly-close,portal-session,print-order}.ts` |
| adapters | `src/adapters/{print-api,session-store,login-throttle}*.ts` |
| errors | `src/errors/{csrf-failed,invalid-credentials,invalid-request,login-rate-limited,unauthenticated,upstream-*}.error.ts` |
| use cases | `src/use-cases/*.ts` except `create-cat.ts` |
| http + entrypoint | `src/http/*.ts` (`server.ts` is the production entrypoint) |
| tests | `tests/{unit,integration}/{portal,print}*.test.ts`, `tests/helpers/{fake-print-upstream,print-*,portal-harness}.ts` |
| other | `examples/print-portal.hono.ts`, `scripts/{smoke-portal-bundle,portal-loc}.js`, `tsup.portal.config.ts` |

Lines of code: `pnpm loc:portal` (non-blank lines per group). At the commit
that introduced this file it reported: src 45 files / 4128 non-blank, tests
14 files / 2468, other 4 files / 270.

## Portal-only commands

| Step | Command | Notes |
|---|---|---|
| install | `pnpm install --frozen-lockfile` | one lockfile for the whole repo |
| typecheck | `pnpm typecheck` | `tsc --noEmit` over `src/` (the Cat files are ~200 lines of it) |
| lint | `pnpm lint && pnpm lint:structure && pnpm depcruise` | whole repo; the portal adds no exceptions |
| tests | `pnpm test:portal` | unit + integration of the portal; real HTTP boundaries (fake upstream server on a port, the real entrypoint as a child process); **no Docker** |
| build | `pnpm build:portal` | → `dist-portal/server.mjs` |
| artifact smoke | `node scripts/smoke-portal-bundle.js` | copies the bundle alone into an empty dir (no `node_modules`), checks startup refusal, `/healthz`, `/login` |
| example | `pnpm tsx examples/print-portal.hono.ts` | whole journey in one process |
| full gate | `pnpm check` | everything above **plus** the Cat example (needs Docker for Testcontainers) |

Reference timings on the author's machine (Apple Silicon, Node 24.15, warm
cache): `build:portal` 0.5 s, `test:portal` 1.9 s (111 tests), bundle smoke
0.3 s.

## Production artifact

- **One file:** `dist-portal/server.mjs` (~0.74 MB, ~131 KB gzipped) plus an
  optional source map. All dependencies (hono, @hono/node-server, zod,
  @opentelemetry/api) are inlined by tsup (`noExternal`).
- **Runtime needs:** Node.js ≥ 20 and nothing else — **no `node_modules`**.
- **Run:** `node dist-portal/server.mjs` with
  `PRINT_PORTAL_PASSWORD` (≥ 16 chars), `INCLUIR_PRINT_SERVICE_TOKEN`,
  `INCLUIR_PRINT_API_ORIGIN`, `PRINT_PORTAL_ORIGIN`; optional `PORT`
  (default 3000), `HOST`, `PRINT_PORTAL_TRUSTED_PROXIES`,
  `PRINT_PORTAL_SESSION_IDLE_SECONDS`, `PRINT_PORTAL_SESSION_ABSOLUTE_SECONDS`.
- Probes: `GET /healthz`, `GET /readyz`.
- State: sessions and the login limiter live in process memory (one replica).

## Running against a real Incluir Hono

The portal only needs `INCLUIR_PRINT_API_ORIGIN` and a supplier service
token for that Hono. It was verified end to end against monorepo-incluir
`12178459` (PR B + PR C contract) running locally with Postgres, Redis and
MinIO. The orders journey (login → list → download with matching sha256 →
collected → quote → staff approval through the real human route → printed),
the HTML-form journey, CSRF/Origin, 404 across suppliers, relayed 412/428/409
and logout all passed. At that commit the monthly-close routes are not
mounted upstream, so `/invoices` shows "Notas fiscais ainda indisponíveis".

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
  `PRINT_PORTAL_PASSWORD` (≥ 12 chars), `INCLUIR_PRINT_SERVICE_TOKEN`,
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

## Production container (2026-10-08)

The multi-stage Dockerfile builds only the portal bundle with frozen pnpm
10.33.0 dependencies. The runtime uses the official **node:24-bookworm-slim**
image (Node 24 satisfies package.json's >=20 engines constraint), a root-owned
bundle, and UID 10001. No application node_modules, source maps, TypeScript,
compiler or build dependencies are copied into the runtime. The base image's
normal Node/npm installation is retained, not hand-stripped.

This matches Phoenix's Debian/glibc slim posture: non-root, exec-form entrypoint,
HTTP /healthz HEALTHCHECK at 30s/5s timeout/20s grace/3 retries, and no Alpine,
scratch, UPX, special minification or OS-library stripping. Build-only native
tooling supports the existing dev dependencies and does not affect final size.
The runtime layout follows the [official Node image](https://hub.docker.com/_/node)
and [Docker multi-stage builds](https://docs.docker.com/build/building/multi-stage/).

```bash
docker build --platform linux/arm64 -t print-portal-ts .
docker image inspect print-portal-ts --format '{{.Size}}'
# Supply the four required variables through your protected environment first.
docker run --rm -p 127.0.0.1:4000:4000 \
  -e PRINT_PORTAL_PASSWORD -e INCLUIR_PRINT_SERVICE_TOKEN \
  -e INCLUIR_PRINT_API_ORIGIN -e PRINT_PORTAL_ORIGIN print-portal-ts
curl --fail http://127.0.0.1:4000/healthz
```

The image defaults to HOST=0.0.0.0 and PORT=4000 (the non-container entrypoint
otherwise defaults to 3000). A PORT override also updates the health probe;
update the published port accordingly. Secrets are runtime-only, never ARG/COPY.
.dockerignore excludes .env files, dependencies and generated outputs.

Measured locally with Docker 29.4.0 on **linux/arm64**: **249,405,608 bytes
(237.85 MiB)** from docker image inspect .Size. This is the uncompressed logical
image size, not compressed registry transfer, unique disk usage or runtime RAM.
Resolved Node: v24.21.0; base manifest
sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20.
Node 24 is a moving security-patch tag: record the resolved digest when rerunning.
Image ID: sha256:9ea296e0cb929fe2f4b5a4c13403b6f99f7c546f57ec99984641066a6bb30a4a.

Real-container checks: /healthz and /login 200; Docker healthy; default and
custom port 4010; UID 10001; no compiler or application node_modules; read-only
root filesystem with all capabilities dropped; missing env exits 1. Synthetic
runtime secrets were not present in logs. Health is liveness, not proof of an
upstream Incluir connection. No production service or credentials were used.

## Build revision

`GET /version` is public and returns only `{"revision":"<sha>"}` with
`Content-Type: application/json` and `Cache-Control: no-store`. It is compiled
into the artifact: setting `BUILD_SHA` on the running container cannot change it.

CI builds with `docker build --build-arg BUILD_SHA="$GITHUB_SHA" ...`. For Dokploy
public clones without that argument, the build reads only `.git/HEAD`,
`.git/refs/**`, and `.git/packed-refs` from a read-only, filtered build context.
Git config, objects, logs, and credentials are excluded; Git metadata never enters
the runtime image. A worktree `.git` pointer is not followed (pass the argument).
An explicit argument conflicting with valid checkout metadata fails the build.
Missing metadata/argument yields `unknown` for local development; malformed Git
metadata fails closed. Staging smoke must require an exact full 40-hex SHA match
and reject `unknown`. This proves the source revision, not the runtime image ID.

# Deploy, rollout and rollback — print portal (Elixir)

Spec §10. **Nothing here has been deployed.** Each production step needs the
operator's approval, with Peppy running the infra side.

## Artifact

- Image: `docker build -t print-portal-elixir .` A multi-stage build: OTP
  release `print_portal` on `debian:bookworm-slim`, running as uid 10001,
  with no Erlang distribution (`RELEASE_DISTRIBUTION=none`).
- Listens on `PORT` (4000) over plain HTTP. TLS terminates at Traefik.
  Never publish the port on the host.
- `HEALTHCHECK` hits `GET /healthz` (liveness, no dependencies). Use
  `GET /readyz` as the readiness probe: it returns 200 only when the
  upstream accepts the service token, with no content in the response.
- One replica only. Sessions and login limits are in memory (§5), so
  running more replicas would need a shared store, which is a separate decision.

## Dokploy service (proposal to ratify, §10)

| | |
|---|---|
| Service | `print-portal-elixir` on the Incluir Dokploy (Xerox) |
| Hostname | `grafica.programaincluir.org` (Traefik HTTPS) |
| Internal port | 4000 |
| Replicas | 1 |
| Memory | 256 MB is plenty (the BEAM idles at ~60 MB; uploads ≤ 5.5 MB are held in memory) |
| Env (secrets) | `PRINT_PORTAL_PASSWORD`, `INCLUIR_PRINT_SERVICE_TOKEN` |
| Env (plain) | `INCLUIR_PRINT_API_ORIGIN` (Hono of the same environment, internal network), `PRINT_PORTAL_ORIGIN=https://grafica.programaincluir.org`, `PRINT_PORTAL_TRUSTED_PROXIES=<Traefik network CIDR>` |

On the Incluir side, Hono needs `PRINT_SUPPLIERS` (the print shop row) and
`PRINT_SERVICE_CREDENTIALS` holding the **SHA-256** of the portal's token
(never the token itself), plus `REDIS_URL`.

Generate the token (256 bits) and its digest without writing either to disk:

```bash
token=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')
printf %s "$token" | sha256sum   # → PRINT_SERVICE_CREDENTIALS[].sha256 on Hono
# put $token in the portal's INCLUIR_PRINT_SERVICE_TOKEN secret, then: unset token
```

## Rollout

1. Hono with PR A–C migrations and configuration in place, backups verified (Peppy).
2. Staging: same image with staging Hono, then the full §8 black-box suite
   (`PORTAL_BASE_URL`, `HONO_BASE_URL`) and the visual gate (desktop + mobile).
3. Production: create the service, set the secrets, deploy, and check `/readyz`
   is 200. Run a controlled smoke with an authorized fixture order (no real
   expense, no load test).
4. The operator hands the URL and password to the print shop over the
   protected channel.

## Rotation

- **Password:** `PRINT_PORTAL_PASSWORD` requires at least 12 characters. Change it
  and restart. Every session ends with the restart.
- **Token:** add the new digest on Hono as current and the old one as
  previous with `expiresAt` ≤ 24 h. Then switch the portal's
  `INCLUIR_PRINT_SERVICE_TOKEN` and restart. Remove the old digest after the
  switch.

## Rollback

- Stop or scale the portal service to 0, or redeploy the previous image tag.
  The portal holds no data. Rolling back deletes nothing upstream: orders,
  quotes, audit rows, proposals and dispatches stay in Incluir.
- To cut supplier access entirely, remove the token digest from
  `PRINT_SERVICE_CREDENTIALS` on Hono. The portal then answers 503 and
  `/readyz` goes red.
- Sessions are lost on any restart. That is expected; the supplier just
  signs in again.

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

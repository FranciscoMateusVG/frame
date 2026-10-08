# TTP staging infrastructure

This is a **staging** delivery experiment, never a production promotion workflow.
The same workflow and Python orchestration are copied verbatim across the three
portal branches. Changes to common files must be mirrored and reviewed together.

## Contract

Dedicated `frame-ttp-mini` runner, labels `self-hosted, macOS, ARM64, frame-ttp`.
Only same-repository PRs by the repository owner and branch pushes are admitted.
No `pull_request_target`, fork checkout, general Dokploy token, or production secret.
Repository policy requires approval for **all external contributors**; the YAML
condition is only defence in depth, not the fork security boundary. The checks job
has contents:read only, no Environment, no OIDC and no GH_TOKEN environment. The
push-only deploy job needs checks and has the staging Environment/OIDC; GH_TOKEN
is scoped to webhook polling/report steps. Approved dependencies/code still run on
a persistent host under the same OS user: a compromised dependency could leave a
process to inspect later deploy environment. Job separation is not a sandbox.
Separate OS users/ephemeral runners are out of scope, a documented residual risk.

Workflow concurrency is separated by event + branch: a pending PR cannot cancel
a pending merged deploy. There is no shared job concurrency group (GitHub keeps
only one pending entry and would cancel older deploys). Global serialization comes
from the single dedicated runner plus the protocol one-trial-at-a-time rule. Within
a same-event/branch group GitHub can replace older pending runs; preserve cancelled
metadata, never silently substitute a trial. Each stage waits for the two existing Incluir
workers to be idle. Contention during a stage invalidates comparison, not evidence:
the original timings/failures remain in the artifact. This does not preempt Incluir.

| Event | Stages |
| --- | --- |
| PR | install, lint-format, typecheck-compile, tests |
| Branch push | those four, image-build, staging-deploy, staging-smoke |

Commands are explicit in `infra/ttp/pipeline.py`. Dependencies are locked; caches
are keyed by platform, variant, actual toolchain versions, and lockfile hash.
PR/push cache keys and native pnpm/Cargo/Hex/Rebar cache directories are separate;
deploy checks out clean source and does not restore native caches. Image cleanup
runs always, removes only the current run tag, and records its result (no prune).
Infrastructure self-tests run separately, outside the timed portal tests stage.
Rust uses `~/.cargo/bin` explicitly. `/opt/homebrew/bin` is prepended only inside
this workflow; login shell configuration is untouched. Tool versions and cache
hit/miss are recorded. The seven stage IDs are stable, not identical commands or
identical test counts. PRs do not deploy or fetch staging secrets.

## Auth and deployment

`ttp-staging` GitHub Environment allows exactly portal-ts/rust/phoenix. Nonsecret
configuration comes from repository variables (no tailnet IPs/project IDs in code):
`INFISICAL_URL`, `INFISICAL_IDENTITY_ID`, `INFISICAL_PROJECT_ID`,
`INFISICAL_ENVIRONMENT`, `INFISICAL_DENIED_PROJECT_ID` (nonexistent-key negative
probe only), `DOKPLOY_WEBHOOK_ORIGIN`, and `TTP_FAKE_SHA` (full frozen fake source SHA).
GitHub OIDC subject is bound to that Environment, repository, push event and portal
ref; Infisical access TTL is 600 seconds. Identity `frame-ttp-ci` can read only
root secrets in the dedicated `frame-ttp-staging` project's staging environment.
No bootstrap credential or production project membership. A nonexistent probe key
must return authorization denied both in the same project's prod environment and
the separate General prod project. No real production secret is requested.

Staging secret **names**:
- `PRINT_PORTAL_PASSWORD_TS`, `PRINT_PORTAL_PASSWORD_RUST`, `PRINT_PORTAL_PASSWORD_PHOENIX`
- `INCLUIR_PRINT_SERVICE_TOKEN` (shared synthetic fake only)
- `DOKPLOY_WEBHOOK_TS`, `DOKPLOY_WEBHOOK_RUST`, `DOKPLOY_WEBHOOK_PHOENIX`

Native Python reads credentials directly into memory; no env files, argv values,
credential response bodies or URLs are logged. The runner reaches Infisical and
Dokploy through existing Tailscale. HTTP is acceptable only within that encrypted
tailnet transport; never route these endpoints over public plaintext networks. Rotation: replace staging passwords/token in
Infisical + the matching Dokploy env, redeploy the affected staging services;
rotate scoped webhook in Dokploy then replace its Infisical key. Never production.

Each portal uses public Git source (not GitHub App), `autoDeploy=true` solely to
accept its scoped webhook, and `docker-compose.staging.yml`. The global GitHub
App hook does not select these custom Git composes. CI invokes the scoped hook
only after tests and local image build. Dokploy clones branch HEAD, **not** the
payload SHA. CI checks HEAD before invocation and during readiness and rejects
races. `GET /version` must equal the run SHA; health alone is insufficient.
BUILD_SHA is passed in the CI image build; Dokploy derives it from the tightly
filtered real `.git` metadata. A valid explicit/metadata mismatch fails the build.
Final images must not contain `.git`; CI probes `/app` with a real container.

## Isolation, resources, and frozen fake

Portal URLs: `https://staging-grafica-{ts,rust,phoenix}.programaincluir.org`.
Each portal: 512 MiB, 0.5 CPU, one replica, no host port, service `portal:4000`.
Dokploy **isolatedDeployment=true** gives each an isolated ingress network
attached to Traefik, not production's shared dokploy-network. Trusted proxy
addresses are taken from the actual ingress network, never guessed globally.
All three also join the external **internal bridge** `frame-ttp-private`.
Only the synthetic fake joins that network as `ttp-fake:4001`; no public domain,
no production Hono, database, token or data. Fake: 256 MiB, 0.5 CPU, one replica.
Inspect live network membership and DNS resolution before acceptance.

The TS branch carries `docker-compose.ttp-fake.yml` and `Dockerfile.fake`. The
shared fake runs a frozen approved infra SHA on its own staging ref with
`autoDeploy=false`. Do not advance that ref during trials. Record that full SHA
and the fixture hash in every manifest; administrative readback verifies the
configured fake against the live container at acceptance and before each trial
block: internally GET `/healthz` and assert both `X-TTP-Fixture-SHA256` and the
JSON fixtureHash. The BFF contract does not forward that header; CI does not fake
that proof or expose the private upstream (GLaDOS approval #1292).

The fake reuses `tests/helpers/fake-print-upstream.ts` and the frozen contract
fixture, one order/two jobs, zero artificial latency. Its public-on-private-network
health reports the fixture SHA256. It never retains authorization headers, allows
only reads (writes return 405), and has no production upstream route. This proves
authenticated read smoke, **not** a complete stateful printing journey. Fixture
hash: `9d1ab88ca294c4a446cce579e21a538e6a78f430b45770a71022c0a344093f6d`.
Local fake verification (TS only, separate from comparable portal test stage):

```sh
pnpm exec tsup --config infra/ttp/tsup.fake.config.ts
python3 infra/ttp/test_fake.py
docker build --platform linux/arm64 -f infra/ttp/Dockerfile.fake -t frame-ttp-fake:check .
```

## Evidence and honest limits

`$TTP_STATE_DIR/ttp-timings.json` (per-run runner temporary directory, outside
the source checkout so generated data cannot pollute lint) is always uploaded if the runner remains alive. It includes
stage timestamps/durations/statuses, admission waits, contention, actual source
SHA/toolchains, local image ID, fake SHA/hash, webhook acceptance, first observed
healthy revision, and authenticated smoke completion. GitHub run/job metadata
adds setup/cache/queue times. Final workflow completion and artifact upload occur
after the report; retain GitHub's final metadata separately. Missing artifacts or
an offline runner are **not success**.

CI image build is not Dokploy's remote rebuild; publishing is `not_performed`.
Webhook deployment ID, remote image ID and internal deployment finish time are
null / `not_exposed`, not fabricated. accepted_at → healthy_at includes opaque
remote rebuild time. `/version` proves revision, not image identity. Correlate
administrative Dokploy read-only evidence separately at acceptance.

Common smoke: TLS, exact `/version`, `/healthz`, `/login`, real CSRF login,
orders HTML + JSON containing exactly the frozen order, logout. Phoenix LiveView
WebSocket exact-Origin and browser visual acceptance are additional checks,
not falsely marked proven by this HTTP smoke.

## Operations and rollback

Runner native commands on the Mini: `cd ~/actions-runner-frame && ./svc.sh status`;
stop/start require operator approval. Do not stop the two Incluir runners.
To pause staging, stop new trials and disable the staging workflow or scoped
webhook through an approved change. Preserve failed artifacts and previous image
IDs; no automated pruning/resetting. A source rollback is reviewed, not a force push.
Never delete Dokploy projects/services/databases.

KR Digital production tracks `release/portal-phoenix`, isolated at d3660de5.
These workflows and composes neither reference nor modify production. Promoting
production remains a separate operator-approved operation.

# TTP v2 staging fake (aperture-qscen)

Review/deployment gate: **not yet deployed**. This isolated infra branch starts at
`2b317be330432b40b48fec3a4bb0d108dc299da4`. No portal arm, prod branch, CI workflow,
production data or credential changes. After independent review, pin the approved
commit on `staging/ttp-fake-v2` and keep Dokploy `autoDeploy=false`. The old
`staging/ttp-fake` at `2b317be` remains the rollback point. Do not advance the
staging compose until GLaDOS approves the reviewed SHA.

## Provenance and boundaries

- Upstream freeze: `FranciscoMateusVG/monorepo-incluir`
  `270224676d61431c2d26a8e20ec911c328a1f5f3` (#1053).
- `contracts/` preserves all 13 source files byte-for-byte: normative Markdown,
  schema, both fixtures, asset index, `.gitattributes`, seven real synthetic PDFs.
  `contracts/manifest.json` records every original path, length and SHA256.
- Bundle digest = SHA256 of the **raw manifest bytes**, which bind all source file
  hashes and the approved deviation. Startup verifies each file, every referenced
  File's bytes/hash/MIME, structural schema and item/file uniqueness. Corruption
  stops startup, not an invented fallback document.
- The eight batch snapshots are **alternate states of one batch**, not eight live
  batches. The fake doesn't reimplement Hono or infer unsafe legacy associations:
  the source's mixed projection is served unchanged. Extra `pairing-<case-name>`
  seeds replay all seven legacy examples using their explicit `expectedPairs`/
  residual lists; raw unpaired blocks are preserved as residual text. This is
  fixture replay, not an independent fuzzy rematching algorithm.
- V1 remains frozen/read-only, with its original `X-TTP-Fixture-SHA256`:
  `9d1ab88ca294c4a446cce579e21a538e6a78f430b45770a71022c0a344093f6d`.
  V2 uses its bundle digest in that header. `X-TTP-V2-Fixture-SHA256` is present
  on both, plus `X-TTP-Boot-ID` and `X-TTP-Generation`. Never label v2 as the v1
  fixture. The current arm CI smoke remains v1; updating that shared smoke before
  task1/T0 is **separate work**, not a change hidden in this fake.

## Service and state

Port4001 is private Docker-network-only, with no public domain/host port; same
256MiB/0.5CPU/one-replica envelope. Authentication precedes replay and ownership
checks precede downloads. Service tokens cannot access Financeiro/admin actions.
Complete service HTTP surface is documented by the unmodified upstream contract.

One current batch; collect freezes the viewed membership and moves every member
pending→in_progress atomically. New publications queue privately until receipt;
receipt moves all members to approved and exposes the next open batch atomically.
Cancellation preserves history and puts every member back into the new open batch,
including the backend `previouslyCancelledIn` flag; no price/quote is transferred.
GET/download never collect or create a batch. A separate checkpoint changes an
open member revision to demonstrate stale ETag412 and required reconfirmation.

Commands use UUID idempotency + original If-Match + semantic fields/stored upload
hash (not multipart boundary). Successful replay returns the original response
and ETag, even after later state changes. A committed-quote503 fault is one-shot:
retry **the same key and intention**, never a fresh key. JS synchronous transactions
serialize mutations; async body buffering is inside the active trial command
lease, so reset/finish/checkpoints cannot race an upload. At most two command
bodies are in flight; the third concurrent command gets503 with Retry-After, not
an unbounded queue. This is a documented fake capacity limit, not a Hono claim.

Limits: read120/min, command30/min, upload10/hour, Retry-After on429. Upload file
5MiB, body5MiB+512KiB capped while reading, exact multipart fields, MIME/magic checks,
no-store/nosniff/attachment downloads. Per-trial bounded uploads32MiB/64files,
idempotency1024entries/checkpoints64. A reset clears **all** those stores/counters.

**Approved deviation: fake does not transcode images** (GLaDOS1390). It accepts
PDF/JPEG/PNG/WebP signatures with matching declared MIME and stores bytes as-is.
Returned length/hash/MIME describe stored bytes; it is not a deep image decoder.
TTP acceptance quotes are PDFs only. Real Hono transcode is tested in Hono suites.
The task1 draft's “non-PDF” rejection wording must be read consistently with this
contract: unsupported MIME fails; allowed images aren't arbitrarily rejected.

The synthetic event timestamp is the fixture's `2026-09-10T12:00:00.000Z`; the
accounting clock is fixed in October2026 so September is closed on all arms.
Monthly totals combine one batch charge (printed/received counted once) with the
source legacy charge1000. Receipt doesn't charge again. Empty competence returns
its virtual close and cannot submit an invoice. Invoices stay in memory only.

## Private admin protocol

Listener **127.0.0.1:4002 inside the container**. Never bind0.0.0.0, publish a port
or add a Traefik route. Use the existing `docker exec` with Node HTTP. Exact
loopback Host required; any Origin or Fetch-Metadata header rejected.4KiB JSON
body cap,5s header/request timeouts,8connections. Errors/logs never echo payloads,
auth tokens, uploads, config values or stack traces.

- GET `/status`: boot_id, generation, phase, trial_id, scenario, seed_sha256,
  configured, in_flight. No data or credentials.
- GET `/manifest`: source manifest + bundle/v1 hashes, current lifecycle metadata
  and ordered checkpoint names. Archive this with the trial evidence and the
  separately verified fake git SHA/image ID/deployment metadata.
- POST `/reset`: `{boot_id,generation,trial_id,scenario}`. Only idle/finished/aborted;
  prepared/active/in-flight reset is denied. Unknown scenarios rejected. New state
  is fully constructed before replacing the old generation.
- POST `/start`, `/finish`, `/abort`: `{boot_id,generation,trial_id}`.
  Finish requires active/no command in flight. Abort also allows prepared.
- POST `/checkpoint`: same stamp + `event`. Active/no command in flight only;
  fixed synthetic events, no arbitrary DTOs, IDs, SQL, code, paths or URLs.

Owner archives prior evidence, resets, verifies manifest/hash/fence, then starts
one trial. A restart changes boot_id and loses state: **invalidate the trial**,
never silently resume it. Wrong generation/trial/boot is409. No automatic reset,
lease takeover or timeout recovery. End the trial before resetting the next arm.
The admin is not an exposed Financeiro API and is not part of portal TTP work.

Example inside the already-identified fake container (no secrets needed):

```sh
docker exec "$FAKE_CONTAINER" node -e 'fetch("http://127.0.0.1:4002/status").then(r=>r.json()).then(x=>console.log(JSON.stringify(x)))'
```

Use the returned stamp literally for POST JSON; do not infer generation from a
previous run. Token-bearing service probes use the established native secret
mechanism in memory, never a pasted token in a shell command or report.

## Three reproducible acceptance scenarios

Use identical scenario/checkpoint order for all arms, recorded in each manifest.
Seed digest includes bundle digest + scenario + fixed clock + generation + policy `ttp-v2-2`.
Quote, document and invoice IDs derive from SHA256(scenario, generation,
successful per-trial sequence). Same scenario+generation+successful command order
reproduces IDs; failures/replays do not consume sequence numbers. Different
generations intentionally have different IDs; record the generation when comparing.
Frozen initial DTOs and all file bytes remain identical.

1. `flow`: open LOT-0001, one member with two jobs plus residual instructions/file.
   Read/download → admin `revise-open` → old collect412 → refresh/reconfirm collect
   → `publish-queued` (IMP-0002 remains hidden) → `quote-commit-503` → PDF quote503
   after commit → same-key retry201/replayed → `reject-quote` → resubmit PDF →
   `approve-quote` → portal prints → admin `receive` → next LOT-0002 appears.
   Inspect September total = batch quote +1000, submit matching monthly PDF NF.
   Alternative stale-membership demonstration: `publish-queued` before collection;
   record that variation, do not mix it into the standard flow silently.
2. `cancel`: initial approved LOT-0001 with IMP-0002 already queued. Admin `cancel`
   → immutable cancelled history + next open LOT-0003 with both pending members;
   IMP-0001 visibly carries `previouslyCancelledIn=LOT-0001`. The next projection must exactly match the real rebatched fixture; incompatible
   ad-hoc state rolls back with INVALID_SEED instead of rewriting fixture items. No old quote/price;
   collection, upload and approval are required again.
3. `empty-history`: received LOT-0001 history, no current/open batch. Empty current
   screen; history's source files remain downloadable. September mixed total46900,
   empty August virtual close, monthly PDF NF submit/download. No hidden second
   batch created by reads.

Other checkpoint calls fail by state; repeated publication cannot duplicate a
member. Checkpoints do not mutate the raw freeze. Full Hono/PG/MinIO failure
semantics and the pairing algorithm itself remain covered by backend tests,
not misrepresented as integration with real services here. The optional
`pairing-reordered-mixed`, `pairing-duplicate-block`, `pairing-duplicate-file-prefix`,
`pairing-almost-title`, `pairing-invalid-suffix`, `pairing-invalid-copies`,
`pairing-unicode-nfd` seeds exercise the seven normative examples independently;
register any such extra trial block identically across all arms.

## Verification / review / rollout

Existing lockfile only; no new dependency, toolchain, sharp or production access.

```sh
pnpm exec tsx --test infra/ttp/test-{control,batch-state,batch-runtime,batch-http,contract-freeze}.ts
pnpm exec tsup --config infra/ttp/tsup.fake.config.ts
python3 infra/ttp/test_fake.py
docker build -f infra/ttp/Dockerfile.fake -t ttp-fake:qscen-local .
python3 infra/ttp/test_fake_container.py
```

The bundle test was red against the scaffold (configured=false), then green with
real seed/wiring/source-byte downloads. HTTP tests cross native HTTP sockets:
auth before replay, stale/race, actual multipart/limits, quote503 replay and
reject/resubmit/print/receipt/monthly NF. Container test exercises the built
non-root/read-only image, all three admin reset scenarios, raw downloads, v1 hash,
no host ports/.git, no token in logs, and a separate namespace proving service4001
reachable but admin4002 refused. It removes only its owned temporary containers.

Remaining deployment gate: GLaDOS review → approve exact SHA → immutable new ref,
compose branch switch/deploy with autoDeploy=false → real private-network
manifest/SHA/hash/admin binding/read-flow checks. Record container running,
endpoint healthy, outcomes and `visually verified:no` (headless upstream). Do not
claim portal UI acceptance before task1 is implemented. Re-check existing staging
v1 smoke and protected KR Digital revision; no arm or prod redeploy is authorized.

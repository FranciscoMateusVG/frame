# Print portal v2 — frozen batch contract (aperture-ltza7)

Approved decisions: GLaDOS #1355, #1368, #1375 and #1378, 2026-10-09. This contract is language-neutral.
The existing `/api/print-portal/v1` JSON contract is unchanged. Backend deployment
keeps supplier mode `individual`; no production activation is part of the PR.

## Types and fixtures

Normative JSON Schema: `print-portal-v2.schema.json` (`$defs` names below).
Generated from `src/use-cases/print-batches/contract.ts`; drift test is mandatory.
`print-portal-v2.fixture.json` contains successive snapshots of ONE synthetic
batch, not eight live batches, plus a mixed historic/current monthly close.
`print-portal-v2.legacy-pairing.fixture.json` defines safe matching examples.
`print-portal-v2.assets/index.json` maps EVERY File.id in both fixtures to a real,
valid one-page synthetic PDF. Read its bytes verbatim; file length/SHA-256/MIME
are verified by the asset drift test. `queuedItem`, `nextBatch`, `rebatchedBatch`
provide complete DTOs for every timeline reference, not placeholder IDs. The
visibility/receipt and cancellation timelines are alternate journeys, not one
combined sequential database history.

- BatchSummary: id, `LOT-0001` reference, status, version, itemCount, createdAt,
  collectedAt, printedAt, receivedAt, approvedAmountCents. UTC RFC3339, nullable
  timestamps/value before the corresponding event. UUID IDs. Integer BRL cents.
- Batch: summary + items, currentQuote, cancellationReason. itemCount equals items
  length; unique orderId. An empty open batch is not collectable.
- Item: orderId, `IMP-0001` reference, title, revision, jobs, optional
  generalInstructions, optional previouslyCancelledIn (`LOT-0007`). **Mixed jobs + residual generalInstructions is valid v2**.
  Each file ID appears exactly once within the item; at least one file. Semantic
  uniqueness/count invariants are additional to structural JSON Schema.
- Job/File match v1 field shapes. Quote has no orderRevision: the sealed batch is
  immutable, and commands use its ETag. A quote contains id, revision, amountCents,
  currency BRL, document, decision, rejectionReason, submittedAt, decidedAt.
- CloseResponse retains v1 fields; items are discriminated `kind: batch` + batchId
  or `kind: legacy_order` + orderId; both have reference/quoteId/amountCents/printedAt.
  No invented per-request share of a batch price. Received never charges again.
- Unknown keys are rejected. Supplier DTOs never include identity/PIX, storage
  keys/URLs, requester profiles, accounting semester or email destinations.

## Service HTTP

Prefix **`/api/print-portal/v2`**. Authorization Bearer maps to one supplier on
Hono, never browser-supplied supplierId. Missing/bad token 401, foreign ID 404.
Credentials remain server-side in portals. Responses no-store. Reuse existing
read/command/upload rate limits (120/min, 30/min, 10/hour); 429 + Retry-After.
Every non-GET command requires `If-Match` + UUID `Idempotency-Key` (missing 428).
ETag is `"<batch-id>:<version>"`; never compose it from quote revision.

| Method/path | Input | Response |
|---|---|---|
| GET /batches | status optional; limit 1–100/default20; opaque cursor | 200 BatchListResponse `{items,nextCursor}`; createdAt ASC,id ASC, all history by default |
| GET /batches/open | — | 200 OpenBatchResponse `{batch:null\|Batch}`; no write; null while an active collected…printed batch exists; ETag only when nonnull |
| GET /batches/:id | — | 200 BatchResponse + ETag |
| GET /batches/:id/orders/:orderId/files/:fileId | — | 200 authorized member revision bytes; attachment Content-Disposition, detected Content-Type/Length, nosniff/no-store; no redirects |
| POST /batches/:id/collected | JSON `{}` | 200 BatchResponse + ETag |
| POST /batches/:id/quotes | multipart file + amountCents (positive decimal integer string) | 201 BatchResponse + ETag |
| GET /batches/:id/quotes/:quoteId/file | — | 200 current quote bytes, same download policy |
| POST /batches/:id/printed | JSON `{quoteId:uuid}` | 200 BatchResponse + ETag |
| GET /monthly-closes/:competence | YYYY-MM | 200 BatchCloseResponse + close ETag |
| POST /monthly-closes/:competence/invoice | multipart file + declaredTotalCents | 201 BatchCloseResponse + close ETag |
| GET /monthly-closes/:competence/invoice | — | 200 current invoice bytes |

Uploads use v1 limits: one PDF/JPEG/PNG/WebP, 5 MiB file, 5 MiB + 512 KiB body;
stream cap before buffering, MIME sniffing/transcoding, hashes of STORED bytes.
Missing/extra/repeated fields, scalar/truncated JSON → 400. Never echo contents.
GET of an empty competence returns existing v1 virtual close: id=null, version=0,
state=open, items=[], total=0, ETag `"month:YYYY-MM:0"`; not submit-able.

Error envelope: `{error:{code,message,requestId}}` (`BatchError` schema).
400 INVALID_REQUEST/INVALID_CURSOR/INVALID_COMPETENCE; 404 NOT_FOUND;
405 METHOD_NOT_ALLOWED; 409 INVALID_STATE/BATCH_NOT_ACTIVE/BATCH_WORKFLOW_REQUIRED/
EMPTY_BATCH/IDEMPOTENCY_CONFLICT/OPERATION_IN_PROGRESS/PERIOD_OPEN/EMPTY_CLOSE/
TOTAL_MISMATCH; 412 VERSION_MISMATCH; 413 FILE_TOO_LARGE;
415 UNSUPPORTED_MEDIA_TYPE; 428 PRECONDITION_REQUIRED; 429 RATE_LIMITED;
500 INTERNAL; 503 NOT_CONFIGURED/UPSTREAM_UNAVAILABLE.
Replay identical intention returns original status/body/ETag with
`Idempotency-Replayed: true`, even if version advanced; authorize first. Intent
includes route, original precondition, fields and SHA of upload, not multipart
boundary. In-progress response has Retry-After. No automatic blind retry with a
fresh key. A stale collection must refresh and require confirmation again.

## State machine and human boundary

At most ONE CURRENT batch (open through printed) exists per supplier. Completed
received/cancelled batches remain in history. Open contains every published pending
request not yet collected, only when no collected…printed batch is active.
Entry/removal/revision increments batch version. Collect freezes EXACT seen
membership/projection AND atomically moves every member solicitation from pending
to in_progress (Em análise). The batch stays visible regardless of parent status.
New requests remain pending in Incluir but are NOT exposed to the supplier or
materialized as a next open batch while the current batch is active. Receipt moves
ALL members to approved and only then forms/exposes the next batch in the same
transaction. GET/download never collect/create a batch. Supplier lock + CAS
serializes publication/collection/receipt and ensures no invisible collection.

`open → files_collected → quote_pending → quote_approved → printed → received`.
Quote rejection is `quote_pending → quote_rejected → quote_pending` (new quote).
History remains visible, including received/cancelled. No quote replaces an
approved/pending quote. No partial edits/removal/cancel/receipt after collection:
409 BATCH_WORKFLOW_REQUIRED. Whole-batch cancellation only before printed, confirmed by #1375: atomically
return EVERY member solicitation to pending (in_progress → pending, audited),
release its current-batch membership and form the next open batch together with
queued pending requests. The cancelled batch keeps immutable history and files.
The next batch must be collected/quoted/approved again; no quote is transferred.
Each re-batched member has `previouslyCancelledIn: "LOT-0007"`, the latest cancelled
batch reference, persisted/frozen with the new member. Its file cards visibly say
**Este item já esteve no lote LOT-0007, cancelado**. Never infer this flag in the UI
from client state; the backend supplies it, including after restart.
For cancelling an open batch, members already pending remain pending. Confirmation
must explicitly warn that the files may already be downloaded and the requests
will return to the next batch. No cancellation after printed/received.

Human API **`/api/print-batches`**, BetterAuth Financeiro/admin, not service token:
GET list/detail/files/quotes; POST `/:id/quotes/:quoteId/decision`
`{decision:"approved"|"rejected",reason?}`, `/:id/received` `{}`,
`/:id/cancel` `{reason}`. Require If-Match/idempotency, preserve audit. Decisions
return `{batch}` + ETag; reason required for rejection/cancel (1–500 trimmed chars).
Receipt changes all members' solicitations to approved and orders to received in
ONE transaction, then exposes the queued next batch; no per-member generic approval bypass. Semester filter includes
any matching member but detail/confirmation show the WHOLE batch.

## Safe legacy pairing and UI acceptance

Only structured metadata.printJobs (`fileTitle`, `copies`, `printInstructions`)
is parsed, object or JSON string. NFC + external trim, **no casefold, accent
stripping, fuzzy, startsWith, ordering or positional matching**. File prefix:
remove only terminal `-<alphanumeric>-<13 decimal digits>.<extension>` from the
stored public filename. Require nonempty prefix; unknown suffix stays residual.
A key must have exactly ONE block and ONE file, and valid v1 job values, to pair.
Duplicate keys on either side remain entirely unpaired. Copies may be an integer
or decimal string 1–500. Job title 2–160; instructions 5–4000 chars.

Pairs become ordinary jobs with stable IDs. Unpaired blocks retain full title,
copies and instructions in generalInstructions.text. Unpaired files appear in
its files array. Preserve additional request-wide text. No duplication or lost
blocks; malformed metadata is preserved as residual text, never guessed. The
optional residual may be text-only or files-only; omit when both empty. Explicit
v2 file links take precedence, with no legacy rematching. Freeze this projection
and policy version on collection; do not reinterpret closed batches later.

Each FILE is ONE card: title, copies, instructions, **Baixar arquivo**. Unpaired
file cards say **Não identificadas** / **Sem vínculo seguro — consulte instruções
gerais** and retain download; show residual instructions separately, not as a
false per-file association. No new manual publication gate.

Portal UI: single current-batch screen (open OR active), request/file cards, **Retirei os arquivos**
with confirmation showing count, **Enviar orçamento** (document + total), pending
approval/rejection reason, **Marcar como impresso** with confirmation, **Histórico
de lotes** with full detail, and monthly NF. No finance approval/receipt buttons in
supplier UI. Disable actions by state; preserve session on upstream failures;
show stale feedback + **Atualizar**, do not silently confirm a changed batch.
Financeiro approves/rejects quote once and confirms whole receipt once. It shows
member requests as Em análise after collection and shows queued Pendentes as
awaiting the next batch; those queued items are never exposed in supplier DTOs.

Monthly NF: only ended São Paulo competence; sum approved batch quotes ONCE plus
individual historical charges ONCE. Existing single close/NF/explicit accounting
semester/total equality/Vidal workflow persists; no discounts/freight or new email
sender. Source revision/ETag/hash includes the composition, including batch items.

## Rollout and frozen acceptance

Default supplier mode remains individual. New v2 gives BATCH_NOT_ACTIVE until
explicit authorized activation AFTER new Phoenix ships. Migrate all current
ready/pending/uncollected into open batch under lock. Gate: drain individual
files_collected/quote_pending/quote_rejected/quote_approved first, never convert
quotes. Old printed/received/NFs remain history. V1 remains operational before
cutover; afterward it cannot mutate batch-owned items or expose a misleading
partial monthly total. No automatic flag activation on migration/boot/deploy.

Black-box v2 phases (separate from unchanged v1 suite): empty + mixed legacy
projection; isolation; open membership change + stale collection; replay/race;
one quote rejection/resubmission/approval; print guard; all-or-nothing receipt;
closed partial-edit guards; queued pending hidden until receipt; collect→in_progress visibility and generic-transition 409; mixed monthly NF/once-only accounting; real PG/MinIO/
Redis failures, composition-root mounts, telemetry confidentiality. Pairing
fixture includes reversed files, duplicate blocks/prefixes, missing counterparts,
near-match, malformed suffix/copies, NFC/NFD. TTP arms share this same fixture and
acceptance rubric. Backend/Financeiro implementation is NOT TTP-measured.

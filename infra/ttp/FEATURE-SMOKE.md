# Optional task-1 v2 smoke (OFF by default)

The shared helper uses Python's standard library, real JSON session authentication
(Origin, CSRF rotation, cookie jar, logout) and real HTTP downloads. No browser,
new dependency, app route, reset endpoint, or deployment credential is added.
`visually_verified` remains **false**: this checks rendered HTML, not CSS visibility,
JS interaction, responsive layout or the LiveView websocket. Those remain separate
acceptance checks. It sends no collect/quote/printed command.

## Selection and provenance

Absent/empty `TTP_SMOKE_CONFIG`, or `{"mode":"v1"}`, preserves the existing
health/login/version + `/orders`/v1 API smoke. `task1-v2` replaces only that last
v1 feature section with `/` and file download assertions. It does **not** require
the retired `/orders` screen after task 1.

The trial owner sets **one repository variable**, JSON with these exact fields:

```json
{
  "mode": "task1-v2",
  "trial_id": "REPLACE-WITH-TRIAL-ID",
  "scenario": "flow",
  "checkpoint": "open",
  "fake_sha": "74e677c764a0dc11d3ec6ce61e62f10df417a2c2",
  "freeze_sha": "270224676d61431c2d26a8e20ec911c328a1f5f3",
  "bundle_sha256": "550698df3fa1e2e42a710ec6ca5d995ed1c5fe9d3a32c520c1f0c11c6430c85e",
  "boot_id": "REPLACE-FROM-ADMIN-MANIFEST",
  "generation": 1,
  "seed_sha256": "REPLACE-FROM-ADMIN-MANIFEST",
  "admin_manifest_sha256": "REPLACE-WITH-SHA256-OF-ARCHIVED-MANIFEST-BYTES"
}
```

This template deliberately fails until the owner fills actual manifest fields.
`TTP_FAKE_SHA` must match `fake_sha` when v2 is enabled. Init validates and freezes
the selector plus its canonical JSON hash in the checks artifact. Deploy resumes
that snapshot, validates its hash, and never rereads the selector variable. A change
mid-run affects future runs only. No `workflow_dispatch` or OIDC permission change.
Unknown keys/modes/checkpoints, wrong pins, duplicate keys and oversized config fail.

Allowed checkpoints (expected HTML snapshot, **not** an admin reset command):

| Scenario | Checkpoints |
|---|---|
| flow | open, collected, quote-pending, quote-rejected, quote-approved, printed, next-batch |
| cancel | approved, rebatched |
| empty-history | empty |

The owner reaches the selected state using the existing trial protocol **before**
the read-only smoke, then keeps it stable. Flow states select the corresponding
frozen `batches` snapshot; next-batch/rebatched use their actual fixture envelopes.
These are smoke checkpoint names, not claims of verifying the full command journey.

The fake stays private. Only the trial owner reads `/manifest` and resets/starts
through the approved inside-container admin path. Archive the exact manifest bytes
and hash; compare boot ID, generation, seed, scenario, fake SHA and bundle **before
and after** each trial block. A reset, reboot or concurrent state change invalidates
the trial. CI cannot independently attest these fields through the portal: its
artifact explicitly says `administrative_correlation: required_before_and_after_trial`.
A green HTTP smoke alone does not waive that external acceptance gate.

`smoke-fixtures/` vendors byte-exact synthetic fixture/assets from the frozen
monorepo contract; `provenance.json` records their original paths/hashes. Nothing
comes from production. The helper checks file integrity before selecting an
expectation. It does not derive expected data from the portal response under test.

## Marker contract

Canonical handout: Aperture `data/specs/ttp-smoke-markers.md` (same for all arms).
For review portability its normative marker table is repeated below. `data-ttp`
markers belong on the actual rendered components, not hidden test-only copies.
HTML must be balanced; whitespace in text assertions is normalized.

| `data-ttp` | Shape / content |
|---|---|
| batch | Exactly one container, `data-batch-id` = UUID, `data-status` = contract status |
| batch-reference | Inside batch, exact reference text |
| item | Inside batch, `data-order-id`; fixture order; exactly one per item |
| item-reference | Inside item, exact reference text |
| general-instructions | Inside owning item, exact residual text when present; otherwise absent |
| previously-cancelled | Inside item when `previouslyCancelledIn` exists; text includes that reference |
| file | Inside owning item, `data-file-id`; jobs first, then residual files, each exactly once |
| file-name | Inside file, exact filename text |
| file-size | Inside file, nonempty human-readable size, `data-bytes` = exact decimal bytes |
| copies | Inside job file, decimal copies text; absent for residual files (do not invent copies) |
| instructions | Inside job file, exact instructions (empty marker if absent); absent for residual files |
| download | One `<a>` per file, text `Baixar arquivo`, real session-authenticated same-origin href |
| action | One button/form/input, `data-action` per state below, real visible action label |
| status-message | Waiting text in pending/printed states, no action marker |
| empty | When no current batch: `Nenhum pedido aguardando`; no batch/item/file/action markers |

Actions: open → `collect` / `Retirei os arquivos`; files_collected or quote_rejected
→ `upload-quote` / `Enviar orçamento`; quote_approved → `mark-printed` /
`Marcar como impresso`. quote_pending → `Aguardando aprovação do Financeiro`;
printed → `Aguardando recebimento`. Inapplicable actions must not be rendered.
A collect button may be disabled until confirmation; interaction is tested separately.
No selector dictates classes, framework, layout or BFF URL paths.

Hidden/aria-hidden/inline display:none or visibility:hidden/template/script/style
ancestors fail. External stylesheets and browser layout are not evaluated. Downloads
use the login cookie with no redirects/proxy, exact same origin (no userinfo or
fragment), expected MIME, a byte cap, exact length and SHA256. Neither cookies,
passwords, URLs with queries nor response bodies go into artifacts.

## Tests and acceptance

`python3 infra/ttp/test_feature_smoke.py` runs real loopback HTTP/session/download
regressions and frozen PDF positives. Workflow runs it in the **untimed infra
self-test**, not the language's timed `tests` stage. No mutable fake state needed.
`test_pipeline.py` proves a changed env variable cannot alter a resumed selector.

Before review: default mode passes all three actual staging portals; enabled mode
fails cleanly against the unimplemented baselines and still logs out. This is a
negative feature detector acceptance, **not** a live v2 UI acceptance. No live
variable is changed until GO, and no production service or release ref is touched.

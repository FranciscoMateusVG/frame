# Fake v2 — infrastructure scaffold (aperture-qscen)

**Not ready to deploy.** The replacement contract/asset freeze is pending. No
v2 batch fixture, transition, scenario or pairing rule is implemented here. The
approved server/reset scaffold is independent of the old d727281a semantics.
The service returns 503 NOT_CONFIGURED for v2; reset returns 503 until the new
freeze's seed factory is wired in the actual composition root. V1 is unchanged.

## Private control boundary

- Service: existing port 4001/private Docker network only. No admin routes there.
- Admin: **127.0.0.1:4002 inside the container**, never 0.0.0.0, no published port
  or Traefik route. Use the existing `docker exec` mechanism with Node HTTP.
- Exact loopback Host required; Origin/Fetch-Metadata requests rejected. No CORS.
- GET /status: boot_id, generation, phase, trial_id, scenario, seed_sha256,
  configured, in_flight. No data, passwords, tokens, uploads or request bodies.
- POST /reset: JSON {boot_id,generation,trial_id,scenario}; reset allowed only
  after idle/finished/aborted, never prepared/active/in-flight. The future seed
  factory creates a fresh state including uploads, idempotency, faults and rate
  counters before replacing the old generation. Unknown scenarios must reject.
- POST /start, /finish, /abort: JSON {boot_id,generation,trial_id}. Every command
  is fenced to the current boot/generation/trial. End refuses in-flight work;
  abort can also release a prepared trial. No implicit reset or timeout takeover.
- Admin body cap 4 KiB, 5-second header/request timeouts, 8 connections. Errors
  expose fixed codes only. Server shutdown closes both listeners.

Owner archives prior evidence, resets, reads back the seed and fence, then starts
one trial. Restart changes boot_id; the owner must invalidate an ongoing trial,
not treat a new boot as continuity. No state persistence is claimed. The future
v2 command handlers must call the lifecycle command boundary; this scaffold alone
does not prove batch CAS, idempotency or full seed cleanup.

## Local verification (existing lockfile/tooling, no new dependency)

1. `pnpm exec tsx --test infra/ttp/test-control.ts` — real loopback HTTP, neutral
   lifecycle seed only (not a batch fixture), reset fences, phase guards, in-flight
   refusal, generation reset, Origin rejection and bounded input.
2. `pnpm exec tsup --config infra/ttp/tsup.fake.config.ts`
3. `python3 infra/ttp/test_fake.py` — actual bundled composition root: v1 HTTP,
   localhost admin wired, v2/reset fail closed, no admin on service port, clean
   shutdown and generated synthetic token absent from process output.

The composition test was red on the old bundle (connection refused on4002), then
passed after wiring the control listener. Do not advance any portal branch,
change staging pins or deploy this incomplete scaffold. Full v2/container/asset
acceptance and review remain required after the NEW freeze arrives.

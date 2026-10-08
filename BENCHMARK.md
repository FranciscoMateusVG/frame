# Benchmark — portal only (Elixir)

GLaDOS's fairness rule: measure the **portal only**. Build, tests, gate,
release artifact and LOC cover the portal itself, not leftovers from the
frame skeleton (none remain: the Cat example, Postgres adapter and
migrations were removed).

All commands run from the repository root, on the same machine as the
other two portals.

## Build

```bash
mix deps.get
MIX_ENV=prod mix compile --force                 # cold compile time
MIX_ENV=prod mix release print_portal --overwrite
du -sh _build/prod/rel/print_portal              # release size
docker build -t print-portal-elixir .            # image
docker image inspect print-portal-elixir --format '{{.Size}}'
```

## Tests and gate

```bash
mix test                                          # unit + integration (fake Hono over HTTP)
mix check                                         # full gate
```

## Lines of code

Portal code (production) and tests, excluding deps/_build:

```bash
find lib -name '*.ex' | xargs wc -l | tail -1                            # production
find test -name '*.ex' -o -name '*.exs' | xargs wc -l | tail -1          # tests
find priv/static -type f | xargs wc -l | tail -1                         # CSS + JS
find scripts -name '*.ex' | xargs wc -l | tail -1                        # gate tasks (frame tooling)
```

## Runtime

The black-box suite and load runs use the release or the container with the
same Hono, fixture and environment as the other implementations (spec §8):

```bash
PORT=4100 PRINT_PORTAL_ORIGIN=http://localhost:4100 \
PRINT_PORTAL_PASSWORD=… INCLUIR_PRINT_SERVICE_TOKEN=… INCLUIR_PRINT_API_ORIGIN=http://127.0.0.1:43133 \
  _build/prod/rel/print_portal/bin/print_portal start
```

Memory: `ps -o rss= -p $(pgrep -f 'print_portal.*beam')` (resident set,
cold and after load).

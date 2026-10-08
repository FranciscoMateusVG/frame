# syntax=docker/dockerfile:1
# Print-shop portal (Elixir) — production image for Dokploy.
#
#   docker build -t print-portal-elixir .
#   docker run --rm -p 4000:4000 \
#     -e PRINT_PORTAL_PASSWORD -e INCLUIR_PRINT_SERVICE_TOKEN \
#     -e INCLUIR_PRINT_API_ORIGIN -e PRINT_PORTAL_ORIGIN print-portal-elixir
#
# Required runtime env (never baked into the image): see lib/frame/config.ex.
# The container refuses to start when any of them is missing or invalid.

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.1
ARG DEBIAN_VERSION=bookworm-20261005-slim

# ── build ────────────────────────────────────────────────────────────────
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

ENV MIX_ENV=prod
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY rel rel
# CI supplies BUILD_SHA. Dokploy's public checkout supplies only filtered Git metadata.
# The readonly context mount also supports worktrees/no .git: never follow a pointer.
ARG BUILD_SHA
RUN --mount=type=bind,target=/source,readonly <<'SH'
set -eu
derived=
if [ -d /source/.git ] && [ -f /source/.git/HEAD ]; then
  test ! -L /source/.git/HEAD
  head=$(cat /source/.git/HEAD)
  case "$head" in
    'ref: '*)
      ref=${head#ref: }
      printf '%s\n' "$ref" | grep -Eq '^refs/[A-Za-z0-9._/-]+$'
      case "$ref" in *..*|*//*) exit 1 ;; esac
      if [ -f "/source/.git/$ref" ]; then
        test ! -L "/source/.git/$ref"
        derived=$(cat "/source/.git/$ref")
      elif [ -f /source/.git/packed-refs ]; then
        test ! -L /source/.git/packed-refs
        derived=$(awk -v ref="$ref" '$2 == ref { print $1; exit }' /source/.git/packed-refs)
      fi
      ;;
    *) derived=$head ;;
  esac
  printf '%s\n' "$derived" | grep -Eq '^[0-9a-f]{40}$' || { echo 'Invalid build revision metadata' >&2; exit 1; }
fi
if [ -n "${BUILD_SHA:-}" ] && [ -n "$derived" ] && [ "$BUILD_SHA" != "$derived" ]; then
  echo 'BUILD_SHA disagrees with checkout metadata' >&2
  exit 1
fi
export BUILD_SHA="${BUILD_SHA:-${derived:-unknown}}"
mix compile --warnings-as-errors && mix release print_portal
chmod -R a+rX _build/prod/rel/print_portal
SH

# ── runtime ──────────────────────────────────────────────────────────────
FROM debian:${DEBIAN_VERSION} AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libsctp1 ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --no-create-home --home-dir /app portal

ENV LANG=C.UTF-8 \
    PORT=4000 \
    HOME=/app

WORKDIR /app
COPY --from=build --chown=root:root /app/_build/prod/rel/print_portal ./

RUN test -z "$(find /app -name .git -print -quit)"
USER portal
EXPOSE 4000

# Liveness without extra tools: a raw HTTP/1.0 request over bash's /dev/tcp.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT} && printf 'GET /healthz HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -q ' 200 '"]

CMD ["/app/bin/print_portal", "start"]

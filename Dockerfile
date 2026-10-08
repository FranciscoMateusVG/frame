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
RUN mix compile --warnings-as-errors && mix release print_portal

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

USER portal
EXPOSE 4000

# Liveness without extra tools: a raw HTTP/1.0 request over bash's /dev/tcp.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT} && printf 'GET /healthz HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -q ' 200 '"]

CMD ["/app/bin/print_portal", "start"]

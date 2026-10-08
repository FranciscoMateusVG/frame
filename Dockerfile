# syntax=docker/dockerfile:1
# Production portal only; required configuration is supplied at runtime.
ARG NODE_VERSION=24

FROM node:${NODE_VERSION}-bookworm-slim AS build
WORKDIR /app
# Build-time native dev dependencies never enter the runtime stage.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates python3 make g++ \
 && rm -rf /var/lib/apt/lists/* \
 && corepack enable
COPY package.json pnpm-lock.yaml ./
RUN HUSKY=0 pnpm install --frozen-lockfile
COPY tsconfig.json tsup.portal.config.ts ./
COPY src src
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
pnpm build:portal
SH

FROM node:${NODE_VERSION}-bookworm-slim AS runtime
RUN useradd --system --uid 10001 --no-create-home --home-dir /app portal
ENV NODE_ENV=production \
    LANG=C.UTF-8 \
    HOME=/app \
    HOST=0.0.0.0 \
    PORT=4000
WORKDIR /app
# tsup inlines all portal dependencies: no node_modules or source maps needed.
COPY --from=build --chown=root:root --chmod=0444 /app/dist-portal/server.mjs ./server.mjs
RUN test -z "$(find /app -name .git -print -quit)"
USER portal
EXPOSE 4000
# Same probe posture as Phoenix: bash + base-system utilities, no curl package.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT} && printf 'GET /healthz HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -q ' 200 '"]
CMD ["node", "/app/server.mjs"]

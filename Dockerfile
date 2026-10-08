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
RUN pnpm build:portal

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
USER portal
EXPOSE 4000
# Same probe posture as Phoenix: bash + base-system utilities, no curl package.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PORT} && printf 'GET /healthz HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -q ' 200 '"]
CMD ["node", "/app/server.mjs"]

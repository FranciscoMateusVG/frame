# syntax=docker/dockerfile:1
# Production portal only; keep glibc/Debian consistent with Phoenix.
ARG RUST_VERSION=1.94.1
ARG DEBIAN_VERSION=bookworm-20261005-slim

FROM rust:${RUST_VERSION}-slim-bookworm AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY .cargo .cargo
# Cargo resolves the workspace manifests; only the portal binary is built.
COPY crates crates
COPY examples examples
COPY tests tests
COPY xtask xtask
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
cargo build --release --locked -p frame-portal-web --bin print-portal
SH

FROM debian:${DEBIAN_VERSION} AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libgcc-s1 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --no-create-home --home-dir /app portal
ENV LANG=C.UTF-8 \
    HOME=/app \
    PRINT_PORTAL_BIND=0.0.0.0:4000
WORKDIR /app
COPY --from=build --chown=root:root --chmod=0555 /app/target/release/print-portal ./print-portal
RUN test -z "$(find /app -name .git -print -quit)"
USER portal
EXPOSE 4000
# Keep the probe aligned with PRINT_PORTAL_BIND; no extra curl/toolchain package.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PRINT_PORTAL_BIND##*:} && printf 'GET /healthz HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -q ' 200 '"]
CMD ["/app/print-portal"]

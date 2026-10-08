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
RUN cargo build --release --locked -p frame-portal-web --bin print-portal

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
USER portal
EXPOSE 4000
# Keep the probe aligned with PRINT_PORTAL_BIND; no extra curl/toolchain package.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/${PRINT_PORTAL_BIND##*:} && printf 'GET /healthz HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' >&3 && head -n1 <&3 | grep -q ' 200 '"]
CMD ["/app/print-portal"]

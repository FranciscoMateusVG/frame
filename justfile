check:
    cargo xtask check

build:
    cargo build -p frame -p frame-postgres -p frame-testing --locked

build-all:
    cargo build --workspace --all-targets --locked

test:
    cargo test --workspace --locked

fmt:
    cargo fmt --all

db-up:
    docker compose -f docker/docker-compose.yml up -d

db-down:
    docker compose -f docker/docker-compose.yml down

db-migrate:
    cargo xtask migrate

codegen:
    cargo xtask codegen

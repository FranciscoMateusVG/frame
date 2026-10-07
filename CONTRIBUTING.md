# Contributing

Use the [five-step, role-separated TDD workflow](.claude/workflow.md). Tests are
the behavioral contract. A human approves the red specs **before** implementation.

## Git hooks and the binary gate

Run `cargo xtask install-hooks` once in a fresh clone. `.husky/_` contains plain
shell wrappers, not a Husky/Node dependency. Existing Frame worktrees already
configured for this path need no shared Git config changes.

- Pre-commit: `cargo fmt --all -- --check` (entire workspace; never rewrites staged files).
- Pre-push: `cargo xtask check` (the complete gate, including real databases).
- `cargo xtask verify-hooks` fails on missing, unreadable, non-executable or
  incorrectly wired required hook files.

**Never bypass hooks**, use `--no-verify`, or weaken checks to push. Fix failures.
A successful check and its real output, not a claim of readiness, define done.

## Verification

Use `cargo xtask check` / `just check`. It stops on errors from formatting,
architecture/layout, Clippy, all-target compilation, schema drift, tests/coverage,
examples or hooks. Build is separately available as `cargo build --workspace
--all-targets --locked`. Coverage instruments full workspace tests and enforces
per-core-file line/function/**region** thresholds (not branch thresholds).

Tests live in `tests/unit`, `tests/integration`, `tests/helpers`. Properties stay
memory-only. Integration boundaries use real PostgreSQL 16 via testcontainers-rs,
real OTel SDK exporters, and real HTTP sockets. Never replace them with mocks.

After migration/query edits: `cargo xtask codegen`, review and commit `.sqlx/`.
Do not hand-edit generated metadata. A fresh temporary migrated database is
used in the drift gate; normal builds are SQLx-offline.

Architecture modifications require explicit edits to `xtask/src/architecture.rs`
and review. Negative tests should mutate a scratch copy, not the working branch.

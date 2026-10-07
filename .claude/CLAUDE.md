# Frame Rust — agent operating instructions

1. NEVER bypass Git hooks (`--no-verify`, environment bypasses, or disabled hooks).
2. `cargo xtask check` / `just check` is the canonical gate. All steps must pass.
3. Domain is pure data/validation. No other internal layer or I/O dependencies.
4. Use cases are plain async functions with explicit repository, clock and
   Observability deps. No DI container; never import concrete adapters.
5. Internal crates must not depend on the public `frame` facade. Concrete
   repositories remain separate crates, not facade re-exports.
6. Validate at external/use-case entry boundaries. Direct invalid calls must
   produce typed errors, including malformed IDs as InvalidCatNameError.
7. Production imports only OTel API. SDKs belong in `frame-testing`, tests,
   examples. Consumers own their providers/exporters; no production setup helper.
8. Exactly one span per use case and repository method; exception + ERROR on
   failure, OK on success. End spans and propagate errors. Attach async context
   per poll, never hold a context guard across an await.
9. Adapter spans: `db.cats.save/findById/findByName/deleteById`, `db.system`,
   `db.collection.name`, `db.operation.name`. Adapters NEVER log.
10. Business logs come from use cases (`cat.created`); attributes use shapes,
    not raw names. Pure domain parsing does not emit spans.
11. Run real PostgreSQL via testcontainers; real OTel exporters; real HTTP
    sockets for composition. Shared conformance tests run against both adapters.
12. Preserve proptest invariants. Never skip/ignore/filter tests or weaken
    lint, structure, architecture, drift, coverage or hook gates.
13. Commit regenerated `.sqlx/` with migrations/queries. Never hand-edit it.
14. Follow `.claude/workflow.md`. Spec agent writes tests only; implementation
    agent cannot modify approved tests. Human gates tests before implementation.
15. Coverage is ≥90% lines/≥90% functions/≥85% **regions**, independently for
    domain/cat.rs and use-cases/create_cat.rs. Region ≠ branch coverage; do not
    claim they are the same. No additional coverage exclusions.

Source layout and dependency allowlists are executable policy in
`xtask/src/architecture.rs`; Cargo also enforces crate boundaries and cycles.

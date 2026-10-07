# Frame development workflow — role-separated TDD

The human's leverage is at the **test gate**, not at final code review. Tests
are the contract; do not let two agents quietly satisfy one another's code.

## Five steps

1. **Human describes behavior.** Inputs, results, errors, invariants and deliberate
   differences from existing cases. Do not prescribe implementation details.
2. **Spec agent writes failing tests** using `.claude/commands/write-spec.md`.
   It writes no production implementation and reports the actual red run.
3. **Human gates the tests.** Read their behavioral names and assertions. Check
   edge cases, properties, shared conformance, spans and real boundaries. Send
   back incorrect tests before approving; never skip this step.
4. **Implementation agent makes approved tests pass** using
   `.claude/commands/implement-spec.md`. No test edits, weakened gates or bypasses.
5. **Human reviews diff and merges.** Check idiomatic code, architectural bounds,
   real `cargo xtask check` output, and especially the diff of approved tests.

## Patterns

- Domain: `crates/domain/src/cat.rs`
- Use case: `crates/use-cases/src/create_cat.rs`
- Port: `crates/port/src/lib.rs`
- Adapters: `crates/{memory,postgres}/src/`
- Behavioral specs: `tests/integration/create_cat.rs`
- Conformance: `tests/helpers/cat_repository_conformance.rs`
- Properties: `tests/unit/cat_property.rs`
- DB fixture: `tests/helpers/test_db.rs` (also used by examples)
- Consumer observability fixture: `crates/testing/src/lib.rs`
- Architecture/layout: `xtask/src/architecture.rs`

Integration-first means persistence tests really use Postgres, telemetry tests
really use SDK exporters, and HTTP composition tests really cross a socket.
Mocks are for pure logic only. Assert retrievable cats and real spans, not
internal method invocation counts. Tests must be independently isolated and
cleanup must happen even on failure.

Avoid vague specs, implementation-coupled assertions, skipping the human gate,
and changing tests to make a broken implementation look green. Escalate genuine
contract conflicts rather than hiding them. `cargo xtask check` is binary:
nonzero means not done.

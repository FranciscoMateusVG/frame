# Frame Development Workflow

Frame is built using **role-separated TDD**: a spec agent writes failing tests, a human gates the tests, and an implementation agent makes them pass. The human's leverage is at the spec gate, not at code review.

This workflow is the canonical way to add features to Frame and to projects forked from Frame. Skipping the human gate defeats the model.

## The Five Steps

### 1. Describe behavior (human)

Write a plain-English description of the feature. One paragraph. No code, no tests, no pseudo-code. Cover:

- What the use case does (inputs → outputs).
- The error cases and how they should be handled.
- Any non-obvious invariants.
- Whether anything about the spec is *not* like existing use cases.

Save in `docs/specs/<feature>.md`, a GitHub issue, or paste into the spec agent prompt directly.

**Example:**

> `findCatById` takes a `CatId` and returns the matching `Cat`, or `null` if no cat exists with that id. It does not throw for missing cats — only for malformed inputs (which the boundary validation catches). It emits a `findCatById` span. It does not log. It must be safe to call repeatedly with the same id (idempotent reads).

### 2. Spec agent writes failing tests

Invoke the spec agent with `.claude/commands/write-spec.md`. Provide:

- The behavior description from step 1.
- The new use case name.

The agent writes a test file (or files) with all tests red. It does not write implementation code. It reports back when done.

### 3. Human gates the tests

This is the leverage point. Review the test file:

- Do the tests describe the behavior you wanted? Are any tests testing the *implementation* instead of the *behavior*?
- Are the edge cases covered? Are there obvious cases missing?
- Are the test names readable as a spec? If you read just the `it(...)` strings, do they describe what the use case does?
- Are property tests included where invariants exist?
- Did the spec agent stay in the test files, or did it sneak code into `src/`?

This is a five-minute task. Don't skip it. Once approved, the tests are the contract — what the implementation agent will be measured against.

If something's off, send the spec agent back with specific corrections. Iterate until the tests are right.

### 4. Implementation agent makes tests pass

Invoke the implementation agent with `.claude/commands/implement-spec.md`. Provide:

- The path to the locked test file.
- The new use case name.

The agent writes code in `src/` and loops until `pnpm check` is green. It may not modify the test files. It reports back when green.

### 5. Human reviews the diff and merges

Most of this is a skim — `pnpm check` passing means the contract is satisfied. Focus on:

- Is the code idiomatic? Does it look like the existing patterns?
- `git diff tests/` — did the implementation agent modify any tests it shouldn't have? (If yes, escalate; this is a violation.)
- Are there obvious gaps the tests didn't catch?
- Does the diff respect the architectural rules in `CLAUDE.md`?

About ten minutes. Then merge.

## Why This Works

- **Behavior as contract.** The tests *are* the spec. There's no separate "what should this do" document drifting out of sync with reality.
- **Architectural rails prevent drift.** `dependency-cruiser`, type checks, coverage thresholds, and conformance tests all enforce structure independently of what the agents claim.
- **Binary verification.** `pnpm check` either passes or doesn't. No "looks good to me" approvals.
- **Human time is concentrated where humans add value.** You review 50 lines of test descriptions, not 300 lines of implementation. You set direction, the agents execute.

## Anti-Patterns to Avoid

**Skipping the human gate (step 3).** If you let the spec agent and implementation agent run back-to-back without your test review, you've handed the agents both halves of the contract. They'll satisfy each other, not you.

**Letting the implementation agent modify tests.** When stuck, agents sometimes "fix" the test instead of the code. The implementation prompt forbids this; your review verifies it.

**Vague behavior descriptions in step 1.** Garbage in, garbage tests out. Spend two minutes on the description; it saves an hour of test rewrites.

**Over-specifying tests.** "Test every code path" leads to brittle tests that lock the implementation into one shape. Test *behavior*, not *implementation breadth*. A few sharp tests beat fifty mechanical ones.

**Testing internal calls instead of observable behavior.** "Expect `repository.save` to have been called once" is implementation-coupled. "Expect the cat to be retrievable after creation" is behavior-coupled. Frame prefers the latter — that's why integration tests are the primary spec.

## Where to Find Things

- Spec agent prompt: `.claude/commands/write-spec.md`
- Implementation agent prompt: `.claude/commands/implement-spec.md`
- Architectural rules: `.claude/CLAUDE.md`
- Existing patterns to model new work after:
  - Use case: `src/use-cases/create-cat.ts`
  - Use case behavior tests: `tests/integration/create-cat.test.ts`
  - Repository integration tests: `tests/integration/cat-repository.postgres.test.ts`
  - Repository interface: `src/adapters/cat-repository.ts`
  - Adapters: `src/adapters/cat-repository.{postgres,memory}.ts`
  - Conformance suite: `tests/helpers/cat-repository.conformance.ts`
  - Property tests: `tests/unit/cat-property.test.ts`
  - Observability primitive tests: `tests/unit/logger.test.ts`
  - Test observability helper: `tests/helpers/observability.ts`
  - Test database helper: `tests/helpers/test-db.ts`
# Contributing to Frame

## Commit & Push Workflow

Frame uses git hooks (in `.githooks/`, installed by `mix setup` via `core.hooksPath`) as the canonical quality gate. There is no server-side CI — the hooks are the only thing standing between your code and the repository.

### Pre-commit hook (fast)

Formats staged files:
- `mix format` on staged `*.ex`/`*.exs` files, then re-stages them

This is fast and non-disruptive. It catches formatting issues before they're committed.

### Pre-push hook (full verification)

Runs `mix check` — the complete Definition of Done:

```bash
mix lint                        # mix format --check-formatted + credo --strict
mix frame.lint_structure        # Folder/file layout
mix typecheck                   # compile --warnings-as-errors
mix frame.depcruise             # Architectural rules
mix test.coverage               # All tests + coverage thresholds
mix run examples/*.exs          # Examples run cleanly (MIX_ENV=test, one VM each)
mix frame.verify_hooks          # Hooks are installed
```

If **any** of these fail, the push is blocked. Fix the code, don't bypass the gate.

## ⚠️ --no-verify is Forbidden

**Do not use `git push --no-verify` or `git commit --no-verify`.**

There is no server-side CI fallback. The pre-push hook is the only quality gate. Bypassing it means broken code reaches the repository with no safety net.

This is not a suggestion — it's a rule. For human contributors and AI agents alike.

If you believe a hook is producing a false positive:
1. Investigate the failure
2. Fix the root cause (in the code or in the hook configuration)
3. Push normally

If you're stuck and need to push a WIP branch for backup or collaboration, create a draft PR and note in the description that checks are not passing.

## How the Hooks Work

- Hooks live in `.githooks/` and are activated with `git config core.hooksPath .githooks` (run by `mix setup`)
- The pre-commit hook formats staged Elixir files
- The pre-push hook calls `mix check`, which runs the full pipeline
- `mix frame.verify_hooks` (part of `mix check`) confirms the hooks exist and are readable

> In a checkout that shares its git config with other worktrees, `core.hooksPath` is shared too; use `git -c core.hooksPath=.githooks push` instead of changing it.

## Test Organization

```
test/
├── unit/           # Pure logic, memory adapters, frozen-contract validation
├── integration/    # Real sockets: HTTP adapter vs FakeHono, the whole portal, confidentiality
├── helpers/        # FakeHono, Portal harness, PrintApi conformance suite, test observability
└── fixtures/       # Frozen upstream schema + fixtures (copied from monorepo-incluir)
```

- **Conformance**: every PrintApi behaviour is asserted for both adapters (memory and HTTP).
- **Black box**: portal tests drive real HTTP with a cookie jar, like a browser. No Docker needed.
- **Property-based tests**: StreamData in `test/unit/`.
- **Examples**: `examples/*.exs` run as smoke tests during `mix check`.

## Architectural Rules

Enforced by `mix frame.depcruise` (see `scripts/depcruise.ex`):

1. `domain/` → can only depend on `domain/`
2. `use_cases/` and `http/` → can depend on `domain/` and adapter ports, not concrete implementations (only `lib/frame/application.ex` names them)
2b. `domain/`, `use_cases/`, `adapters/` → never depend on `http/`
3. Nothing depends on `lib/frame.ex` internally
4. No OTel SDK in production code (`lib/frame/testing/` excepted)
5. No circular dependencies

Run `mix frame.depcruise` to check manually.

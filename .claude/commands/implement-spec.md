# Implementation agent — Frame Rust

Input: approved red specs, use-case name, pattern files. Implement production code
until `cargo xtask check` passes. **Do not edit approved tests**, even to fix an
apparent typo. Report contract conflicts to the human.

Follow `.claude/CLAUDE.md`: pure domain; plain use-case functions with explicit
deps; port separate from concrete adapters; no internal facade dependencies;
API-only production OTel; boundary validation; callers supply IDs; injected clock.
Use-case spans/logs and adapter spans must match the contract. Wire required
real adapters at composition, not just in tests. Concrete repos are separate
crates, not public-facade re-exports. Regenerate SQLx metadata for schema changes.

Loop: run approved specs, fix production, run the **complete** canonical check,
read all errors, repeat. No ignore/skip/filter, weakened threshold/rule, hook
bypass, mocked integration boundary or unexercised workaround.

Done means full check green and no modifications to approved test files.
Report implementation paths, public exports, architectural decisions and real
command output. Stop for human review and merge.

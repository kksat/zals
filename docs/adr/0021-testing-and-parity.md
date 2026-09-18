# ADR-0021: Testing and parity

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Upstream has a substantial test suite with fixtures (collections under
`test/fixtures/common/collections/ansible_collections/...`) and unit tests that
call internal functions directly (`doCompletion`, `doSemanticTokens`, ...). We
want confidence that `zals` behaves like upstream without committing to
byte-for-byte output equality, which would be brittle and would block reasonable
implementation differences.

## Decision

Combine three approaches:

1. **Port upstream fixtures and unit tests** into `test/`, adapted to Zig, run
   under `zig build test`.
2. Build a **dev-only differential parity harness** in `tools/differential/` that
   runs the same inputs through upstream ALS and `zals` and diffs the results.
3. Maintain a **documented deviations list** in `docs/deviations.md`.

Parity is **behavioral, not byte-for-byte**.

## Consequences

- Ported fixtures give broad coverage cheaply.
- The differential harness catches drift that unit tests miss, but is not part of
  the normal build or CI for end users.
- The deviations list makes intentional differences explicit and reviewable,
  rather than accidental.
- Some upstream tests depend on Node-specific internals and cannot be ported
  directly; those become differential cases instead.
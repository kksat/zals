# ADR-0015: Validation behavior

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Upstream's validation is intricate: it lints on open and save, runs a quick
validation on change, reconciles cached diagnostics against edited lines using an
interval tree, tracks multi-file diagnostics with reference counting, supports
`autoFixOnSave`, and reports progress. Reproducing the observable behavior is
required for parity; reproducing the implementation is not.

## Decision

Implement **full behavioral parity** with these choices:

- **Lint on open and save** via `ansible-lint --offline --nocolor -f codeclimate`.
- **Quick validation on change**, reconciling cached diagnostics against edited
  lines using a **sorted array** instead of an interval tree.
- **Multi-file diagnostics** with reference counting.
- **`autoFixOnSave`** supported.
- **Progress** reported best-effort via `$/progress`.
- **Syntax-check fallback** via `ansible-playbook --syntax-check` when lint is
  unavailable.
- **Schema validation** for metadata files
  ([ADR-0005](0005-json-schema-validation-in-zig.md)).

## Consequences

- Users see the same diagnostics as with upstream.
- The sorted array is simpler than an interval tree and sufficient for the
  document sizes involved; if profiling shows otherwise, it can be swapped
  without changing behavior.
- Reference counting must be correct or diagnostics will leak or disappear
  prematurely; this needs focused tests.
- Best-effort progress means clients may not see every progress update, which is
  acceptable and matches upstream's tolerance.
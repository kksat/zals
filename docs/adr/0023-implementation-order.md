# ADR-0023: Implementation order

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Every Tier 1 feature depends on the YAML layer, the exec layer, and the docs
service. Building features before those foundations would mean stubbing them
repeatedly. The YAML layer in particular is the highest-risk component
([ADR-0004](0004-yaml-parsing-tree-sitter.md)).

## Decision

Build in this order:

1. **M1 — Skeleton & transport:** `build.zig`, `main.zig`, framing,
   `initialize`/`initialized`/`shutdown`/`exit`, document store with incremental
   sync and position encoding, writer thread.
2. **M2 — YAML layer:** tree-sitter backend, DOM, path utilities. Tested in
   isolation against upstream fixtures.
3. **M3 — Exec & config:** `CommandRunner` + POSIX backend, `ansible-config`
   parsing, settings model and resolution.
4. **M4 — Docs service:** `ansible-doc` batching, in-memory cache, cache-writer
   thread, catalog load, background prefetch.
5. **M5 — Providers, one at a time:** semantic tokens → hover → definition →
   completion (+ resolve). Each end-to-end.
6. **M6 — Validation:** YAML diagnostics, schema source and validator,
   `ansible-lint` + codeclimate parser, syntax-check fallback, validation manager
   with cache reconciliation.
7. **M7 — Workspace:** multi-root contexts, `didChangeConfiguration`, watched
   files. The custom `refreshConfiguration` request was later removed by
   [ADR-0043](0043-custom-readiness-without-refresh.md); standard configuration
   updates remain.
8. **M8 — Parity harness & packaging:** differential harness, deviations list,
   logging, release artifacts.

Within M5, **semantic tokens come first** because they exercise YAML + docs + the
token encoder and produce a visible result quickly.

## Consequences

- Foundations are built once and reused, rather than stubbed per feature.
- M2 is validated before any provider depends on it, reducing rework.
- Validation (M6) lands after the providers, so diagnostics can reuse the YAML
  and docs work.
- The order is a plan, not a contract; if a dependency emerges, it can be
  revisited.
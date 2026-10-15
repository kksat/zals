# ADR-0002: Tier 1 feature scope

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Upstream's language server covers a large surface: core LSP features plus
inventory, metadata, and execution-environment integrations. Reimplementing all
of it at once would delay a usable server and spread effort across features that
depend on VS Code-specific machinery.

## Decision

v1 targets **Tier 1 only** — the client-agnostic LSP surface:

- Semantic tokens
- Hover
- Completion (+ resolve)
- Go to definition
- Validation (`ansible-lint`, `ansible-playbook --syntax-check` fallback, and
  JSON-schema validation)

Tier 2/3 features are explicitly out of scope: the VS Code extension, inventory
and metadata notifications, execution environments, and `--generate-docs`.

## Consequences

- A usable, focused server ships sooner.
- The Tier 2 custom messages (`resync/ansible-inventory`,
  `update/ansible-metadata`) are dropped (see
  [ADR-0043](0043-custom-readiness-without-refresh.md)).
- Tier 2/3 can be added later without reworking the Tier 1 architecture, because
  external dependencies sit behind interfaces
  ([ADR-0003](0003-pluggable-external-process-execution.md)).
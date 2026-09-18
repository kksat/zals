# ADR-0006: Bundle the schema snapshot at build time

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Upstream fetches schemas from
`raw.githubusercontent.com/ansible/ansible-lint/main/...` and caches them with a
24-hour TTL. That makes validation depend on the network and on whatever `main`
happens to contain, which is bad for reproducibility and offline use.

## Decision

**Materialize a schema snapshot into `vendor/schemas/` at build time**, pinned to
a known ansible-lint revision, and load it through a `SchemaSource` interface.
The build step is what fetches the snapshot; the repository does not track the
schema files themselves.

## Consequences

- Validation is reproducible and works offline once built.
- The snapshot is pinned, so schema changes are explicit and reviewable.
- The build requires network access the first time (or when the pin changes).
- A future `SchemaSource` backend can fetch at runtime or read from a user cache
  without changing consumers.
- Because ansible-lint is GPL-3.0, the snapshot is GPL-3.0 content; this is one
  reason the project is GPL-3.0-only ([ADR-0020](0020-license.md)).
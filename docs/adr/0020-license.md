# ADR-0020: License

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Upstream `vscode-ansible` is MIT (Red Hat Inc. and Tomasz Maciążek). However, the
JSON schemas we bundle come from `ansible-lint`, which is **GPL-3.0**, and the
schema files carry no separate license header. Bundling them means distributing
GPL-3.0 content.

## Decision

License the whole project **GPL-3.0-only**.

## Consequences

- The bundled schema snapshot is unambiguously compatible.
- The project cannot be relicensed as MIT later without removing the schemas or
  obtaining permission.
- Downstream users must comply with GPL-3.0, which is more restrictive than
  upstream's MIT.
- Attribution to upstream `vscode-ansible` and `ansible-lint` is still
  appropriate and should be recorded in the README or a `NOTICE` file.
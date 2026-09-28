# ADR-0037: No custom LSP messages

- **Status:** Accepted
- **Date:** 2026-09-29
- **Supersedes:** ADR-0016
- **Superseded by:** —

## Context

Upstream's language server defines methods outside standard LSP:
`ansible/errorMessage`, `ansible/docsLibraryReady`, `ansible/refreshConfiguration`,
`resync/ansible-inventory`, and `update/ansible-metadata`.
[ADR-0016](0016-custom-ansible-messages.md) kept the first three.
`ansible/refreshConfiguration` reset settings to defaults instead of re-reading
them. The VS Code extension will not handle any of these methods.

## Decision

`zals` implements none of them. `initialized` starts docs loading and sends no
custom notification. An unknown request gets method-not-found.

## Consequences

- A client that waits for `ansible/docsLibraryReady` will not see it. Docs
  loading still starts on `initialized`.
- Settings change through `initializationOptions` and
  `workspace/didChangeConfiguration` only.
- [ADR-0016](0016-custom-ansible-messages.md) is superseded.

# ADR-0032: No coordination with other language servers

- **Status:** Accepted
- **Date:** 2026-09-28
- **Supersedes:** —
- **Superseded by:** —

## Context

VS Code will run more than one language server for the same language. The Red
Hat Ansible extension (`redhat.ansible`) starts its own server for documents
whose language id is `ansible`. Stopping `zals`, or warning, when that
extension is enabled would block a setup the user wants.

## Decision

The extension starts `zals` for every document its selector matches. It does
not look for `redhat.ansible`, warn about it, or refuse to start.

## Consequences

- Both servers can be active on the same document. Diagnostics, completions,
  hovers, definitions, and code actions from both are shown.
- Semantic tokens and formatting still come from a single provider, chosen by
  the editor.
- Duplicate results are the caller's responsibility, not something the
  extension tries to prevent.

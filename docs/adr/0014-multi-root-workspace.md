# ADR-0014: Multi-root workspace and shared docs cache

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

LSP clients can open multiple workspace folders in one session. Each folder may
have its own Ansible configuration (via `ansible.cfg`, environment, or settings),
which affects module resolution and linting. But module documentation is a
property of the installed Ansible, not of a folder, so duplicating it per folder
would waste memory and process invocations.

## Decision

Support **multi-root workspaces with per-folder contexts**. Each folder gets its
own configuration, document set, and diagnostics. A **single docs cache is shared
across folders**, keyed by `ansible_version + config_fingerprint`.

## Consequences

- Correct behavior when folders have different Ansible configurations.
- Memory is not multiplied by the number of folders for the largest data
  structure.
- The cache key must capture everything that affects docs resolution; getting the
  fingerprint wrong would serve stale docs across folders.
- Per-folder contexts add bookkeeping to every request that needs configuration.
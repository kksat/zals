# ADR-0043: Custom readiness without configuration refresh

- **Status:** Accepted
- **Date:** 2026-10-15
- **Supersedes:** [ADR-0016](0016-custom-ansible-messages.md)
- **Superseded by:** —

## Context

ADR-0016 planned three upstream custom messages. The implemented
`ansible/refreshConfiguration` request instead reset settings to defaults and
rebuilt Workspaces; it did not re-read client configuration, clear documentation
caches, or discover newly installed collections as that ADR claimed.
`ansible/errorMessage` was never implemented. Existing warnings already use
standard `window/showMessage` and `window/logMessage` messages.

The current server has two asynchronous completion notifications. Tests and
benchmarks use them as independent barriers: Workspace scanning can finish
while docs bootstrap is still blocked. Removing these signals would require a
replacement observation contract. Polling feature results would not preserve
exact passive completion timing or indexed-file counts; standard log messages
would introduce a text convention, and work-done progress would require a new
capability and request-response lifecycle.

## Decision

Remove `ansible/refreshConfiguration` and its settings-reset helper. Requests
receive JSON-RPC method-not-found (`-32601`); notifications are ignored without
changing settings or Workspaces. Keep `initializationOptions` and
`workspace/didChangeConfiguration` for settings. Do not add a replacement cache
or installed-collection refresh feature.

Retain both custom readiness notifications at their existing main-thread
handoff points, without changing internal synchronization or background work:

- `ansible/workspaceIndexReady` carries `filesCount` after queued scan results
  have been applied to the index. It can recur after additional scans.
- `ansible/docsLibraryReady` carries `modulesCount` after asynchronous catalog
  bootstrap and module discovery, not full documentation prefetch. Bootstrap
  remains best effort and can report zero modules when Ansible tools are absent.

Do not introduce `ansible/errorMessage`. The Tier 2 methods
`resync/ansible-inventory` and `update/ansible-metadata` remain unsupported.

## Consequences

- This is not a standard-LSP-only policy: the two readiness notifications are
  deliberate exceptions for tests and benchmarks. Ordinary editors can ignore
  them, and feature requests remain nonblocking with respect to startup work.
- Benchmark barriers, counts, timing boundaries, pinned baseline, and thresholds
  remain unchanged. No historical-protocol adapter or harness digest update is
  needed because both readiness methods remain intact.
- Clients sending the removed refresh request must stop doing so. Standard
  configuration updates remain supported but are not a cache-refresh command.
- ADR-0016 remains as the superseded historical policy, not an inventory of
  implemented behavior.

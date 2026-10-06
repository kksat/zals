# ADR-0031: Workspace index

- **Status:** Accepted
- **Date:** 2026-09-28
- **Supersedes:** the parse cache described in [ADR-0024](0024-variable-go-to-definition.md)
- **Superseded by:** —
- **Extended by:** [ADR-0038](0038-workspace-collection-members.md) (metadata
  identity, public collection source symbols, and uniform open/watch exclusions)

## Context

Navigation now reaches across the whole Workspace
([ADR-0032](0032-workspace-wide-navigation.md)): variable and role
find-references, collection references, task-file references, and
`workspace/symbol`. Before this decision every request built a fresh variable
index and re-parsed its file set. ADR-0024 described a path + mtime parse cache,
but none was implemented. Re-parsing every YAML file in a Workspace on every
request is too slow for real repositories.

## Decision

Keep a persistent, in-memory **Workspace index** owned by the server.

- **Contents.** One entry per discovered file (`.yml`, `.yaml`, `.j2`), keyed
  by path and mtime. An entry holds the facts navigation needs: variable
  definitions and references, role references, collection references, task-file
  and vars-file references, role invocations, and workspace symbols. Entries own
  their memory in a per-entry arena. File text and parse trees use separate
  temporary storage, reused by each parsing worker with retained capacity
  capped at 1 MiB per worker; they are not retained in entries. Python/PowerShell source candidates
  contribute path-only symbols, so their bodies are not read.
- **Discovery.** Each Workspace is walked from its root. Hidden directories,
  `node_modules`, `venv`, directories containing `pyvenv.cfg`, and nested
  Workspaces (directories holding the root marker) are skipped.
- **Initial build.** On `initialized`, one pool task per Workspace (ADR-0011)
  discovers files in the background. For larger scans it submits additional
  parsing tasks to the same bounded pool (two to four threads, based on CPU
  count). Up to four tasks share a file cursor and an immutable discovery
  snapshot, with separate parser scratch storage. The discovery task also
  parses files rather than waiting for queued tasks, avoiding pool deadlocks.
  The last task releases the snapshot and reports scan completion. Finished
  entries go to a pending queue guarded by a mutex. The main thread drains that queue before handling each
  message and while waiting for input during background startup, so it remains
  the sole writer of the index map. When the scan finishes the server sends
  `ansible/workspaceIndexReady` with the file count, even if the client is idle.
  Docs bootstrap proceeds independently and does not delay scan submission.
- **Open documents.** Facts for open documents are computed from the document
  store at query time, so unsaved edits win over the indexed disk copy.
- **Updates.** When the client supports dynamic registration, the server
  registers `workspace/didChangeWatchedFiles` for `**/*.{yml,yaml,j2}`,
  `**/ansible.cfg`, and `**/galaxy.yml`, and re-indexes or removes only the
  files named in each event. Without watch support, the index re-stats known
  files before answering and re-parses those whose mtime changed. `didSave`
  also re-indexes the saved file.
- **Partial results.** A request that arrives before the first scan finishes
  answers from the files indexed so far.

## Consequences

- Workspace-wide find-references, hover, and symbol search read the index and
  parse nothing beyond open documents.
- Memory grows with the number of Ansible files in the Workspace; entries store
  names and byte ranges, not parse trees.
- Clients without file watching see new files only after a save or a restart.
- The pending-queue handoff keeps ADR-0011's single-writer rule without locks on
  the read path.

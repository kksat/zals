# ADR-0011: Threading topology

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

The server does blocking work — spawning `ansible-doc`, `ansible-lint`, and
`ansible-playbook`, and parsing YAML — that must not stall the LSP loop. It also
has shared state (documents, caches, diagnostics) that must not be corrupted by
concurrent access.

## Decision

Use a fixed topology:

- **Main thread** — owns all shared state, reads and parses input, dispatches
  requests, and runs the `poll()` loop. It is the **sole writer** of shared
  state.
- **Worker pool** — performs parsing, linting, and schema validation on
  **immutable snapshots** and returns results over channels.
- **Docs thread** — owns `ansible-doc` batching and the docs cache.
- **Cache-writer thread** — persists docs and schema caches. Built in v1.
- **Writer thread** — serializes and writes outgoing messages to stdout.

A **self-pipe** wakes the `poll()` loop when a worker finishes, so the main
thread can apply results without busy-waiting.

Implemented in `concurrency/pool.zig` (worker pool), `services/docs_service.zig`
(docs prefetch + cache writes), and `lsp/writer.zig` (outgoing writer thread).
`workspace/session.zig` owns Workspace lifecycle state on the main thread;
`lsp/server.zig` applies its returned index and warning effects there.
The docs library guards its maps with a mutex held only during ingestion, never
across an `ansible-doc` subprocess. Parsing, linting, and schema validation
remain on the main thread for now; the self-pipe is not needed until those move
to workers.

## Consequences

- No locks on the main data structures; the single-writer rule removes a whole
  class of races.
- Workers must copy or borrow snapshots safely; the ownership rules in
  [ADR-0013](0013-memory-management.md) govern this.
- The self-pipe adds a small amount of plumbing but keeps the loop responsive.
- The cache-writer thread being in v1 means cache persistence is not a later
  retrofit.
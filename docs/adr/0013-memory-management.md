# ADR-0013: Memory management

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Zig has no garbage collector, so ownership must be explicit. The server has two
very different allocation patterns: short-lived, request-scoped work (parsing a
document, building a response) and long-lived state (document store, docs cache,
schema cache) that lives for the process lifetime.

## Decision

Use a **hybrid** approach:

- **Arenas** for request-scoped work. Each request gets an arena that is freed
  when the request completes, so intermediate allocations need no individual
  tracking.
- **Explicit ownership** for long-lived state. The main thread owns the document
  store, caches, and diagnostics; their lifetimes are documented and their
  deallocation is deliberate.
- **Debug allocator in tests** (`std.testing.allocator`) so leaks and
  use-after-free are caught.

## Consequences

- Request handling is simple and fast, with no per-allocation bookkeeping.
- Long-lived state requires discipline; the single-writer rule
  ([ADR-0011](0011-threading-topology.md)) keeps ownership unambiguous.
- Snapshots handed to workers must outlive the worker's use; the main thread
  retains ownership and workers borrow.
- Tests catch leaks early, which matters because the server is long-running.
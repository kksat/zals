# ADR-0051: Cross-request navigation cache

- **Status:** Accepted
- **Date:** 2026-11-25
- **Supersedes:** —
- **Superseded by:** —
- **Extends:** [ADR-0013](0013-memory-management.md) (request arenas), [ADR-0031](0031-workspace-index.md) (Workspace index)

## Context

Profiling a warm `textDocument/definition` request against a
1,000-file Workspace (ReleaseSafe, per `test/benchmark_operations.py`) shows
that nearly all of the per-request time is spent re-deriving state that the
previous request already derived:

- Building the Workspace file set: collecting and path-sorting every index
  entry, re-encoding a URI per file, and re-resolving workspace membership for
  every open document (realpath and stat syscalls included).
- Re-extracting navigation facts for every open document: a full tree-sitter
  YAML parse per document per request.
- Re-resolving URI→path (realpath) and per-directory role/collection search
  paths (directory probing) on every request.

Editors issue several requests per keystroke and many more per cursor move;
only the edited document actually changes between them. The rest of the work
is deterministic given the same Workspace index revision, open-document
revisions, and session state.

## Decision

Derivations that depend only on the index, the document store, and the session
are memoised **across requests** in a server-owned cache
(`src/queries/cache.zig`), keyed by generation counters:

- `WorkspaceIndex.entries_generation` — bumped on every entry-map mutation
  (`putEntry`, `remove`, `dropRoot`).
- `DocumentStore.generation` — bumped on open, change, and close.
- `Session.generation` — bumped by every `apply` that changes roots, marker,
  or venv.

The cache stores:

- **File sets** (Workspace and Role scopes) in a sets arena, invalidated when
  any of the three generations changes. Role scopes without a Workspace and
  scopes that enumerate directories directly are never cached; their file
  lists are not covered by the invalidation inputs.
- **Open-document facts** per URI in a per-document arena, keyed by document
  identity and version, so an edit re-extracts exactly one document. Entries
  are dropped on `textDocument/didClose`.
- **Resolved paths** (URI→realpath) and **per-directory role/collection search
  paths**, invalidated on index or session generation changes.

Files read from disk while building a cached set (vars-load targets and
collection metadata that the index does not cover) are recorded as mtime
probes; a cache hit re-stats those few paths and rebuilds on any mismatch.
Without file watching, the request lease forces the index's stale refresh
before the cache is consulted, so mtime-based discovery keeps working.

The request arena and ADR-0013 are unchanged: everything a request returns is
still request-owned. Cache-owned storage is only borrowed during a request,
and mutations happen solely on the main thread between requests
([ADR-0011](0011-threading-topology.md)), so borrowed slices cannot dangle
mid-request.

## Consequences

- Warm navigation requests stop re-sorting, re-encoding, re-parsing, and
  re-statting unchanged state; measured warm medians drop by more than half.
- The first request after any mutation (keystroke, save, watcher event) pays
  the rebuild cost once, matching the previous per-request cost, and never
  exceeds it.
- Memory is bounded: the sets arena keeps its high-water mark (a small factor
  of the Workspace size), and per-document arenas are dropped on close.
- Document identity plus version is trusted for fact freshness; a client that
  re-opens a document at the same version with different text (an LSP
  violation) would be served stale facts until the next generation change.
- Symlink retargets of an already-open URI resolve to the cached path until an
  index or session generation change; watch events for the affected files
  invalidate sooner.

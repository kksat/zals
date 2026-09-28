# ADR-0008: Hybrid docs loading and caching

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

`ansible-doc` is fast for the catalog (~0.6 s) and for small batches, but loading
all ~861 modules takes ~6.3 s and ~7.7 MB. Blocking startup on the full load
would make the server feel slow; loading only on demand would make the first
hover or completion stall.

## Decision

Use a **hybrid strategy**:

1. **Eager catalog** — run `ansible-doc -l --json` at startup to get module names
   and short descriptions.
2. **Lazy batched docs** — when a feature needs a module's full docs, request it
   in a batch with other pending modules.
3. **Background prefetch** — after startup, load all modules in the background
   and persist them through the cache-writer thread.

The cache is keyed by `ansible_version + config_fingerprint` and shared across
workspace folders ([ADR-0014](0014-multi-root-workspace.md)).

This is implemented in `services/docs_service.zig` (orchestration),
`services/docs_cache.zig` (JSON persistence), and `concurrency/pool.zig` (the
worker pool). The catalog is loaded synchronously on `initialized`. Prefetch
and cache writes run on the pool and are cancelled on shutdown.

## Consequences

- Startup is fast; the catalog is available almost immediately.
- The first hover/completion for an uncached module may wait on a batch, but
  batching amortizes the process cost.
- The background prefetch warms the cache so later requests are instant.
- The cache-writer thread is part of v1, not a later optimization
  ([ADR-0011](0011-threading-topology.md)).
- Cache invalidation must account for Ansible upgrades and config changes via the
  fingerprint.
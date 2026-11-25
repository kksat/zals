# ADR-0052: Audited subset fast path for YAML parsing

- **Status:** Accepted
- **Date:** 2026-11-21
- **Supersedes:** —
- **Superseded by:** —

Amends [ADR-0004](0004-yaml-parsing-tree-sitter.md).

## Context

Cold workspace indexing is dominated by YAML parsing. Profiling a 1000-file
workspace showed ~80% of scan CPU inside the vendored tree-sitter runtime and
grammar (~0.3 ms per file, confirmed against a standalone C build): the
tree-sitter-yaml grammar is heavily ambiguous GLR. The pure-Zig indent-based
subset parser parses the same documents ~13x faster, but ADR-0004 made
tree-sitter the default because the subset parser does not model every YAML
construct: flow collections, anchors, aliases, tags, escape sequences,
directives, and plain-scalar continuations lower differently, so blanket
preferment of either backend would change navigation results per document.

## Decision

The default (`.tree_sitter`) backend parses through an **audited subset fast
path**: `parser.parseChecked` runs the subset parser with a compatibility
audit that records every construct known to lower differently in tree-sitter
and fails with `UnsupportedYaml`. The dispatch in `yaml.parse` then:

1. uses the subset result when the audit passes,
2. defers to tree-sitter on any audited-subset failure, and
3. falls back to the unaudited subset parser when tree-sitter itself fails,
   exactly as before.

The audit is deliberately conservative — it flags leading flow indicators,
anchors, aliases, tags, unterminated quotes, escapes, inline nested
sequences, unmarked document boundaries, and colon-less continuation lines —
so an unflagged document is one the subset parser reproduces byte-for-byte.
To make that literal, the subset parser now matches tree-sitter's node
ranges exactly (container ends including trailing comments and
end-of-document trivia, maps under `- ` items starting at item content,
value-less pairs ending past their colon, scalars ending before trailing
comments). A differential test asserts DOM equality — kinds, values, and all
ranges — between the two backends for every audit-passing checked-in fixture
and a block-YAML corpus, and a second corpus asserts that known-divergent
constructs are always deferred.

## Consequences

- Cold indexing of block-style Ansible workspaces (the overwhelming
  majority) skips the tree-sitter parse: a 1000-file workspace went from
  ~200 ms to ~40 ms median on a 4-vCPU machine, and 8000 files from ~1 s to
  ~0.3 s. Interactive document parses get the same speedup.
- Backend selection no longer changes any navigation result: a document
  either takes the audited fast path with a verified-identical tree, or is
  parsed by tree-sitter as before.
- Fixing range parity also fixed latent subset-parser bugs visible in
  fallback mode, such as block scalars swallowing dedented sequence items.
- Every new divergence discovered in the wild must be added to the audit and
  to the deferral corpus; the fixture differential test is the guard.
- The subset parser remains a fallback and reference implementation; a
  future pure-Zig backend can absorb the audit (see ADR-0004).

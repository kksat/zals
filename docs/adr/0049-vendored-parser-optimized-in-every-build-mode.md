# ADR-0049: Optimize the vendored parser in every build mode

- **Status:** Accepted
- **Date:** 2026-11-21
- **Supersedes:** —
- **Superseded by:** —

## Context

The tree-sitter YAML parser is vendored C code linked into every build. Cold
indexing (first workspace scan) is dominated by that parser, and at `-O0` it is
slow enough to make Debug builds unusable against real workspaces. The obvious
fixes — defining `NDEBUG` or forcing a global optimize level — would either
change assertion behavior inside the vendored code or discard the Zig-level
debug checks requested for the rest of the binary.

## Decision

In `build.zig`, the vendored parser library's C code is compiled with
optimization enabled (`-O2`) in **every** build mode, including Debug, without
defining `NDEBUG` and without changing the requested Zig debug checks for the
rest of the build. Release-mode flags are unchanged.

## Consequences

- Debug builds keep Zig-level debug checks everywhere while remaining fast
  enough for real workspace scans.
- Vendored C assertions stay active in Debug builds; only codegen changes.
- A future pure-Zig YAML backend ([ADR-0004](0004-yaml-parsing-tree-sitter.md))
  would remove this special case entirely.

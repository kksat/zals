# ADR-0050: Native CEL rule engine via zig-cel package dependency

- **Status:** Accepted
- **Date:** 2026-11-23
- **Supersedes:** —
- **Superseded by:** —

## Context

Native Ansible diagnostics evaluate `.cel` rule files in process without an external
runtime service, Python interpreter, or C++/protobuf build closure
([PRD-0002](../prd/0002-cel-rules.md)). Every release target in the five-target
matrix (`x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-macos.13.0`,
`aarch64-macos.13.0`, `x86_64-windows`) must continue to cross-compile under the
pinned Zig 0.15.1 toolchain ([ADR-0019](0019-toolchain-build-and-platforms.md)).

## Decision

1. **Package dependency:** Declare
   [`kksat/zig-cel`](https://github.com/kksat/zig-cel) at pinned commit `445a967`
   in `build.zig.zon` as the `zig_cel` `url`+`hash` package dependency and
   consume its registered `cel` module via `b.dependency("zig_cel", ...).module("cel")`.
   Engine changes go upstream rather than into a vendored copy. `zig-cel` is
   licensed under Apache-2.0 (compatible with Zals's GPL-3.0-only distribution).
2. **One-rule-per-file declaration and re-rooting:** Each `.cel` rule file must
   parse as a top-level `zals.Rule{ ... }` message literal containing literal
   metadata (`id`, `target`, `severity`, optional `field`, optional
   `schema_version: 1`) plus `condition` and `message` CEL expressions. The host
   validates the declaration and re-roots the single parsed `cel.ast.Ast` onto
   `condition` and `message` to compile them separately while preserving original
   `.cel` byte offsets.
3. **Structural load-time linting plus runtime validation:** Because `zig-cel`
   does not implement a static type-checking phase, rule loading runs a host-side
   structural AST lint (literal metadata validation, known targets and field
   selectors, declared bindings and comprehension scope resolution, known stdlib
   functions, static literal root-type checks, regex pattern validation, and
   source/node/depth/comprehension limits). Runtime evaluation always validates
   that `condition` yields `bool` and `message` yields `string`, isolating errors
   without fabricating Ansible violations.
4. **Per-worker program ownership:** `cel.vm.Program` reuses internal execution
   buffers across runs and must not run concurrently. Workers clone/compile their
   own `WorkerRule` instances into heap-allocated arenas so concurrent evaluations
   never share mutable VM state.

## Consequences

- Cross-building all five release targets succeeds with the existing Zig toolchain
  and no external C++ dependencies.
- Evaluation is data-only and deterministic; any bounded lexical or structural
  facts needed by rules are computed by the host and passed as immutable CEL
  map/list values rather than via custom side-effectful host functions.
- Updating `zig-cel` requires only updating the pinned archive `url` and
  content `hash` in `build.zig.zon`.
- Upstream `zig-cel` at commit `445a967` has a regex codegen defect in `regex.zig`
  where alternations with three or more top-level branches skip branch 2+;
  built-in `.cel` rules express regex alternations using 2-way groups or
  separate `matches()` calls rather than maintaining local engine patches.

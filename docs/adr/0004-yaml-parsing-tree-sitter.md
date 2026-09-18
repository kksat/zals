# ADR-0004: YAML parsing via tree-sitter with a Zig DOM

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Every Tier 1 feature depends on understanding the YAML document: semantic tokens
need node kinds and ranges, hover and completion need the path to the cursor, and
definition needs to resolve a module name. Upstream uses the `yaml` npm package
and a set of AST helpers (`yamlAst.ts`).

Zig has no mature YAML library. Writing a full YAML parser from scratch is a
large, error-prone effort that would dominate the project.

## Decision

Use **tree-sitter-yaml** (vendored C, compiled by `zig cc`) to produce a concrete
syntax tree, then lower it into a **Zig semantic DOM** of `Scalar`, `Map`, `Seq`,
and `Pair` nodes that retain source ranges. Path utilities mirror upstream's
`yamlAst` helpers: `getPathAt`, `AncestryBuilder`, `isTaskParam`, `isPlayParam`,
`isBlockParam`, `isModuleParam`, and friends.

The parser sits behind a **`YamlParser` interface** so a pure-Zig parser can
replace it later.

## Consequences

- We get a battle-tested YAML grammar without writing one.
- tree-sitter is error-tolerant, which suits an editor: incomplete documents
  still produce a usable tree.
- We must vendor and build C code, which complicates the build slightly and
  requires the C toolchain (see [ADR-0019](0019-toolchain-build-and-platforms.md)).
- The semantic DOM is the shared substrate for all providers; its correctness is
  the highest-risk part of the project and is tested first
  ([ADR-0023](0023-implementation-order.md)).
- tree-sitter's tree is not a YAML data model; we own the lowering logic and its
  edge cases (anchors, aliases, multi-line scalars, tags).
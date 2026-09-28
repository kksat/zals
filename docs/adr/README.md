# Architecture Decision Records

Each ADR captures one decision, its context, and its consequences. Statuses are
`Proposed`, `Accepted`, `Deprecated`, or `Superseded by ADR-NNNN`.

| ADR | Title | Status |
| --- | --- | --- |
| [0001](0001-standalone-stdio-lsp-server.md) | Standalone stdio LSP server | Accepted |
| [0002](0002-tier-1-feature-scope.md) | Tier 1 feature scope | Accepted |
| [0003](0003-pluggable-external-process-execution.md) | Pluggable external-process execution | Accepted |
| [0004](0004-yaml-parsing-tree-sitter.md) | YAML parsing via tree-sitter with a Zig DOM | Accepted |
| [0005](0005-json-schema-validation-in-zig.md) | JSON Schema validation in Zig | Accepted |
| [0006](0006-bundle-schema-snapshot.md) | Bundle the schema snapshot at build time | Accepted |
| [0007](0007-module-docs-via-ansible-doc.md) | Module documentation via `ansible-doc` | Accepted |
| [0008](0008-hybrid-docs-loading.md) | Hybrid docs loading and caching | Accepted |
| [0009](0009-go-to-definition-target.md) | Go-to-definition target | Accepted |
| [0010](0010-hand-rolled-lsp-transport.md) | Hand-rolled LSP/JSON-RPC transport | Accepted |
| [0011](0011-threading-topology.md) | Threading topology | Accepted |
| [0012](0012-incremental-sync-and-position-encoding.md) | Incremental sync and position encoding | Accepted |
| [0013](0013-memory-management.md) | Memory management | Accepted |
| [0014](0014-multi-root-workspace.md) | Git workspaces and shared docs cache | Accepted |
| [0015](0015-validation-behavior.md) | Validation behavior | Accepted |
| [0016](0016-custom-ansible-messages.md) | Custom `ansible/*` messages | Accepted |
| [0017](0017-settings-compatibility.md) | Settings compatibility | Accepted |
| [0018](0018-cli-and-logging.md) | CLI and logging | Accepted |
| [0019](0019-toolchain-build-and-platforms.md) | Toolchain, build, and platforms | Accepted |
| [0020](0020-license.md) | License | Accepted |
| [0021](0021-testing-and-parity.md) | Testing and parity | Accepted |
| [0022](0022-repository-structure.md) | Repository structure | Accepted |
| [0023](0023-implementation-order.md) | Implementation order | Accepted |
| [0024](0024-variable-go-to-definition.md) | Variable go-to-definition | Accepted |
| [0025](0025-variable-references.md) | Variable references | Accepted |
| [0026](0026-release-process.md) | Release process | Accepted |
| [0027](0027-document-symbols.md) | Document symbols | Accepted |
| [0028](0028-debug-code-actions.md) | Debug code actions | Accepted |
| [0029](0029-role-navigation.md) | Role go-to-definition and go-to-implementation | Accepted |
| [0030](0030-extract-tasks-code-actions.md) | Extract tasks code actions | Accepted |

## Template

```markdown
# ADR-NNNN: Title

- **Status:** Accepted
- **Date:** YYYY-MM-DD
- **Supersedes:** —
- **Superseded by:** —

## Context

What forces are at play? What is the problem?

## Decision

What we will do.

## Consequences

What becomes easier or harder as a result.
```
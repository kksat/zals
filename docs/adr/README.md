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
| [0014](0014-multi-root-workspace.md) | Multi-root workspace and shared docs cache | Accepted |
| [0015](0015-validation-behavior.md) | Validation behavior | Accepted |
| [0016](0016-custom-ansible-messages.md) | Custom `ansible/*` messages | Superseded by ADR-0037 |
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
| [0031](0031-vscode-extension-bundles-zals.md) | VS Code extension bundles the zals binary | Accepted |
| [0032](0032-no-coordination-with-other-language-servers.md) | No coordination with other language servers | Accepted |
| [0033](0033-ansible-language-document-selector.md) | Ansible language document selector | Accepted |
| [0034](0034-yaml-grammar-only.md) | YAML grammar only | Accepted |
| [0035](0035-extension-ignores-python-configuration.md) | Extension ignores Python configuration | Accepted |
| [0036](0036-extension-settings-contribution.md) | Extension settings contribution | Accepted |
| [0037](0037-no-custom-lsp-messages.md) | No custom LSP messages | Accepted |
| [0038](0038-vscode-extension-in-this-repository.md) | VS Code extension lives in this repository | Accepted |
| [0039](0039-vscode-extension-is-a-language-client-only.md) | VS Code extension is a language client only | Accepted |
| [0040](0040-distribution-marketplaces-and-releases.md) | Distribution to marketplaces and GitHub releases | Accepted |
| [0041](0041-extension-identifier-and-display-name.md) | Extension identifier and display name | Accepted |
| [0042](0042-workspace-trust-disabled.md) | Workspace trust disabled | Accepted |
| [0043](0043-strictly-bundled-binary-at-runtime.md) | Strictly bundled binary at runtime | Accepted |

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
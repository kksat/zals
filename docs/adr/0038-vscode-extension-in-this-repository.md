# ADR-0038: VS Code extension lives in this repository

- **Status:** Accepted
- **Date:** 2026-09-29
- **Supersedes:** —
- **Superseded by:** —

## Context

The extension version is the `zals` version, and each platform package bundles
the matching release binary
([ADR-0031](0031-vscode-extension-bundles-zals.md)).
[ADR-0022](0022-repository-structure.md) describes a server-only tree. A second
repository would be a second release train for that same version.

[ADR-0002](0002-tier-1-feature-scope.md) left the VS Code extension out of
scope. [ADR-0001](0001-standalone-stdio-lsp-server.md) said the client adapter
was out of scope for v1.

## Decision

The extension source lives in this repository, at `editors/vscode`. The
existing release builds one platform-specific VSIX for each binary it already
cross-compiles: Linux x64/arm64, macOS x64/arm64, and Windows x64.

This supersedes only the "VS Code extension is out of scope" clause of
[ADR-0002](0002-tier-1-feature-scope.md) and the matching consequence of
[ADR-0001](0001-standalone-stdio-lsp-server.md). The server stays a standalone
stdio process.

## Consequences

- `editors/vscode` sits outside the layer-first `src/` tree. It launches the
  release binary; it does not link Zig code.
- release-please bumps the extension version together with `src/main.zig`,
  `build.zig.zon`, and `python/pyproject.toml`.
- Inventory, metadata, execution environments, and `--generate-docs` stay out
  of scope.

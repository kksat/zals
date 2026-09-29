# ADR-0001: Standalone stdio LSP server

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

Upstream's language server is launched by the VS Code extension as a Node module
over IPC (`TransportKind.ipc`). It is not designed to be launched directly by
arbitrary editors. We are reimplementing the server in Zig, where the Node IPC
transport is neither available nor desirable.

## Decision

`zals` is a **standalone LSP server that speaks JSON-RPC over stdio**. It is not
a drop-in replacement for the VS Code extension's bundled server. Any LSP client
that can launch a stdio server can use it.

## Consequences

- The server is usable from Neovim, Emacs, Helix, Zed, and any other LSP client
  without a Node runtime.
- We do not need to implement Node's IPC framing.
- The VS Code extension cannot use `zals` without a small adapter. That adapter
  is in scope ([ADR-0038](0038-vscode-extension-in-this-repository.md)).
- stdio means stdout is reserved for the protocol; all logging goes to stderr or
  a log file (see [ADR-0018](0018-cli-and-logging.md)).
# ADR-0031: VS Code extension bundles the zals binary

- **Status:** Accepted
- **Date:** 2026-09-28
- **Supersedes:** —
- **Superseded by:** —

## Context

A VS Code extension should install `zals` without a separate Homebrew or pip
step, and the extension version should be the `zals` version. The server is a
stdio binary ([ADR-0001](0001-standalone-stdio-lsp-server.md)). Release
artifacts already exist per platform ([ADR-0026](0026-release-process.md)).

Looking `zals` up on `PATH`, or downloading it on first launch, lets the
extension version and the running server diverge. A download also needs a
network and fails offline.

## Decision

Each platform-specific extension package **bundles the matching `zals` release
binary** and runs it over stdio. Platforms are the ones `zals` already ships:
Linux x64/arm64, macOS x64/arm64, Windows x64. The extension version is that
`zals` version. Installing the extension is the install.

## Consequences

- An extension-only fix cannot ship without a `zals` version bump, or it waits
  for the next `zals` release.
- Publishing the extension is another artifact of the same release that
  publishes the binaries, the Homebrew formula, and the PyPI wheels.
- [ADR-0001](0001-standalone-stdio-lsp-server.md) still holds: the server stays
  stdio-only. The extension is the client adapter that ADR-0001 left out of
  scope.

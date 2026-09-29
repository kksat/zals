# ADR-0040: Distribution to marketplaces and GitHub releases

- **Status:** Accepted
- **Date:** 2026-09-29
- **Supersedes:** —
- **Superseded by:** —

## Context

The extension needs to be installable directly from VS Code and from editors
that do not use Microsoft's Visual Studio Marketplace (such as VSCodium), as
well as in air-gapped or offline environments.

## Decision

The release process will publish platform-specific `.vsix` packages to:
1. The **Visual Studio Marketplace** (for standard VS Code).
2. The **Open VSX Registry** (for VSCodium and open-source derivatives).
3. **GitHub Release assets** alongside the server binaries, wheels, and Homebrew
   formula.

## Consequences

- The release pipeline requires publishing tokens (`VSCE_PAT` for Marketplace
  and `OVSX_PAT` for Open VSX). If either secret is not configured in the
  repository, CI logs a notice and skips that store without failing the build.
- Each platform target (Linux x64/arm64, macOS x64/arm64, Windows x64) gets a
  dedicated platform-specific `.vsix` packaging the matching `zals` executable,
  which is always uploaded to the GitHub release.
- Users can install without internet access by downloading the `.vsix` from the
  GitHub release.
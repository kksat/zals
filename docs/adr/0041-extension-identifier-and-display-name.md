# ADR-0041: Extension identifier and display name

- **Status:** Accepted
- **Date:** 2026-09-29
- **Supersedes:** —
- **Superseded by:** —

## Context

Publishing to the Visual Studio Marketplace and Open VSX Registry requires an
immutable extension identifier (`<publisher>.<name>`) and a human-facing
display name. Changing the identifier after publication breaks update paths and
splits user installs.

## Decision

The extension uses:
- **Publisher:** `kksat`
- **Name:** `zals` (making the full extension ID `kksat.zals`)
- **Display name:** `Ansible Language Server (zals)`

## Consequences

- The extension URL is `kksat.zals` on both registries.
- It does not collide with `redhat.ansible`.
- Users searching for "Ansible" or "Ansible Language Server" find `Ansible Language Server (zals)` in the Extensions view, with the server identity visible in the name.
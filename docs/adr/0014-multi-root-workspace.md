# ADR-0014: Git workspaces and shared docs cache

- **Status:** Accepted
- **Date:** 2025-09-18
- **Updated:** 2026-09-28
- **Supersedes:** —
- **Superseded by:** —

## Context

LSP clients can open several folders in one session. Those folders are not the
project boundary. A Workspace is the nearest directory containing `.git` (a
directory or a file) at or above an opened folder. Two opened folders that walk
up to the same `.git` are one Workspace. A different `.git` is a different
Workspace. A nested `.git` is its own Workspace and is included only when an
opened folder walks up to it; its files lie outside the parent. A folder with
no `.git` at or above it has no Workspace.

Module documentation is a property of the installed Ansible, not of a
Workspace, so duplicating it per Workspace would waste memory and process
invocations.

This decision originally treated each folder the client opened as its own
context. That split one git checkout into several contexts.

## Decision

Resolve each opened folder to its Workspace and keep **one context per distinct
`.git`**. The directory that contains the `.git` file or `.git` directory is
the Workspace root. A **single docs cache is shared across Workspaces**, keyed
by `ansible_version + config_fingerprint`.

When an opened folder has no Workspace and `ansible.workspace.missingGitWarning`
is true (the default), the server shows one session warning via
`window/showMessage`. Turning the setting off suppresses the warning. The
folder still has no Workspace.

## Consequences

- Workspace-scoped search uses the git root, including paths the client did not
  open as a folder.
- Files under a nested `.git` stay outside the parent Workspace until an opened
  folder walks up to that nested root.
- A `.git` file (a submodule checkout or a linked worktree) marks the directory
  that contains it.
- The docs cache is still shared, so memory is not multiplied by the number of
  Workspaces for the largest data structure.
- The cache key must capture everything that affects docs resolution; getting
  the fingerprint wrong would serve stale docs across Workspaces.
- A tree with no `.git` gets no workspace-wide features.

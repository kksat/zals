# ADR-0040: Absolute navigation file URIs

- **Status:** Accepted
- **Date:** 2026-10-02

## Context

LSP navigation locations require absolute file URIs, not Workspace-relative
URIs. A fresh server against an ordinary absolute Ansible configuration already
returns correct existing role targets. However, `ANSIBLE_ROLES_PATH` and
`ANSIBLE_COLLECTIONS_PATH` can contain relative filesystem paths: role
resolution successfully reads them relative to the server's working directory,
then URI conversion previously emitted `file://role-path/...`, which treats the
first component as an authority rather than part of an absolute local path.

## Decision

At the shared filesystem-path-to-URI boundary, anchor relative paths to the
server process's working directory before constructing a `file://` URI. This
uses the same base as the successful filesystem lookup, not the referencing
file's directory or the Workspace root. Existing absolute filesystem paths and
already supplied file URIs retain their behavior.

Do not require a target to exist or call `realpath`: code actions also convert
paths for files they are about to create. Preserve path components, including
`..`, rather than lexically collapsing them across possible symlinks. This
changes URI serialization, not Ansible search-path precedence or role identity.

## Verification

`test/navigation_uris_e2e.zig` drives the real stdio server with a pinned cwd,
isolated HOME/cache, and a dedicated checked-in Workspace marker. Dependencies
live outside that Workspace to prevent editor fallback from concealing the
configured-path bug. Explicit expected locations name the role's argument
specs/metadata and main task file at a zero-width `(0, 0)` range. The suite
compares the full URI and range, independently decodes the returned URI, and
opens that exact intended file. An absolute-path control guards existing
behavior. No external checkout, installation, network, or fixture copies are
needed.

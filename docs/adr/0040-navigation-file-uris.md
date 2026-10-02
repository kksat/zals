# ADR-0040: Absolute, escaped navigation file URIs

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
file's directory or the Workspace root. Existing absolute filesystem paths
retain their targets; already supplied file URIs pass through unchanged.

Do not require a target to exist or call `realpath`: code actions also convert
paths for files they are about to create. Preserve path components, including
`..`, rather than lexically collapsing them across possible symlinks. This
changes URI serialization, not Ansible search-path precedence or role identity.

Independently reproduced stdio navigation also returned literal spaces, `%`,
and `#` in filesystem paths, making clients decode the wrong filename or treat
part of it as a fragment. Serialize filesystem paths as raw URI path components
with the standard URI formatter so those bytes are escaped. Decode incoming
file-URI percent escapes exactly once: `%2520` names a literal `%20`, not a
space. This inverse conversion is required when an editor opens a returned URI
and then navigates from that document; fixing output alone leaves that second
request unable to resolve files relative to it.

## Verification

`test/navigation_uris_e2e.zig` drives the real stdio server with a pinned cwd,
isolated HOME/cache, and a dedicated checked-in Workspace marker. Dependencies
live outside that Workspace to prevent editor fallback from concealing the
configured-path bug. Explicit expected locations name the role's argument
specs/metadata and main task file at a zero-width `(0, 0)` range. The suite
compares the full URI and range, independently decodes the returned URI, and
opens that exact intended file. An absolute-path control guards existing
behavior. Explicit escaped URI suffixes distinguish a literal `%20` from a
space and ensure `#` never becomes a fragment. A follow-up case opens the URI
returned by go-to-implementation, then navigates its `import_tasks` to the exact
existing sibling task file. No external checkout, installation, network, or
fixture copies are needed.

# ADR-0038: Workspace collection identity and members

- **Status:** Accepted
- **Date:** 2026-10-02
- **Extends:** [ADR-0031](0031-workspace-index.md),
  [ADR-0032](0032-workspace-wide-navigation.md)

## Context

Workspace source checkouts need not use Ansible's installed
`ansible_collections/namespace/collection` layout. A dotted or arbitrarily
named directory can hold the same collection metadata and members.
Collection discovery already reads both YAML metadata extensions, but role
resolution only tried the installed layout, and collection symbols invented
a `galaxy.yml` target even when the file was `galaxy.yaml`.

## Decision

A Workspace collection is a directory carrying `galaxy.yml` or
`galaxy.yaml` that declares `namespace` and `name`, either at the
Workspace root or anywhere below an `ansible_collections/` directory in
that Workspace. Metadata determines its `namespace.name` identity, not
the spelling or depth of its directory. Ordinary metadata elsewhere does
not introduce a Workspace collection.

Collection symbols target the actual metadata file with a zero-width range
at its start. FQCN roles and roles named through declared `collections:`
also try these metadata-defined roots after the configured standard-layout
collection paths, before unrelated short-role/editor fallback paths.
Existing standard/Installed resolution order is unchanged.

Role symbol names remain short. In addition to their case-insensitive name
substring, search matches their collection-qualified identity
(`namespace.collection.role`). Thus a collection query returns its
collection and role members; `containerName` remains the collection FQCN.
This does not rename tasks, plays, task files or noncollection roles, nor
expand their query matching.

All results retain absolute file URIs. Metadata from open documents replaces
disk metadata, including an unsaved identity change. Workspace discovery
boundaries still exclude virtual environments, hidden/package directories,
nested Workspaces and Installed collection files.

## Verification

The independent stdio suite `test/collection_symbols_e2e.zig` uses a
static Workspace with standard, dotted, arbitrary and Workspace-root
collections. Expected names, containers and locations are handwritten.
Every expected and returned target must exist. See
[Workspace collection members](../workspace-collection-members.md) for
the API contract and RED/GREEN evidence.

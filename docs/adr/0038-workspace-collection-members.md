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

Role, module and plugin symbol names remain collection-local. In addition
to their case-insensitive name substring, search matches their
collection-qualified identity (`namespace.collection.member`). Thus a
collection query returns its collection and public members;
`containerName` remains the collection FQCN.
This does not rename tasks, plays, task files or noncollection roles, nor
expand their query matching.

Modules and plugins contribute one LSP Module symbol per public source file,
pointing to file start: Python `.py` sources in conventional
`plugins/<type>/` directories, and PowerShell `.ps1` sources in
`plugins/modules/`. Nested plugin-relative paths become dotted names.
Supported types are `modules`, `action`, `become`, `cache`, `callback`,
`cliconf`, `connection`, `filter`, `httpapi`, `inventory`, `lookup`,
`netconf`, `shell`, `strategy`, `terminal`, `test`, and `vars`.
Private path components (starting `_` or `.`), package initializers,
`module_utils`, `doc_fragments`, unknown helper directories, tests, docs
and sources outside a metadata-defined collection's own `plugins/` tree
are not member symbols. Non-private nested sources in a supported plugin
kind are public by this path-based rule; we do not inspect Python exports
or attempt to distinguish helpers by executing them.

Discovery retains Python/PowerShell source candidates under `plugins/`,
but they never contribute YAML/variable/navigation facts. Open buffers and
watch/save events obey the same Workspace discovery exclusions as the
initial scan. Watch registration includes plugin source extensions;
without watching, known sources retain ADR-0031's refresh behavior.

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

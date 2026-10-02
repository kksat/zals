# Workspace collection identity and members

`workspace/symbol` lists project sources, not Installed collections.
Collection identity comes from `namespace` and `name` in
`galaxy.yml` or `galaxy.yaml`. Supported roots are:

- the Workspace itself;
- `ansible_collections/namespace/collection/`;
- `ansible_collections/namespace.collection/`;
- any other directory at any depth below `ansible_collections/` carrying
  that metadata.

The root marker still defines Workspace membership. Metadata outside these
roots does not create a collection. Installed dependencies, all virtual
environments, hidden/package directories and nested Workspaces stay outside
the Workspace symbol set.

Collections have LSP Package kind and point to the actual metadata file.
Roles have Module kind and point to their role source (normally
`tasks/main.yml` or `tasks/main.yaml`). All targets are absolute file
URIs with zero-width ranges at file start. Member `containerName` is the
nearest enclosing collection's metadata FQCN.

## Searching

Role names stay short, e.g. `dotted_role`, not
`contract.dotted.dotted_role`. The case-insensitive substring query
matches either the short name or its collection-qualified identity.
`contract.dotted` therefore finds the collection and its role members;
`contract.dotted.dotted_role` finds that role. Other Workspace symbol
families retain their existing name-based matching.

Role navigation tries configured standard collection paths first, then
metadata-defined Workspace roots for FQCN/declared-collection roles.
Open, unsaved metadata changes immediately change the metadata-defined
identity and the symbol container; no save or restart is required.

## Black-box verification

Run from the repository root:

```sh
make build
DEVELOPER_DIR=/nonexistent zig test test/collection_symbols_e2e.zig
```

The environment override is the repository's macOS SDK workaround (on
other platforms it is unnecessary). Tests start a real stdio zals process,
isolate HOME, use static explicit collection paths, and wait for the
Workspace index readiness notification. They neither install dependencies
nor edit fixture files on disk. Unsaved changes use only LSP notifications.

TDD evidence (each RED used the same command with `--test-filter`):

| Slice / filter | RED | GREEN |
| --- | --- | --- |
| `Workspace root collection symbol` | `FileNotFound`: invented `galaxy.yml` target | 1 test passed; target is existing `galaxy.yaml` |
| `FQCN role navigation` | expected 1 location, got `null` | 1 test passed; definition and implementation target the dotted root |
| `role symbols retain` | expected 1 qualified-query result, got 0 | 1 test passed; short name and explicit collection container retained |
| `metadata outside` | expected 0, got noncollection metadata symbol | 1 test passed; noncollection, nested and venv roots excluded |

Regression checks: `make test` passed; `make e2e` passed
265 semantic cases with 0 failures. The expanded layout suite also covers
standard/arbitrary/root role targets, short roles in declared collections,
both metadata extensions, existing Installed dependency exclusion, and an
unsaved metadata rename.

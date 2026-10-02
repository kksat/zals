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
`tasks/main.yml`, then `tasks/main.yaml`, then another discovered role file
when neither main exists). Modules and plugins also have
Module kind and point directly to their source files. All targets are absolute
file URIs with zero-width ranges at file start. Member `containerName` is the
nearest enclosing collection's metadata FQCN.

## Searching

Role, module and plugin names stay collection-local, e.g. `dotted_role`, not
`contract.dotted.dotted_role`. The case-insensitive substring query
matches either the short name or its collection-qualified identity.
`contract.dotted` therefore finds the collection, its roles, modules and
plugins; `contract.dotted.dotted_role` finds that role, and
`contract.dotted.dotted_plugin` finds that plugin. Other Workspace symbol
families retain their existing name-based matching.

Role navigation tries configured standard collection paths first, then
metadata-defined Workspace roots for FQCN/declared-collection roles.
Open, unsaved metadata changes immediately change the metadata-defined
identity and the symbol container; no save or restart is required.

## Public module and plugin sources

There is one symbol per public source file, not per Python function, class
or exported filter/test. Sources must be in the recognized collection
root's own `plugins/<type>/` tree:

- Python `.py`: `modules`, `action`, `become`, `cache`,
  `callback`, `cliconf`, `connection`, `filter`, `httpapi`,
  `inventory`, `lookup`, `netconf`, `shell`, `strategy`,
  `terminal`, `test`, `vars`.
- PowerShell `.ps1`: `modules` only.

Names drop the source extension; nested plugin-relative directories use
dots, e.g. `plugins/modules/network/nested_member.py` is
`network.nested_member`. Searching its full collection-qualified name
works without changing the returned name or collection container.

Any plugin-relative component beginning `_` or `.` is private, including
`__init__.py` and descendants of `_internal/`. Helpers in
`module_utils/`, `doc_fragments/`, unknown plugin kinds, tests/docs,
non-source files and noncollection plugin trees are excluded. A folder's
standard `ansible_collections/ns/coll` spelling alone does not create
Workspace collection symbols: it needs metadata. Non-private nested files
within a supported plugin kind count as public sources; this intentionally
does not infer helper status from Python contents.

Python and PowerShell files never enter YAML task, role-reference or
variable extraction, including unsaved source text that resembles a YAML
documentation example. Source edits preserve their path-based symbol.
Unsaved metadata changes update their collection container. Installed
module files remain outside symbols even when open in the client.

Watch registration includes `**/plugins/**/*.{py,ps1}`. Creation,
deletion and save events update eligible sources; excluded venv/nested/
hidden/package paths stay excluded even when opened or watched. Without
watch support, the normal index refresh updates/removes known files; new
files require a save or restart as in ADR-0031.

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
| `Workspace modules` | expected 4 source symbols, got 0 | 1 test passed; all four metadata layouts |
| `Workspace plugins` | expected 4 plugin symbols, got 0 | 1 test passed; lookup/filter/inventory/callback sources |
| `private source` | expected 0, got private file and private descendant | 1 test passed; helpers/private/noncollection sources excluded |
| `nested and Windows` (split into separate tests before GREEN) | expected 1 PowerShell module symbol, got 0 | `Windows modules`: 1 test passed; existing `.ps1` target |
| `nested module sources` | expected 1 qualified-query result, got 0 | 1 test passed; dotted plugin-relative name |
| `opened or watched` | expected 0, got 4 venv/nested collection and source symbols | 1 test passed; discovery boundaries preserved |
| `collection role symbols prefer` | expected main `.yaml` task target, got earlier defaults file | 1 test passed; main task target preferred |

Regression checks: `make test` passed; `make e2e` passed
265 semantic cases with 0 failures. All 18 collection-member tests passed.
The expanded collection-member suite also covers
standard/arbitrary/root role targets, short roles in declared collections,
both metadata extensions, an available Installed role and opened Installed
module excluded from symbols, an unsaved metadata rename affecting members,
YAML-looking source edits not leaking task/variable facts, qualified plugin
queries, and source watcher deletion/recreation without disk mutation.

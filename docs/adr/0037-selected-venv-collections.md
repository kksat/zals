# ADR-0037: Search collections in the selected virtual environment root

- **Status:** Accepted
- **Date:** 2026-10-02
- **Extends:** [ADR-0032](0032-workspace-wide-navigation.md)

## Context

A collection may be installed directly into a virtual environment as
`<venv>/ansible_collections/<namespace>/<collection>`, not in `site-packages`.
Searching only `site-packages` makes Collection definition and hover miss that
installation. Manually adding the environment root to `ANSIBLE_COLLECTIONS_PATH`
restores navigation, confirming the missing search-path input.

## Decision

Preserve ADR-0032's effective per-file path order: adjacent `collections/`,
configured paths, selected virtual environment, then Workspace collection paths.
The selected environment contributes its root when it contains
`ansible_collections/`, followed by `Lib/site-packages` and every
`lib/python*/site-packages` that contains `ansible_collections/`. POSIX layouts
are ordered lexically; duplicate paths are removed without changing precedence.
A missing layout does not prevent searching the others.

Relative environment paths resolve against the owning Workspace; absolute paths
are used directly. `--venv` overrides `ansible.python.venvPath`, and an empty
selection disables environment lookup. Never infer an environment from
`VIRTUAL_ENV`, scan sibling environments, or classify their collections as
Workspace collections (ADRs [0031](0031-workspace-index.md) and
[0035](0035-isolated-navigation-fixture.md)).

## Direct collection-directory inputs

Accept a configured path ending in the literal directory component
`ansible_collections` as an alias for its parent collections root. Normalize at
the common effective collection-path boundary, before ordered deduplication,
not independently in navigation providers. The module filesystem scanner also
uses the same normalization when scanning raw startup dump paths. Collection,
Role, module docs, and module discovery therefore append `ansible_collections`
exactly once. Accept a trailing directory separator as well.

This follows the primary implementation in Ansible core 2.17.1:
[`_AnsibleCollectionFinder.__init__`, lines 257–266](https://github.com/ansible/ansible/blob/v2.17.1/lib/ansible/utils/collection_loader/_collection_finder.py#L257-L266).
The installed source was read directly during implementation: it checks
`os.path.basename(p) == 'ansible_collections'`, replaces such an entry with
`os.path.dirname(p)`, and appends only the first occurrence of each root to
`good_paths`. zals must not append another `ansible_collections` to the already
qualified directory and accidentally fall back to a different Workspace
Collection.

A direct entry and its parent share the first entry's precedence; normalization
does not sort paths or realpath-resolve symlinks. Config-relative entries still
resolve against their `ansible.cfg` directory. Relative environment-variable
and dump entries keep their **server cwd** meaning, and the effective boundary
makes them absolute so Collection/Role locations are valid file URIs and agree
with module subprocess paths. A bare `ansible_collections` entry denotes the
server cwd's collection directory. Explicitly configured paths can name a venv's
collection directory even when automatic venv selection is disabled.

## Module services and cache isolation

Module definition, hover, option lookup, completion, completion resolve, and
semantic tokens consume the same effective per-file collection paths as
Collection and Role navigation. Module discovery scans those paths directly,
even when `ansible --version` is unavailable, rather than only the startup
`ansible-config dump` paths.

Each module library is keyed by the **ordered** effective paths alone. It owns
an immutable copy of the child environment. `ansible-doc` is the executable
found on `PATH` and runs in the server's working directory; zals supplies no
per-file working directory or `ansible.cfg`. The effective paths are already
absolute (relative environment/dump entries keep their server-cwd meaning), and
they reach the child only through the environment. Every `ansible-doc` call
and module-discovery version call uses that snapshot via the execution
interface; no process-global `setenv`, activation script, or environment
mutation is involved. Set `ANSIBLE_COLLECTIONS_PATH` to the effective path
list, remove its legacy plural alias, and disable Python `sys.path` collection
scanning so unrelated interpreter installations cannot bypass the selection.
Completion items retain the source URI in LSP `data` so resolve can recover the
current per-file context.

These contextual libraries cache catalogs and fetched docs **in memory only**,
and are not loaded from or written to the existing process-wide version-only
disk cache. That cache remains for the startup library/prefetch
([ADR-0008](0008-hybrid-docs-loading.md)); it cannot safely supply contextual
filenames or documentation. Different ordered path lists must not share module
entries; files with identical lists share one library, even across Workspaces,
because the child resolves them identically. Changed selections/configured paths select a
new context; unchanged contexts reuse their fetched docs. Contexts and their
owned snapshots remain alive until server teardown; background prefetch only
touches the separate startup library, and workers are joined before either is
destroyed ([ADR-0011](0011-threading-topology.md)).

This prioritizes isolation over persistent caching. A future contextual disk
cache must include environment/configuration identity and installation
invalidation; reusing the version-only cache is not a valid shortcut.

## Verification

A separate black-box stdio LSP suite, `test/selected_venv_e2e.zig`, uses checked-in
ordinary fixtures under `test/fixtures/selected-venv/`. Expected locations are
written explicitly and positions come from unique test-side anchors, following
[ADR-0033](0033-semantic-navigation-e2e-oracles.md). The real reproducer remains
read-only and is not a fixture or test dependency.

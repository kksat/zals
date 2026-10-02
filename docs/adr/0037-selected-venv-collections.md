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

## Verification

A separate black-box stdio LSP suite, `test/selected_venv_e2e.zig`, uses checked-in
ordinary fixtures under `test/fixtures/selected-venv/`. Expected locations are
written explicitly and positions come from unique test-side anchors, following
[ADR-0033](0033-semantic-navigation-e2e-oracles.md). The real reproducer remains
read-only and is not a fixture or test dependency.

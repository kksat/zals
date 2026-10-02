# ADR-0042: Passed role-field navigation

- **Status:** Accepted
- **Date:** 2026-10-02
- **Extends:** [ADR-0039](0039-role-parameter-navigation.md), [ADR-0041](0041-field-name-navigation.md)

A concrete nested key inside a passed role parameter has a callee contract,
just like the root parameter. Definition and hover prefer the resolved role's
selected argument-spec entry point, following the root option and every nested
`options:` key. Implementation matches the complete root-and-key path among
concrete bindings in the callee's conventional role/file set. Lists add no path
component. This avoids selecting a different root's coincidentally equal leaf,
another entry point, the caller's own value, or an unrelated role.

References remain Workspace-wide **leaf-name** matching from every read and
key, including passed keys and schema keys. The user chose this symmetry over
callee-scoped references; the path is a contract/implementation selector, not a
runtime object identity or a reference-search boundary. Root variables remain
a separate name group.

Map/key-value include/import tasks and `roles:` entries (direct or under `vars:`)
share role resolution and collection context. `tasks_from` normalization, YAML
metadata variants, absolute escaped URIs, and unsaved buffers follow the existing
root-parameter rules. Schema-only fields and unresolved callees have no concrete
implementation. If no selected full-path option exists, definition and hover
fall back to ordinary field navigation, explicitly labeled as a Variable field
rather than asserting a callee contract. Implementation can still return a
matching concrete callee path without a schema.

Workspace callee implementations reuse persistent `field_defs` and `var_loads`
facts, replaced by facts extracted from open buffers. The callee file set is
its conventional sources plus one level of their vars loads, with load-site
precedence retained. Load-looking keys inside data are not load directives.
Explicit vars loads remain eligible regardless of their filename extension
(including JSON); this does not broaden general Workspace discovery.
Unindexed dependencies use a bounded source fallback;
non-Workspace callees retain filesystem discovery. Requests do not re-enumerate
or reparse an indexed role's disk sources.

The static stdio fixture checks exact positive contracts and negative collisions,
ordered concrete targets, and both independently authored reference answers from
all 27 sites of a small group. A separate buffer-edit scenario covers moved,
quoted schema keys, changed descriptions and concrete values, and complete
references with stale disk sites excluded. A second buffer scenario changes a
callee's `include_vars` target and its loaded dictionary, checking the exact
load/vars/default implementation order. These are preservation oracles for the
index-reuse refactor, not artificially failing tests. A JSON dependency scenario
locks down extension-independent loads and original-source buffer ranges;
load-looking data controls must not widen callee scope. Post-review evidence is
[recorded separately](../../test/field_navigation_review_e2e.md).
No playbook execution, loop tracing,
YAML alias expansion, or fixture mutation is involved.

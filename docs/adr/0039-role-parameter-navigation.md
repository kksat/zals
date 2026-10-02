# ADR-0039: Role parameter navigation

- **Status:** Accepted
- **Date:** 2026-10-02
- **Extended by:** [ADR-0042](0042-passed-role-field-navigation.md) (nested fields)
- **Extends:** [ADR-0032](0032-workspace-wide-navigation.md) and
  [ADR-0036](0036-variable-navigation-from-bindings.md)

A key passed to a role is both a variable binding and a role API reference.
Definition at that key prefers the called role's matching argument-spec option,
using the same role resolution and entry point as parameter hover: `main`, or
the extensionless basename of `tasks_from`. This applies to `roles:` map
parameters, their nested `vars:`, and `vars:` on map or key-value
`include_role`/`import_role` tasks. Task/block/play collection context applies
identically to definition, implementation, and hover.

Implementation at a passed key returns the concrete same-named bindings in the
resolved callee's role/file set, ranked by variable precedence. It excludes
argument-spec declarations, the caller's own parameter key, and unrelated
roles' same-named variables. A schema-only or unresolved callee has no
implementation. This answers "where is this role input implemented?" rather
than opening the role's main tasks or immediately navigating back to the
calling key. The implementation file set remains an approximation: all
conventional role files and one level of their vars-file loads, not an
execution simulation of one entry point.

When no matching option exists, definition and hover retain ordinary variable
navigation as their fallback. From a root read, defaults/vars binding, or an
argument-spec option, definition still returns ADR-0036's ranked Workspace
bindings. The caller's API context is what makes a passed key more specific;
we do not infer that context for every same-named read in another file.

Find-references does **not** change identity rules. All root-variable reads
and bindings of the same name in one Workspace have the same complete result,
including parameters passed to distinct or unresolved roles and options in
different entry points. Both `includeDeclaration` modes have explicitly
written E2E oracles, exercised from every member of a sixteen-site group.

Option documentation and key ranges prefer open, unsaved metadata, including
when it is not indexed as a Workspace file. The static navigation fixture
covers include/import syntax, selected entry points, collection collisions,
YAML metadata fallback, and schema-only negatives. A separate stdio scenario
moves an option in an unsaved buffer and verifies the returned range and hover.

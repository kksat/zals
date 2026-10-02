# ADR-0041: Field-name navigation

- **Status:** Accepted
- **Date:** 2026-10-02
- **Supersedes:** the attribute exclusion in [ADR-0024](0024-variable-go-to-definition.md) and [ADR-0025](0025-variable-references.md)

Fields are navigation names distinct from root variables. Ordinary field
navigation matches the leaf name throughout the owning Workspace, irrespective
of the receiver, root binding, or loop source. This deliberately extends the
existing variable-name rule instead of attempting runtime object identity or
loop-alias tracing: `item.region` and `backup.region` share a field group;
the root variable `region` does not join it.

Concrete field definitions come from parsed mapping keys below recognized
variable-value bindings, including dictionaries inside lists. List elements do
not add a path component. Nested argument-spec `options:` declare schema fields;
properties such as `type`, `description`, and `default` are not themselves field
definitions. Package and execution-environment metadata maps are not variable
values. A field retains its root-and-key path even though ordinary matching uses
only its leaf name.

References have complete, identical answers from each recognized field read or
key in a Workspace. Declarations off returns reads; declarations on also returns
concrete keys and schema options. This Workspace-wide rule also applies to fields
passed to roles. Definition ranks reachable field keys, then other Workspace
keys; implementation excludes schema declarations. Hover shows the same parsed
values and option descriptions. Unsaved buffers override disk just as for root
variables. Without a session Workspace, the existing role/playbook file set
remains the search boundary.

Name matching intentionally merges unrelated objects. It does not execute
playbooks, expand YAML aliases, infer loop aliases, or trace object identity.
The written stdio oracles exercise all actions from reads, list keys, quoted
mapping keys, and nested schema options, plus schema-only, metadata, unbound,
and same-named-root controls. See the [scope guide](../variable-navigation.md).

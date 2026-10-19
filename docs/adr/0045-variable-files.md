# ADR-0045: Variable files

- **Status:** Accepted
- **Date:** 2026-10-15
- **Supersedes:** the "every map-rooted file is a vars file" heuristic behind
  sites 6 and 8 of [ADR-0024](0024-variable-go-to-definition.md), and the
  separate field-only metadata exclusion in
  [ADR-0041](0041-field-name-navigation.md)

## Context

ADR-0024 makes the top-level keys of `vars_files` and `include_vars` targets
Variable definitions. The implementation approximated "a target" as "any
map-rooted YAML file outside a Role's conventional directories". A Workspace
also holds many map-rooted files that Ansible never loads as variables:
`galaxy.yml`, `requirements.yml`, `execution-environment.yml`, collection
`meta/runtime.yml`, `molecule.yml`, `docker-compose.yml`, `mkdocs.yml`,
changelogs, and YAML inventories (whose top-level keys are groups). Their keys
(`version`, `name`, `dependencies`, `platforms`, `all`, ...) became root
bindings. References, definition, and hover for real variables with those
names listed them. A rename would rewrite them and corrupt the files. Field
collection already skipped a fixed metadata list, so root and field navigation
disagreed.

## Decision

A **Variable file** is one whose top-level keys Ansible binds as variables. We
use an allowlist, not a denylist of known non-variable files. A map-rooted
document binds its top-level keys only when its file is one of these:

1. A Role's `defaults/` or `vars/` entry. These keep Role precedence (ADR-0024).
2. Below a `group_vars/`, `host_vars/`, or `vars/` directory, outside a Role's
   conventional directories. Ansible reads the first two implicitly. `vars/`
   is the conventional target of loads, including dynamic ones that cannot be
   resolved statically (`include_vars: "{{ ansible_os_family }}.yml"`).
3. The resolved target of a static `vars_files` or `include_vars` load
   (without a `name` prefix) anywhere in the owning Workspace. Without a
   session Workspace, this means a load in the request's file set.

Any other map-rooted file binds nothing. Plays and tasks in seq-rooted files
keep their binding sites. Field definitions are collected below the root
bindings this rule admits, so root and field navigation share one rule.

The location test uses only the file's path (and its Role root), so the
Workspace index and per-request scans classify a file the same way. Rule 3
depends on other files. ADR-0031 builds index entries one file at a time, so
an entry records a `.general` file's map keys as **load-only bindings**. The
query layer admits them when the Workspace view, which already merges open
documents over the index, finds a load that targets the file. Callee
implementations (ADR-0039, ADR-0042) admit them for the loads they follow. A
cursor on a load-only key is a navigation subject only when such a load exists.

We rejected a denylist (for example the metadata names plus `molecule.yml`
and `docker-compose.yml`). It fails open: every new tool's config file would
corrupt again until someone listed it. We also rejected deciding rule 3 at
index time: an entry's facts would then depend on other files, and every edit
to a load would have to re-index its target.

## Consequences

- Package, collection, execution-environment, Molecule, Compose, docs, and
  changelog metadata, and inventory structure, are never Variable definitions.
  References, definition, implementation, and hover skip them, so a rename
  built on references cannot rewrite them.
- A map-rooted file outside rule 1 and 2 directories that is loaded only
  through a dynamic path, `include_vars: dir:`, extra vars (`-e @file`), or a
  loader outside the Workspace no longer contributes bindings. ADR-0024 and
  the scope guide already list these loads as unmodeled.
- Without a session Workspace, a cursor in such a file finds no binding. The
  enclosing playbook's file set still finds its loaded keys.
- A directory component named `vars`, `group_vars`, or `host_vars` above the
  Workspace root also matches. A Workspace located inside such a directory
  keeps the old, permissive behaviour.
- Each Workspace query collects the set of load targets from every file's
  stored loads. That costs one pass over facts that are already in memory.

# ADR-0032: Workspace-wide navigation

- **Status:** Accepted
- **Date:** 2026-09-28
- **Supersedes:** the Role/Playbook search boundary of
  [ADR-0024](0024-variable-go-to-definition.md) and
  [ADR-0025](0025-variable-references.md); the resolution order of
  [ADR-0029](0029-role-navigation.md); the `workspace/symbol` exclusion of
  [ADR-0027](0027-document-symbols.md)
- **Superseded by:** in part by
  [ADR-0034](0034-resolved-role-reference-identity.md) (Role find-references matching)
- **Extended by:** [ADR-0036](0036-variable-navigation-from-bindings.md)
  (binding entry points and concrete implementations),
  [ADR-0037](0037-selected-venv-collections.md) (selected installations and
  contextual module services), [ADR-0038](0038-workspace-collection-members.md)
  (metadata-defined collection roots and public source symbols), and
  [ADR-0039](0039-role-parameter-navigation.md) (callee parameter navigation),
  [ADR-0041](0041-field-name-navigation.md) (separate field-name navigation).
  [ADR-0040](0040-navigation-file-uris.md) defines file-URI serialization.

## Context

Variable find-references and go-to-definition stopped at the enclosing role or
playbook. Role navigation resolved names against a fixed list and could not
find a role elsewhere in the project, a Galaxy role (`namespace.role`), or a
role in a collection installed into a virtual environment. Nothing listed the
places that name a role, a collection, or a task file, and there was no
project-wide symbol search. The glossary terms used here are defined in
`CONTEXT.md`.

## Decision

All searches run over the **Workspace that owns the file**
([ADR-0014](0014-multi-root-workspace.md)), read from the Workspace index
([ADR-0031](0031-workspace-index.md)). A file with no session Workspace keeps
the old role/playbook file set.

### Configuration inputs

- **`ansible.cfg`.** The nearest `ansible.cfg` at or above the referencing file,
  up to the Workspace root, supplies `roles_path` and `collections_path`
  (`collections_paths`). Relative entries resolve against that file's
  directory; `~` expands to `$HOME`. `ANSIBLE_CONFIG` names the file instead
  when set.
- **Environment.** `ANSIBLE_ROLES_PATH` and `ANSIBLE_COLLECTIONS_PATH`
  (`ANSIBLE_COLLECTIONS_PATHS`) override the file, as in Ansible.
- **Defaults.** When neither sets a value, the cached `ansible-config dump`
  values apply, then Ansible's defaults (`~/.ansible/roles`,
  `/usr/share/ansible/roles`, `/etc/ansible/roles`).
- **Virtual environment.** `ansible.python.venvPath` (default `.venv`) or the
  `--venv <path>` flag (which wins) selects exactly one virtual environment,
  relative to the Workspace root. Its `lib/python*/site-packages` (or
  `Lib/site-packages`) is a collections path when it contains
  `ansible_collections/`. Other virtual environments are ignored.
- **Collections paths**, in order: the playbook-adjacent `collections/`
  directory, the configured paths, the selected virtual environment, then every
  directory in the Workspace that contains `ansible_collections/`.

### Role resolution

A name with two or more dots is an FQCN; a name with one dot is a Galaxy role
and resolves as a short name. The order copies `ansible-playbook`:

1. FQCN → `<collections path>/ansible_collections/<ns>/<coll>/roles/<role>`.
2. Declared `collections:` (task, block, play, role metadata) → each
   collection's `roles/<name>`.
3. Sibling role: `<role dir>/../<name>` when the reference is inside a role.
4. `<dir>/roles/<name>`, walking up from the referencing file to the Workspace
   root.
5. Each `roles_path` entry.
6. Ansible's default role paths.
7. **Editor fallback:** any other `roles/<name>` in the Workspace.

Definition, implementation, and hover use the first match of steps 1–6. Only
when none matches do they use step 7, returning every match there.

### Features

- **Role references** include `requirements.yml` `roles:` entries (`name:`,
  `src:`, or a bare string, unless the value is a git or URL source).
  Find-references returns every Role reference in the Workspace with the same
  name (superseded by [ADR-0034](0034-resolved-role-reference-identity.md)).
  Hover shows the role's `README.md`, else its unrendered argument specs,
  else its unrendered `meta/main.yml`, else the name and resolved path. There is
  no `textDocument/declaration`; clients fall back to definition.
- **Role parameters** (keys of a `roles:` entry, keys under `vars:` of an
  `include_role`/`import_role` task) hover with the unrendered YAML of
  `argument_specs.<entry point>.options.<param>`. The entry point is the
  `tasks_from` basename, default `main`. Without a matching option the hover
  falls back to the variable hover.
- **Variables.** Find-references returns every occurrence of the name in the
  Workspace. Go-to-definition returns the Reachable definitions ranked by
  ADR-0024 precedence, then every other definition in the Workspace. Hover
  shows the active (highest-ranked reachable) definition with its unrendered
  value and location, the shadowed reachable ones, and the others under
  "elsewhere in the Workspace". A task file outside a role is reachable from
  the playbooks that include it.
- **Task and vars files.** Go-to-definition on an `include_tasks`,
  `import_tasks`, `vars_files`, or `include_vars` path opens the target.
  Relative paths resolve against the referencing file's directory, then the
  enclosing role's `tasks/` (task files) or `vars/` (vars files) directory,
  then the Workspace root. Find-references returns every site that names the
  same resolved file.
- **Collections.** Collection references are the six sites in `CONTEXT.md`.
  Go-to-definition opens `galaxy.yml`, else `MANIFEST.json` (installed
  collections ship that instead), else `README.md`. Hover shows `README.md`,
  else the unrendered `galaxy.yml`, else `MANIFEST.json`. Completion at
  `collections:`, requirements, and `galaxy.yml` dependency sites offers every
  Workspace and Installed collection. Find-references returns every Collection
  reference in the Workspace.
- **`workspace/symbol`** returns a flat list of Workspace symbols filtered by
  a case-insensitive substring query. `containerName` is the nearest parent by
  file location: collection FQCN for roles and playbooks inside a collection,
  role name for task files inside a role, playbook path for plays, and play name
  or task-file path for tasks and handlers. Installed collections and variables
  are excluded.

## Consequences

- Navigation matches what `ansible-playbook` would run whenever the
  configuration is complete, and still finds roles when it is not.
- Collection references remain matched by name. Role references were also
  name-matched, so two different Roles with the same name were listed together
  (superseded by ADR-0034).
- Nearest-`ansible.cfg` resolution is more generous than Ansible, which reads
  only the working directory's file.
- Collections in other virtual environments stay invisible until selected.

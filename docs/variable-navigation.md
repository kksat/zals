# Variable navigation

Variable navigation uses the Workspace that owns the source file. Open,
unsaved documents override indexed files. Wait for `ansible/workspaceIndexReady`
when testing a complete Workspace result; requests during the initial scan may
return partial results.

## Root variables

The cursor may be on a read (`{{ app_port }}`, `when: app_port > 0`) **or a
binding**: a defaults/vars key, an argument-spec option, a role parameter,
`set_fact` key, `register` value, or another recognized definition site.
Argument specs in `meta/argument_specs.yml`, `.yaml`, and `meta/main.yml`,
`.yaml` are included. Standalone Role repositories are recognized by
`meta/main.yml` or `meta/main.yaml`, without needing a `roles/<name>/` path.
Directory-style defaults and vars (for example `defaults/main/main.yml` and
`vars/main/settings.yaml`) retain Role defaults/vars precedence, including
structured field bindings. See the [Neovim setup](neovim.md#standalone-role-repositories)
for attaching zals to these buffers.

### Variable files

Top-level keys of a YAML map bind variables only in a **Variable file**:

- a Role's `defaults/` or `vars/` file;
- a file below a `group_vars/`, `host_vars/`, or `vars/` directory (outside a
  Role's own `tasks/`, `templates/`, and other conventional directories);
- the target of a static `vars_files` or `include_vars` load (without a `name`
  prefix) anywhere in the owning Workspace, wherever the target lives.

Other map-rooted YAML binds nothing: `galaxy.yml`, `requirements.yml`,
`execution-environment.yml`, collection `meta/runtime.yml`, `molecule.yml`,
`docker-compose.yml`, `mkdocs.yml`, changelogs, and YAML inventories (whose
top-level keys are groups). A Role variable named `version` therefore never
lists `version:` in `galaxy.yml`. A loaded file outside those directories binds
only while a load targets it, so its keys are navigation entry points only in
a Workspace that loads it. Dynamic load paths, `include_vars: dir:`, and
`-e @file` extra vars are not resolved: put such files under `vars/` to
navigate them. See [ADR-0045](adr/0045-variable-files.md).

| Request | Answer |
| --- | --- |
| Find references, declarations off | Every read of the same root name in the owning Workspace |
| Find references, declarations on | The same reads plus every recognized binding of that name |
| Go to definition | Reachable bindings in precedence order, then bindings elsewhere in the Workspace |
| Go to implementation | The same ordered bindings, excluding schema-only argument-spec declarations |
| Hover | Active and shadowed reachable bindings, then bindings elsewhere in the Workspace; role parameter keys prefer the called role's option documentation |

Go-to-definition accepts binding keys, including keys in defaults, vars, and
argument specs. The binding under the cursor remains in the result. When it is
the only binding, returning its own location is intentional.

Implementation navigates concrete value bindings, not role task files. From an
argument-spec option it can open its default, vars value, or invocation value;
a schema-only option has no implementation. From a Jinja-valued role name it
navigates the variable binding, not a guessed role.

## Ordinary fields

Fields such as `item.resourcegroup_name` form a separate name group from root
variables. Matching uses the **leaf field name** across receivers and structured
bindings, not loop source or runtime object identity. `item.region` and
`backup.region` therefore share a group; a root variable named `region` does not.

| Request from a field read or key | Answer |
| --- | --- |
| Find references, declarations off | Every field read of the same leaf name in the owning Workspace |
| Find references, declarations on | Those reads plus parsed concrete mapping keys and nested argument-spec options |
| Go to definition | Reachable field keys in precedence order, then same-named keys elsewhere in the Workspace |
| Go to implementation | The same ordered concrete keys, excluding schema-only argument-spec options |
| Hover | Active and shadowed values, plus nested option descriptions and other Workspace candidates |

Concrete keys are collected below recognized variable bindings: dictionaries,
including those inside lists, in defaults, vars, and other supported binding
sites. Quoted keys have unquoted navigation ranges and show their parsed values.
A schema-only field has a definition and description, but no implementation.
Dot access and static single/double-quoted subscripts (`record['region']`) share
the same group, with quote/bracket-free ranges. Template statements and bare
expressions are included. Strings/comments, filter/test plugin names (including
qualified names), called methods, and numeric/computed subscripts are not field
reads; a dynamic subscript such as `record[key]` reads the root variable `key`.
Keyword-spelled data members such as `record.filter` remain real fields.
YAML quoting is normalized before scanning: both
`"{{ record[\"region\"] }}"` and `'{{ record[''region''] }}'` identify the
`region` field. Reported ranges remain in the original document, including
escaped spellings and UTF-16 positions. Jinja raw-block contents are literal,
and the left field in `{% set ns.region = other.region %}` is a write, not a
field reference; the RHS remains a read.
Static key literals retain their raw contents: Jinja escape-decoded aliases
(such as `record['\\u0072egion']`) are not normalized into the `region` group.
A field without a declaration still finds its reads; its hover reports that no
definition was found rather than showing a same-named root variable's value.

Argument-spec `options:` maps explicitly declare fields. Structural properties
like `type`, `description`, and `default` are not themselves fields. Keys in
files that are not [Variable files](#variable-files), such as package,
requirements, or execution-environment metadata, are not fields. A data key named
`vars`, `roles`, or `set_fact` inside a structured value does not introduce a
second binding scope. Likewise, data keys named `include_vars` or `vars_files`
do not introduce file loads. Module argument data is not a variable binding
either; only actual play/task/block containers and recognized binding maps are
followed.
YAML aliases, object identity, and loop aliases are not expanded or traced. The same Workspace,
open-buffer, and no-session boundaries as root variables apply. See
[ADR-0041](adr/0041-field-name-navigation.md).

## Passed role parameters

Keys passed through a `roles:` map entry (directly or under its `vars:`) and
through `vars:` on `include_role`/`import_role` have a called-role context:

| Request from a passed key | Answer |
| --- | --- |
| Go to definition | The matching option of the resolved role's selected argument-spec entry point; ordinary variable navigation if no matching option exists |
| Go to implementation | Ranked concrete bindings in the resolved callee's role/file set, excluding schemas, caller keys, and unrelated roles |
| Hover | The matching option documentation, falling back to ordinary variable hover |
| Find references | Still the complete Workspace-wide root-name result, with or without bindings according to `includeDeclaration` |

`tasks_from: setup.yml` and `setup.yaml` select the `setup` argument-spec entry
point; absent `tasks_from` selects `main`. Map and key-value role includes use
the same rules. Task, block, and play `collections:` declarations affect all
three role-context requests. Metadata and defaults/vars files can use either
YAML extension. Unsaved option documentation and shifted key positions win
over their disk copy.

A passed schema-only input or unresolved role has no callee implementation.
Implementation searches conventional role files and one level of their
vars-file loads; it does not simulate only the selected task entry point.
From the option itself or a normal read, ordinary root-variable navigation
still applies, so definition results can be broader than from a passed key.
See [ADR-0039](adr/0039-role-parameter-navigation.md).

### Nested fields passed to a role

A nested mapping key under a passed parameter also uses that callee context.
For `input_config.endpoint.region_name`, definition and hover follow the selected
entry point's `options.input_config.options.endpoint.options.region_name`.
Implementation returns only concrete callee keys with that **complete path**;
it excludes a same-named key under `alternate_config`, caller values, unrelated
roles, and schema declarations. Lists contain values, not path components, so
keys inside `input_configs: [{endpoint: {region_name: ...}}]` match the analogous
list/dict schema. Intermediate dictionary keys are also navigation entry points.

References deliberately remain the complete Workspace-wide **leaf-name** group
from every origin, including called fields, other roles, other roots, and other
entry points. The callee-specific exception is only for contract/implementation
selection; it does not infer object identity or trace loop aliases. An unresolved
callee or schema-only field has no callee implementation. If no selected
full-path option exists, definition/hover retain ordinary name-based fallback;
a generic fallback hover is labeled **Variable field**, not **Role parameter
field**. Metadata, defaults, and vars overlays supersede disk ranges and values.
Indexed callee implementations reuse stored full-path facts and vars-load
provenance; changed task/load/value buffers override them without reparsing the
callee's disk file set.
See [ADR-0042](adr/0042-passed-role-field-navigation.md).

### What is the same from every site?

Given the same indexed/open-document state, **find-references has an identical
complete answer from every read and binding of a root name in one Workspace**.
Fields have the same symmetry within their separate leaf-name group, including
fields passed through role invocations and include/import tasks.
`includeDeclaration` only controls which kinds of occurrences are returned; it
does not change which name or Workspace is searched.

This is name matching, not runtime variable identity. For example, both a web
role's `port` and a database role's `port` are returned. A search for `app_port`
does not include `port`, filter/test names, quoted literal text, or a module
option named `app_port` that is not a variable binding.

### What can differ by source?

Definition ordering and hover depend on reachability. A file in a role reaches
its own role, files that invoke that resolved role, and one level of the vars
files they load. A task file outside a role reaches its direct includers and
one level of their vars-file loads. Remaining Workspace definitions are still
listed, but are not ranked as active candidates.

These are static, file-level approximations, not Ansible execution: task/block
lexical lifetime, include order, inventory, extra-vars, and dynamically computed
paths are not fully modeled. No-session requests retain the smaller enclosing
role/playbook file set, so the same name in different such file sets need not
produce the same answer. Without a session Workspace, a key in a loaded file
outside `vars/`, `group_vars/`, and `host_vars/` is a binding only from the
playbook whose file set loads it. Nested Workspaces are separate until opened,
and even then each source searches only its owning Workspace.

### Without a session Workspace

A file that no session Workspace owns is searched with the same rules as a
Workspace, over a smaller file set:

- **Role scope.** A file inside one of a Role's conventional directories
  (`tasks/`, `handlers/`, `defaults/`, `vars/`, `meta/`, `templates/`, `files/`,
  `library/`) belongs to that Role, the directory below `roles/` or holding
  `meta/main.yml`/`.yaml`; this is the rule the Workspace index uses to
  classify files. Its file set is the Role's `defaults/`, `vars/`, `tasks/`,
  `handlers/`, `templates/` and `meta/` files.
- **Playbook scope.** Any other file, including a playbook elsewhere in a Role
  directory such as `molecule/` or `tests/`, is its own file set.
- Either set adds one level of the `vars_files`/`include_vars` targets its
  files load, and only those targets bind their load-only keys. Without a
  Workspace, load paths resolve from the loading file and its Role's `vars/`
  directory, with no Workspace-root fallback.
- Every definition in the set is reachable. Definitions are ordered by
  precedence, then by file path and position, as in a Workspace. Root-name
  references are ordered by file path and position; field references list
  each file's keys, then its reads, with the Role's files in path order
  followed by the loaded files.

A called Role uses the same Role scope for implementations. When a session
Workspace owns the Role but has not indexed it yet, its files come from disk
and their loads resolve against that Workspace's root, as if indexed.

References to roles have a different rule: their possible resolved role
directories must overlap (ADR-0034). An ambiguous fallback invocation can find
sites for several roles; a uniquely resolved site can have a narrower answer.
Do not assume root-variable name matching applies to roles.

See [ADR-0036](adr/0036-variable-navigation-from-bindings.md),
[ADR-0032](adr/0032-workspace-wide-navigation.md), and
[ADR-0024](adr/0024-variable-go-to-definition.md) for definition sites and
precedence.

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
`.yaml` are included.

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
Static key literals retain their raw contents: Jinja escape-decoded aliases
(such as `record['\\u0072egion']`) are not normalized into the `region` group.
A field without a declaration still finds its reads; its hover reports that no
definition was found rather than showing a same-named root variable's value.

Argument-spec `options:` maps explicitly declare fields. Structural properties
like `type`, `description`, and `default` are not themselves fields, nor are
package, requirements, or execution-environment metadata keys. YAML aliases,
object identity, and loop aliases are not expanded or traced. The same Workspace,
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
produce the same answer. Nested Workspaces are separate until opened, and even
then each source searches only its owning Workspace.

References to roles have a different rule: their possible resolved role
directories must overlap (ADR-0034). An ambiguous fallback invocation can find
sites for several roles; a uniquely resolved site can have a narrower answer.
Do not assume root-variable name matching applies to roles.

See [ADR-0036](adr/0036-variable-navigation-from-bindings.md),
[ADR-0032](adr/0032-workspace-wide-navigation.md), and
[ADR-0024](adr/0024-variable-go-to-definition.md) for definition sites and
precedence.

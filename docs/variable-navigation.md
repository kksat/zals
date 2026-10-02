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

### What is the same from every site?

Given the same indexed/open-document state, **find-references has an identical
complete answer from every read and binding of a root name in one Workspace**.
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

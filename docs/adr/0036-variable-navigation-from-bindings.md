# ADR-0036: Variable navigation from bindings

- **Status:** Accepted
- **Date:** 2026-10-02
- **Supersedes:** the reference-only definition trigger in [ADR-0024](0024-variable-go-to-definition.md)

Variable declaration keys are navigation entry points, not just destinations.
Go-to-definition accepts the same variable occurrences as find-references and
hover: reads, defaults and vars keys, argument-spec options, and the other
binding sites described in ADR-0024. Its answer remains the reachable bindings
ranked by precedence, followed by other same-named bindings in the owning
Workspace (ADR-0032). The binding under the cursor remains a candidate; a
variable with only one binding can therefore navigate to itself.

Go-to-implementation accepts the same entry points and ranking, but omits
argument-spec declarations: a schema describes an input, it does not implement
a value. Defaults, vars, invocation values, `set_fact`, `register`, and the
other concrete bindings remain candidates. An option with no concrete binding
has a definition but no implementation. Dynamic role-name expressions navigate
their variable's bindings rather than pretending to resolve a static role.

Find-references retains ADR-0032's Workspace-wide **name-based** rule. From any
read or binding of the same root variable, with the same `includeDeclaration`
flag and the same document state, the complete result is identical. This
includes options in both `meta/argument_specs.{yml,yaml}` and
`meta/main.{yml,yaml}`. Changing the cursor does not change the reference search
scope or hide declarations. With `includeDeclaration: false`, only reads are
returned; with `true`, every recognized binding is also returned.

This does not turn references into runtime binding identity. Two unrelated
roles using `port` share a references result inside one Workspace, while their
reachable definitions and active hovers can differ. Separate Workspaces do not
share a result. Without a session Workspace, the existing role/playbook file
set applies; different file sets need not have the same result. Partial startup
indexing and unsaved edits can also change a result between requests.

E2E cases enumerate complete answers independently of server output, including
both declaration modes from every member of the small `app_port` group and
binding-key definitions. This closes a trigger gap without pretending to
resolve Ansible's inventory, extra-vars, execution order, or full lexical scope.

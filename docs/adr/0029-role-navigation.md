# ADR-0029: Role go-to-definition and go-to-implementation

- **Status:** Accepted
- **Date:** 2026-09-20
- **Supersedes:** —
- **Superseded by:** in part by ADR-0032 (resolution order)

## Context

Go-to-definition resolves module names to module source (ADR-0009) and variable
references to their definitions (ADR-0024). Roles are referenced in several
places — a play's `roles:` list, `include_role`/`import_role` tasks, and a
role's `meta/main.yml` `dependencies:` — but none of them are navigable. Users
expect to jump from a role reference to the role's argument specs or metadata,
and to jump to the role's implementation (its main task file).

Upstream has no role navigation: its definition provider handles only task
parameters (modules), and it never reads `DEFAULT_ROLES_PATH`. This is a
post-parity extension, so there is no upstream behavior to match.

## Decision

**Reference surface.** A role reference is a role-name scalar in one of:

| Form | Example |
| --- | --- |
| `roles:` string entry | `roles: [demo]` |
| `roles:` map entry | `- role: demo` |
| `include_role` / `import_role` `name:` (map) | `include_role: { name: demo }` |
| `include_role` / `import_role` `name=` (k=v) | `include_role: name=demo` |
| `meta/main.yml` `dependencies:` string entry | `dependencies: [other]` |
| `meta/main.yml` `dependencies:` `role:` map entry | `- role: other` |

The cursor must be on the role-name **value**, not the `role:`/`name:` key.
`tasks_from`/`vars_from`/`defaults_from` values are file names, not role
references. A Jinja-valued name (`"{{ my_role }}"`) is not a role reference;
the variable provider handles it.

**Resolution.** Role names resolve on demand (no startup pre-scan), in order:

1. **FQCN** (`ns.coll.role`) → `<collections_path>/ansible_collections/<ns>/<coll>/roles/<role>`.
2. **Short name**:
   a. `<dir>/roles/<name>` walking up from the referencing file's directory.
   b. Each `DEFAULT_ROLES_PATH` entry.
   c. `<workspaceRoot>/roles/<name>`.
   d. Each declared `collections:` entry → `<collections_path>/ansible_collections/<ns>/<coll>/roles/<name>`.

`DEFAULT_ROLES_PATH` and `COLLECTIONS_PATHS` come from a cached
`ansible-config dump` (shared with the module index). A leading `~/` is expanded
against `$HOME`. Matching is exact and case-sensitive.

**Targets.** Definition opens, in order: `meta/argument_specs.yml`,
`meta/main.yml`, `tasks/main.yml` (each also tried as `.yaml`), or nothing.
Implementation opens `tasks/main.yml` (or `.yaml`), or nothing. Both point at
line 0, character 0 (ADR-0009). `tasks_from` is ignored.

**LSP wiring.** `textDocument/implementation` is a new handler and
`implementationProvider` is advertised. Definition tries variables, then roles,
then modules. The role branch is position-gated and **stops the chain**: when
the cursor is on a role-name position but the role cannot be resolved, the
result is null rather than the module source. Both providers return a single
`Location`.

## Consequences

- Role navigation is config-driven, so Galaxy-installed and collection roles
  resolve, not just playbook-adjacent ones.
- Resolution stats candidate directories per request; roles are few, so this is
  cheaper than a startup scan of every collection and `~/.ansible/roles`.
- `ansible-config dump` is now shared by the module index and role resolution,
  so it runs at most once per server lifetime.
- `tasks_from` is not honored; a role invoked with `tasks_from: setup.yml` still
  navigates to `tasks/main.yml`.
- A workspace-wide role index could later replace on-demand resolution without
  changing the provider interface.
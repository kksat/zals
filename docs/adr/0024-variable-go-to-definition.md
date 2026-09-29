# ADR-0024: Variable go-to-definition

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** in part by ADR-0031 (parse cache), ADR-0032 (search boundary)

## Context

Go-to-definition currently resolves only module names, to the module's source
file (ADR-0009). Users also expect to jump from a **variable reference** to the
site that binds it. Ansible has no single definition per name: the same variable
can be bound at play level, task level, in a role's `defaults/` or `vars/`, by
`set_fact` or `register`, and more, with a ~20-level precedence deciding the
winner at runtime. This is a post-parity feature; upstream has no counterpart to
match.

This ADR defines the shared variable model — scope, definition sites, Jinja
tokenization, and caching — used by both go-to-definition and find-references
([ADR-0025](0025-variable-references.md)).

## Decision

**Trigger surface.** A variable reference is an occurrence inside a Jinja
expression (`{{ … }}`, `{% … %}`) or a bare name in an expression-valued key:
`when`, `changed_when`, `failed_when`, `until`, `loop`, `with_*`, and
`assert.that`. All other keys are literal strings where only `{{ … }}` counts.
Within an expression, only **root** identifiers resolve; an attribute (`name` in
`user.name`) or filter (`default` in `x | default(y)`) returns no definition.

**In-scope definition sites.**

| # | Site |
| --- | --- |
| 1 | Play-level `vars:` |
| 2 | Block-level `vars:` |
| 3 | Task-level `vars:` |
| 4 | `register:` |
| 5 | `set_fact` |
| 6 | `vars_files:` |
| 7 | `loop_control.loop_var` |
| 8 | `include_vars` (without a `name` prefix) |
| 9 | `vars_prompt:` `name` values |
| 10 | Role `defaults/main.yml` |
| 11 | Role `vars/main.yml` |
| 12 | Role `meta/main.yml` `argument_specs` (`options` keys) |
| 13 | `vars:` / `register:` / `set_fact` inside role `tasks/*.yml` |
| 14 | Role invocation params in a playbook's `roles:` entry |

Out of scope: `include_vars` with a `name` prefix (the prefix namespaces the
loaded variables; deferred), and inventory, extra, and magic vars.

**Visibility.** The candidate set is the reference's **scope chain**: the
enclosing role's files (if inside a role) + the reference's own task/block vars
+ `set_fact`/`register`/`include_vars` in the same play or role. Unrelated roles
are never candidates. `loop_control.loop_var` is visible only inside its loop
body. Role invocation params (site 14) are visible only in the playbook that
invokes the role; resolving them from inside the role would require a reverse
role→playbook lookup, which is out of scope — from inside a role, a parameter
resolves to its `argument_specs` declaration (site 12).

**Result shape.** Return **all** visible definitions as `Location[]`, ranked
highest-precedence first, rather than a single best target. Ranking mirrors
Ansible's precedence for the in-scope sites:

| Rank | Site |
| --- | --- |
| 1 | `loop_control.loop_var` (within its loop only) |
| 2 | Role invocation params (playbook scope only) |
| 3 | `set_fact` / `register` |
| 4 | `include_vars` |
| 5 | Task-level `vars:` |
| 6 | Block-level `vars:` |
| 7 | Role `vars/main.yml` |
| 8 | `vars_files` |
| 9 | `vars_prompt` |
| 10 | Play-level `vars:` |
| 11 | Role `defaults/main.yml` |
| 12 | `argument_specs` (declaration) |

**Cross-file access.** Role and `vars_files`/`include_vars` files are read from
disk on demand, but the `DocumentStore` is consulted first so unsaved edits win.
Parsed files are cached by path + mtime. `vars_files`/`include_vars` targets are
followed **one level** (a target that itself includes vars is not followed
further). The role root is derived from the reference's file path (the ancestor
whose child is `tasks/`, `defaults/`, `vars/`, `meta/`, or `handlers/`); no
`roles_path`/`ansible.cfg` lookup is needed.

**Implementation.** The variable model — definition collection, scope
resolution, precedence ranking, and Jinja tokenization — lives in
`src/variables/` over the YAML DOM. The definition provider stays a thin
adapter. Jinja is tokenized from the **raw** scalar source (not the unescaped
`value`) so cursor offsets stay exact.

## Consequences

- The definition provider returns one `Location` for modules and many for
  variables; clients handle both, but the asymmetry is deliberate.
- We do not model Ansible's full precedence or inventory/extra-vars; ranking is
  a documented subset, so the winning definition is first but the list may omit
  sources we don't index.
- Role parameters point at the declaration in `meta/main.yml` when referenced
  from inside the role, and at the invocation when referenced in the playbook.
- A workspace-wide role→playbook index can later replace the dropped reverse
  lookup without changing the provider interface.
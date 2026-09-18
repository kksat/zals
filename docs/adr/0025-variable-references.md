# ADR-0025: Variable references

- **Status:** Accepted
- **Date:** 2025-09-18
- **Supersedes:** —
- **Superseded by:** —

## Context

`textDocument/references` for Ansible variables is a zals extension: upstream's
language server has no references provider. It shares the variable model —
scope, definition sites, Jinja tokenization, and caching — with variable
go-to-definition ([ADR-0024](0024-variable-go-to-definition.md)). This ADR
settles how references *searches*: which occurrences it returns and how it
resolves the name under the cursor.

## Decision

**Resolution is name-based.** Every occurrence of the same identifier in the
file set is a reference. We do not model Ansible's precedence or shadowing, and
we do not require a definition to exist. This is deliberately different from
go-to-definition, which is scope-aware and ranks visible definitions
(ADR-0024): references answers "where is `foo` used?", not "which `foo` is
this?".

**Scope is the file set from ADR-0024** — the enclosing role's conventional
directories, or the playbook file, plus one level of `vars_files`/`include_vars`
targets and `meta/main.yml`.

**Reference occurrences** are identifiers inside Jinja expressions (`{{ … }}`,
`{% … %}`) and bare names in expression-valued keys: `when`, `changed_when`,
`failed_when`, `until`, `loop`, `with_*`, and `assert.that`. Only root
identifiers count; attributes, filters, and tests do not. Dynamic access
(`vars['x']`, `lookup('vars', …)`, `hostvars[…]`) is out of scope.

**`includeDeclaration`.** When true, return every variable definition in the
file set alongside the references. Definitions are peers; the cursor's own
definition is not special-cased.

**Result shape.** `Location[]` with identifier-level ranges, ordered by file
path then byte offset. `null` when the cursor is not on a variable; `[]` when it
is but nothing matches.

## Consequences

- Results match the question users actually ask ("where is `foo` used?").
- A static resolver would be wrong as often as right, because precedence depends
  on inventory and include order that are not visible in the role or playbook.
- References and go-to-definition can disagree: go-to-definition may rank one
  definition first, while references lists all of them. This is intentional.
- Inventory, extra vars, magic vars, and `include_vars` name prefixes are not
  searched. Documented gaps, not bugs.
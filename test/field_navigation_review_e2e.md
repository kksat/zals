# Field navigation regression contracts

Field-navigation behaviors locked down after review, covered by the
`navigation-e2e` cases and the `field-parameter-edits-e2e` buffer scenarios.

## Seam and oracle rules

Public LSP requests against a real stdio server; tests import only test
helpers. Fixtures are checked-in data; controlled unsaved buffers never change
disk files. No collections are installed and no playbook is executed.
References compare complete lists with duplicates, both declaration modes
independently authored. Definition and implementation keep ordered targets.
Hover checks original-source UTF-16 ranges, positive values/descriptions, and
explicit non-matches.

## Contracts

- **Escaped YAML binding ranges**: a quoted `"\u0065scaped_key"` binding's range
  is its quote-free contents, for references, definition, implementation, and
  hover.
- **Structured data versus directives**: a nested `vars` key inside task vars,
  map-root vars files, `set_fact` values, or passed role values is data, not a
  second declaration. Binding collection stops at bound values and descends only
  through actual play/task containers; module arguments declare nothing.
- **YAML quoting and lexical boundaries**: see
  [field_expressions_e2e.md](field_expressions_e2e.md) and
  [field_lexical_boundaries_e2e.md](field_lexical_boundaries_e2e.md).
- **Indexed callee reuse**: callee implementations reuse stored full-path field
  and vars-load facts, replaced by open-buffer facts when present, preserving
  callee-only scope, one-level loads, precedence, and unindexed-dependency
  fallback.
- **Explicit JSON dependencies**: an explicitly loaded JSON dictionary and its
  buffer override are extracted even though JSON is outside general Workspace
  discovery; Python documentation is never indexed as variables.
- **Load-looking data**: nested data keys named `include_vars` or `vars_files`
  do not widen callee scope; vars-load extraction follows only sequence-root
  play/task containers.

## Scope

References remain Workspace-wide leaf-name matching, separate from root names.
Passed-field contracts and implementations use callee/full-path context and
never narrow references. No runtime object identity, loop tracing, YAML alias
expansion, or Jinja literal-key escape decoding. Decisions live in
[variable-navigation.md](../docs/variable-navigation.md),
[ADR-0041](../docs/adr/0041-field-name-navigation.md), and
[ADR-0042](../docs/adr/0042-passed-role-field-navigation.md).

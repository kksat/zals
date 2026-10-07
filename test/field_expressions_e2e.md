# Field-expression stdio suite

Run: `make e2e SUITE=field-expressions-e2e`.

## Seam and oracle rules

Public `textDocument/references`, `textDocument/definition`,
`textDocument/implementation`, and `textDocument/hover` over a real
`zig-out/bin/zals --stdio` process, using the shared framing client and
unique-span UTF-16 anchor helper. No production imports, private-function
tests, inferred answers, mutable fixture copies, watcher events, or external
repositories. The checked-in Workspace is
`test/fixtures/field-expressions-workspace`; temporary directories isolate HOME
and the docs cache only. Validation is disabled and `venvPath` is empty.

Both `includeDeclaration` answers are complete, separately written lists;
comparisons preserve duplicates while ignoring result order. Field references
match leaf NAME across receivers and binding keys, independently of same-named
root Variables. The suite does not infer runtime object identity or loop
aliases. Non-BMP prefixes (🛰) exercise UTF-16 rather than byte/scalar
coordinates. Static-subscript spans select the key contents, not quotes or
brackets.

## Covered behavior

- **Static quoted subscripts**: `record.field_name`, `other['field_name']`, and
  `spare["field_name"]` form one group with their concrete binding keys.
- **Plugin names**: plain and dotted filter/test names (including
  `{% filter ... %}` blocks) are not fields; their arguments are.
- **Called methods**: a dot/subscript name followed by `(` (whitespace allowed)
  is not a field read; its arguments and result reads are.
- **Strings and comments**: Jinja strings in both quote styles (with backslash
  escapes), literal list/map strings, Jinja comments, and YAML comments
  contribute no names.
- **Expression contexts**: interpolation, statement subscripts, bare `when`
  expressions, and reads in unrelated Roles of the same Workspace.
- **Root controls**: same-named root Variables, dynamic subscripts (root reads
  of the selector), and integer/decimal/computed subscripts stay out of the
  field group.
- **Keyword-like members**: `data.filter`, `data.is`, `data.true` are fields,
  matching their quoted-subscript aliases; plugin state ends at a completed
  plugin name, so `if`/`else` resume ordinary scanning.
- **Quoted closing delimiters**: `}}` and `%}` inside string literals do not
  close the expression; field-looking text inside those literals is excluded.
- **YAML scalar quoting**: doubled single quotes and double-quoted escapes are
  normalized before Jinja scanning, and results map back to original source
  spans (a `\u0079aml_field` key covers its encoded source). Plain, block, and
  `.j2` text use the source directly. All four actions agree on these spans;
  hover shows **Variable field**, never the same-named root value.

## Known limitations

Jinja key-literal escapes are not decoded. Jinja resolves `data['\u0066ilter']`
to the `filter` key, but the scanner keeps the raw name `\u0066ilter`, so it
does not join the `filter` group. YAML quote normalization is a separate,
supported layer: two YAML backslashes become one Jinja backslash, which is then
kept raw.

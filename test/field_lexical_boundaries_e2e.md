# Field lexical-boundary stdio suite

Run: `make e2e SUITE=field-lexical-boundaries-e2e`.

## Seam and oracle rules

Public `textDocument/references`, `textDocument/definition`,
`textDocument/implementation`, and `textDocument/hover` through a real
`zig-out/bin/zals --stdio` process. The suite imports test framing/anchor/model
helpers only, never production code. Its checked-in Workspace is
`test/fixtures/field-lexical-boundaries-workspace`; HOME and docs cache are
isolated in a temporary directory. Fixture contents are never edited by tests.
Validation is disabled and the configured virtual environment is empty.

Both reference modes have complete, independently written answers, compared
without discarding duplicates. Definition and implementation compare complete
ordered locations. Hover checks exact leaf ranges, positive Markdown excerpts,
and deliberate non-matches; negative hovers must be null. All four actions are
requested from every positive origin and negative cursor. Non-BMP prefixes
exercise UTF-16 spans. Ordinary field groups are Workspace-wide leaf names,
separate from root Variable groups.

## Covered behavior

- **Raw blocks**: field/root-looking text inside `{% raw %}...{% endraw %}`
  (with `-` trim and `+` preservation markers) is not navigable; reads before
  and after `endraw` are. Unmatched quotes, comments, or statement-looking text
  inside raw contents cannot hide the closing tag. A raw-looking tag inside a
  genuine Jinja string is ordinary string content. A trailing `+` on an opening
  raw tag is invalid and is not recognized.
- **`set` field-assignment targets**: in `{% set ns.region = other.region %}`
  the left target is a write, not a read. RHS values, dynamic RHS selectors,
  capture bodies, and capture-filter arguments remain reads. Separate
  selector-field and root Variable groups guard against over-suppression.

## Boundaries

Only raw-block literals and `set` target/read separation are in scope. No YAML
alias expansion, runtime object identity, loop tracing, or Jinja binding-flow
analysis. YAML quoting and Jinja key escapes are covered by
[field_expressions_e2e.md](field_expressions_e2e.md); integrated field
regressions by [field_navigation_review_e2e.md](field_navigation_review_e2e.md).

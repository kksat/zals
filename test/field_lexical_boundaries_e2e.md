# Field lexical-boundary stdio verification

## Agreed seam and scope

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

Run directly (parent owns aggregate/build registration):

```sh
DEVELOPER_DIR=/nonexistent zig build
DEVELOPER_DIR=/nonexistent zig test test/field_lexical_boundaries_e2e.zig
DEVELOPER_DIR=/nonexistent zig test test/field_expressions_e2e.zig
DEVELOPER_DIR=/nonexistent zig test test/e2e.zig
DEVELOPER_DIR=/nonexistent zig build test
```

## Slice 1 — raw-block literals

One behavioral tracer verifies ordinary and whitespace-trimmed raw blocks:
field/root-looking template text and markup are not navigable; genuine reads
before/after `endraw` remain navigable. Literal unmatched quotes/comments and
statement-looking text inside raw contents cannot hide the closing tag.
A raw-looking tag inside a genuine Jinja string remains just string content.
An unrelated Role read joins the field group. The separate root Variable
oracle excludes the same root spelling inside raw contents.

- **RED at 448adf3:** 1 failing test, 130 public action requests, 56 failed
  checks. Raw literal fields/root names entered reference answers, and literal
  quote/comment text prevented genuine subsequent reads from being recognized.
  Log: `/tmp/field-lexical-raw-red.log`.
- **Minimal fix:** recognize a complete `raw` tag (including valid `-` trim
  markers), skip literal contents through a complete `endraw` tag without
  interpreting their quotes/comments, then resume normal scalar scanning.
- **GREEN:** 1/1 test; 130 requests, zero failures.
  Log: `/tmp/field-lexical-raw-green.log`.
- Existing contracts: 10/10 field-expression tests (272 exact reference
  requests), 496 semantic cases with zero failures, and `zig build test` pass.
  Logs: `/tmp/field-lexical-raw-existing-expressions.log`,
  `/tmp/field-lexical-raw-existing-semantic.log`,
  `/tmp/field-lexical-raw-unit.log`.

## Boundaries

This work does not normalize YAML scalar escapes or decode static Jinja key
escapes. It does not expand YAML aliases or introduce runtime object identity,
loop tracing, or Jinja binding-flow analysis. Only raw-block literals and
`set` field-assignment target/read separation are in scope.

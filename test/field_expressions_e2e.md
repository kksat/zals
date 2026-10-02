# Field-expression stdio verification

## Agreed seam and scope

Public `textDocument/references` over a real `zig-out/bin/zals --stdio`
process, using the shared framing client and unique-span UTF-16 anchor helper.
No production imports, private-function tests, inferred answers, mutable fixture
copies, watcher events, or external repositories. The checked-in Workspace is
`test/fixtures/field-expressions-workspace`; temporary directories isolate HOME
and the docs cache only. Validation is disabled and `venvPath` is empty.

Both `includeDeclaration` answers are complete, separately written lists;
comparisons preserve duplicates while ignoring result order. Field references
match leaf NAME across receivers and binding keys, independently of same-named
root Variables. This suite does not infer runtime object identity or loop aliases.
The non-BMP 🛰 prefix exercises UTF-16 rather than byte/scalar coordinates.
Static-subscript spans select the key contents, not quotes or brackets.

Run after each production change:

```sh
make build
DEVELOPER_DIR=/nonexistent zig test test/field_expressions_e2e.zig
make test
DEVELOPER_DIR=/nonexistent zig test test/e2e.zig
```

## Slice 1 — static quoted subscripts

- Wrote one stdio test with the complete three-read group:
  `record.field_name`, `other['field_name']`, `spare["field_name"]`.
  Requested both modes from all three reads and both concrete binding keys
  (a list-of-mappings key and an unrelated mapping key).
- **RED:** parent snapshot, `make build` then the independent Zig test:
  1 failed test / 10 failed requests. Dot/key origins returned only the dot
  read (3 locations including keys instead of 5); subscript origins returned
  no field reads. Log: `/tmp/field-expressions-slice1-red.log`.
- **Smallest fix:** recognize a complete literal-string subscript following
  a value, emitting its unquoted byte span only in the field scanner.
  Dynamic root-name scanning is untouched.
- **GREEN:** independent test 1/1; `make test` passed; existing semantic
  stdio suite **338 cases, 0 failures**.

## Slice 2 — qualified filter/test names

- Added one test separating six genuine field reads (including filter/test
  arguments) from plain and dotted plugin names. Both modes are requested
  from every positive read/key and fourteen negative plugin-name cursors.
- **RED:** prior lexical commit, independent suite 1 passed / 1 failed.
  Every positive origin incorrectly returned 10 reads rather than 6
  (11 rather than 7 including the concrete key): four qualified-name
  components falsely joined the field group.
  Log: `/tmp/field-expressions-slice2-red.log`.
- **Smallest fix:** retain plugin-name state across its dotted components,
  clearing it when normal expression punctuation/keywords resume. Field
  arguments remain real reads.
- **GREEN:** independent suite 2/2, including all negative cursors;
  `make test` passed; semantic suite **338 cases, 0 failures**.
  The first combined command exceeded its outer 180-second deadline during
  semantic verification; an isolated rerun completed successfully in 24 seconds.

## Slice 3 — called methods

- Added one test with negative cursors on dot and static-subscript callees,
  including whitespace before calls, plus complete positive oracles for stored
  values, method arguments, and fields read from a call's result.
- **RED:** previous lexical commit, independent suite 2 passed / 1 failed;
  all 12 negative requests failed. Called `method_field` names returned the
  eight-site field group (nine with its key); `invoke` names returned two
  false field reads. Log: `/tmp/field-expressions-slice3-red.log`.
- **Smallest fix:** do not emit a dot/subscript field name immediately followed
  by a call's opening parenthesis, allowing whitespace. Continue scanning the
  call's argument and result expressions normally.
- **GREEN:** independent suite 3/3; `make test` passed; semantic suite
  **338 cases, 0 failures**.

## Slice 4 — strings and comments

- Added one test with complete genuine-read/key answers and eleven negative
  cursors: single/double strings, escaped quotes, literal list/map strings,
  Jinja comments, YAML comments, and non-expression text.
- **RED:** previous lexical commit, independent suite 3 passed / 1 failed.
  The escaped single-quoted string leaked a false field read; both negative
  requests failed (2/3 locations rather than none).
  Log: `/tmp/field-expressions-slice4-red.log`.
- **Smallest fix:** honor backslash escapes in both Jinja quote styles, keeping
  the string skip bounded by the expression length.
- **GREEN:** independent suite 4/4; `make test` passed; semantic suite
  **338 cases, 0 failures**.

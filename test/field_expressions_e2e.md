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

## Verification slice 5 — expression contexts

- Added one stdio test with six explicitly enumerated reads: interpolation,
  single/double-quoted template statement subscripts (including bracket
  whitespace), bare `when` sequence expressions, and a read in an unrelated
  Role in the same Workspace. Both modes are requested from every read and key.
- **GREEN on first run:** independent suite 5/5. Existing paths already support
  these contexts after slice 1; no speculative production change or fabricated
  RED was needed.

## Verification slices 6/7 — roots and non-literal subscripts

- Added the complete, separately enumerated same-named root-Variable group:
  a direct root read, a dynamic-subscript root read, a bare-expression dynamic
  root read, and only the root key when declarations are included. Every origin
  is requested in both modes. The existing three-read field oracle remains
  unchanged despite these added root references.
- Added negative requests in both modes for integer, negative, decimal, and
  computed-string subscripts. Static string *expressions* containing a field's
  spelling do not turn into static field reads.
- **GREEN on first run:** independent suite 7/7. No production change needed;
  these are deliberate verification controls, not fabricated failing tests.

## Slice 8 — template filter-block names

- Added one test extending the filter-name non-match to `{% filter ... %}`
  statements, with explicit positive stored-field/argument oracles and negative
  cursors on plain and qualified block filter names.
- **RED:** previous lexical commit, independent suite 7 passed / 1 failed;
  8 negative requests failed because plain plugin names became roots and
  qualified components became fields.
  Log: `/tmp/field-expressions-slice8-red.log`.
- **Smallest fix:** let the `filter` statement keyword introduce the same
  plugin-name state as a pipe expression; ordinary field arguments still scan.
- **GREEN:** independent suite **8/8**; `make test` passed; semantic suite
  **338 cases, 0 failures**.

## Final verification

- `make build`: passed.
- `DEVELOPER_DIR=/nonexistent zig test test/field_expressions_e2e.zig`:
  **8 tests passed**, **150 reference requests** with exact full-result oracles.
- `make test`: passed.
- `DEVELOPER_DIR=/nonexistent zig test test/e2e.zig`:
  **338 semantic cases, 0 failures**.
- No shared build/test registry changes are included; this independent suite
  remains directly invocable until the parent registers it.

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

## Review follow-up / slice 9 — keyword-like members

- Installed **Jinja 3.1.6** (`/opt/homebrew/lib/python3.14/site-packages/jinja2`)
  rendered `data.filter`, `data.is`, and `data.true` identically to their
  single/double-quoted subscript aliases. Qualified plugin names containing
  these spellings, ordinary/trimmed filter blocks, and the conditional
  expression used below were also accepted (plugin names registered explicitly
  for that syntax check; the LSP suite does not execute Jinja or Ansible).
- Added one stdio test with independently authored, complete answers for each
  keyword-like field group. Both modes are requested from every dot read,
  both quoted aliases, the binding key, and a statement/bare-expression read.
  Genuine filter/test operators, dotted keyword-like plugin components, filter
  blocks, and a called keyword-like method are negative cursor controls.
- **RED:** previous lexical commit, independent suite 8 passed / 1 failed,
  **30 positive requests failed**. Dot origins returned nothing, while
  subscript/key origins returned two reads rather than four (three rather than
  five including the key). Log: `/tmp/field-expressions-slice9-red.log`.
- **Smallest fix:** handle member/plugin context before keyword spelling.
  A `filter` block introduces plugin state only as the first word of a
  statement tag (including the optional `-` whitespace-control marker),
  not after an ordinary member dot or elsewhere in an expression.
- A further **RED** control for
  `data | lower if enabled else other.filter` exposed plugin state leaking
  across a completed name into expression keywords: **12 field-group requests
  and 2 root-Variable requests failed**.
  Log: `/tmp/field-expressions-slice9-conditional-red.log`.
  The minimal state correction distinguishes an explicit plugin-name dot from
  the end of a plugin name, so `if`/`else` resume ordinary expression scanning.
- **GREEN:** independent suite **9/9**, all full reference answers and negative
  cursors; `make test` passed; the isolated snapshot's existing semantic suite
  remains **338 cases, 0 failures**. Parent's separately evolving schema/hover
  cases are not imported into this worktree.

## Review follow-up / slice 10 — quoted closing delimiters

- Added one stdio test with four genuine field reads **after** strings containing
  closing delimiters: `}}` in interpolations and `%}` in statements. The strings
  contain fake field/root-looking template text which is excluded independently
  by negative cursor requests. Block YAML and single-quoted YAML scalar forms
  avoid YAML escape-normalization scope. One block string includes escaped
  Jinja quotes to exercise the existing string-boundary behavior.
- The valid YAML and Jinja forms were accepted by installed **PyYAML 6.0.3** and
  **Jinja 3.1.6**. These are independent syntax checks only; the retained suite
  still uses public stdio LSP without executing Jinja or Ansible.
- Both declaration modes have independently enumerated full oracles:
  the four-read field group and its key; two incomplete-expression fallback
  field reads and their key; and all six genuine receiver root reads plus only
  their root binding. Negative cursors cover fake fields and roots inside each
  of the four literals, plus a comment containing delimiters and quotes.
- **RED:** prior lexical commit, independent suite 9 passed / 1 failed,
  **48 failed requests**: 10 field-group, 14 root-group, and 24 literal-negative
  requests. Genuine-read origins returned nothing; binding-origin results
  contained phantom reads with incorrect exact spans, even where cardinality
  matched the written four-read oracle. Incomplete-expression field fallback
  and comment-negative controls were already green.
  Log: `/tmp/field-expressions-slice10-red.log`.
- **Smallest fix:** replace only the interpolation/statement closing-delimiter
  searches with a quote-aware helper reusing `skipString`. Keep comment scanning
  and the null-delimiter fallback paths unchanged. No subscript-key escape
  decoding is implemented.
- **GREEN:** independent suite **10/10**, **272 exact reference requests**;
  `make test` passed; isolated baseline semantic suite
  **338 cases, 0 failures**.

## Known limitations

### Static-subscript literal escapes

The scanner preserves the raw source contents of a literal key; it does **not**
decode Jinja string escapes when assigning the field name. For example, installed
Jinja resolves `data['\u0066ilter']` to the `filter` key, but this scanner stores
the name `\u0066ilter`, so it does not join the ordinary `filter` name group.
Escaped quotes, backslashes, Unicode escapes, and other decoded-key aliases are
not claimed as supported. Honoring escapes while skipping string boundaries
(slice 4) is different from decoding field-key literals.

## Final verification

- `make build`: passed.
- `DEVELOPER_DIR=/nonexistent zig test test/field_expressions_e2e.zig`:
  **10 tests passed**, **272 reference requests** with exact full-result oracles.
- `make test`: passed.
- `DEVELOPER_DIR=/nonexistent zig test test/e2e.zig`:
  **338 semantic cases, 0 failures**.
- The parent registers this independent suite as `zig build field-expressions-e2e`
  and includes it in `make e2e` / CI, tracking the server and checked-in fixture
  inputs. Direct `zig test` invocation also remains available.

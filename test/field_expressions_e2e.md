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

# Field navigation: post-review verification

## Seam and oracle rules

All regressions use public LSP requests against a real stdio server. Tests import
only test helpers, not production code. Fixtures are checked-in data; controlled
unsaved buffers do not change disk files. No collections are installed and no
playbook is executed. References compare complete lists without discarding
duplicates; both declaration modes are independently authored. Definition and
implementation retain ordered targets. Hover checks original-source UTF-16
ranges, positive values/descriptions, and explicit non-matches.

The Standards/Spec review covered `0ab7a9f...448adf3`. Its findings were fixed,
then both reviewers approved the final bounded remediations.

## Regression slices

- **Escaped YAML binding ranges (`be72339`).** The quoted
  `"\u0065scaped_key"` tracer returned `[3:2,3:20)` instead of its quote-free
  `[3:3,3:19)` contents. RED was observed before fixing scalar-range selection.
  Ten read/key-origin checks cover references, definition, implementation, and
  parsed-value hover. GREEN: 506 semantic cases.
- **Structured data versus directives (`8f63342`).** Task vars, map-root vars
  files, set-fact values, and passed role values containing a nested `vars` key
  returned the same declaration twice: three reference locations instead of
  two. A separate module-argument control returned a false declaration.
  Collection now stops at bound values and descends only through actual
  play/task containers. Expanded all-action/read-and-key oracles were GREEN:
  559 semantic cases, 211 unit tests.
- **YAML quoting (`5a873ed`, `65edfb4`).** Normalize doubled single quotes and
  double-quoted YAML escapes before scanning Jinja, then map names back to
  original source spans. Field and root groups remain separate. See the
  observed RED/GREEN history and all-action controls in
  [field_expressions_e2e.md](field_expressions_e2e.md).
- **Raw literals and assignment targets (`48648c6`, `a738e8a`, `b287931`).**
  Raw blocks do not contribute names; set field targets are writes, while RHS,
  selector, and capture reads remain eligible. Valid trim/preservation markers
  are covered. See [field_lexical_boundaries_e2e.md](field_lexical_boundaries_e2e.md).
- **Indexed callee reuse (`9182dee`).** Reuse stored full-path field and vars-load
  facts, replacing them with open-buffer facts as needed. Preserve callee-only
  scope, one-level loads, precedence, and unindexed dependency fallback.
  Existing contracts and a new task/load-buffer ordering scenario were GREEN;
  this was a behavior-preserving refactor, not an invented RED.
- **Explicit JSON dependencies (`7f6f519`).** The index-discovery extension gate
  incorrectly dropped a valid explicitly loaded JSON dictionary and its buffer
  override. RED: expected JSON/vars/default targets, got only vars/defaults.
  Explicit dependency extraction now bypasses that gate without changing
  general Workspace discovery or indexing Python documentation as variables.
  GREEN: all three field-buffer scenarios, including the independently authored
  moved JSON key span `[3:7,3:18)`. Fixtures remain unchanged on disk.
- **Load-looking data (`db90ff4`).** Nested data keys named `include_vars` or
  `vars_files` falsely expanded callee scope. Defaults, task-vars, set-fact, and
  module-argument controls produced seven implementation failures: an unrelated
  JSON target appeared before the two real callee bindings. Vars-load extraction
  now follows only actual sequence-root play/task containers. GREEN: 560 semantic
  cases; real YAML/JSON load and overlay controls remain positive.

## Integrated verification

At `db90ff4`, on Zig 0.15.1:

- `make test e2e smoke`: passed.
- `zig build test e2e --summary all`: **269/269 tests** (211 unit, 58 E2E),
  including **560 semantic navigation cases**, zero failures.
- Field-expression suite: **13 tests**, 308 reference requests and 51 other
  navigation requests. Lexical-boundary suite: **2 tests / 290 requests**.
- Fresh-cache isolated Python 3.12 / `ansible-core==2.19.2` run:
  **58/58 E2E tests** passed.
- Formatting checks for changed Zig files and `git diff --check`: passed.
  Seven unchanged pre-existing files are outside this formatting cleanup.
- A read-only exploratory probe of `/Users/ksatarin/dev/internal.leapp` passed
  exact role/parameter/module/collection/symbol targets and the reported
  `item.resourcegroup_name` field's five parsed platform-key targets and hover.
  Reference symmetry was checked from read/binding origins. These exploratory
  comparisons are not substitutes for the checked-in complete oracles.
  The external repository remained clean.

Some intermediate reruns hit readiness deadlines while macOS repeatedly entered
sleep. Power logs confirmed the suspension. Five isolated keyword-suite runs
passed; a final aggregate run with temporary `caffeinate -i` sleep prevention
passed. No product or test-timeout workaround was introduced.

## Scope retained

References remain Workspace-wide leaf-name matching, separate from root names.
Passed-field contracts and implementations use callee/full-path context, never
narrowing references. No runtime object identity, loop tracing, YAML alias
expansion, or Jinja literal-key escape decoding is claimed. YAML quoting
normalization is a separate, supported layer. The scope and decisions are in
[variable-navigation.md](../docs/variable-navigation.md),
[ADR-0041](../docs/adr/0041-field-name-navigation.md), and
[ADR-0042](../docs/adr/0042-passed-role-field-navigation.md).

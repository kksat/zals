# Navigation E2E suite

Run `make e2e SUITE=navigation-e2e` to build zals and run **one** Zig E2E test over
the named cases (`make e2e` runs this and the independent suites listed below). It starts one stdio server with an isolated HOME and the checked-in
collections/roles paths, waits for `ansible/workspaceIndexReady`, then opens
source files with
their unchanged on-disk contents. It does not install collections, copy the
fixture, run Ansible, send edits, or test file watching.

Cases live in `cases/{roles,collections,files,variables,role_parameters,fields,field_parameters}.zig`. Each named case
spells out its full expected locations. `cursor(path, "...<selected>...")`
selects a unique source snippet; `span(...)` marks a unique expected range;
`fileStart(path)` expects the zero-width range at the start of a file. Markers
exist **only in Zig**, not in the Ansible fixture. Coordinates are calculated
in UTF-16, so fixture lines can move without changing tests. Missing or
ambiguous snippets fail instead of guessing.

References compare complete, order-independent lists **with duplicates**;
definition and implementation compare ordered lists. A `null` or `[]` result
is accepted only for cases expecting no locations. JSON-RPC errors always
fail. New references must be added to the written oracle—never harvested from
zals output or derived by scanning the fixture for references.

Hover cases assert exact cursor ranges plus independently specified Markdown
excerpts and deliberate non-matches. The parameter cases also enumerate a
sixteen-site root-variable group and verify both declaration modes from every
explicit origin; a role or entry-point context does not narrow root references.
Field cases exercise both declaration modes and ordered definition/implementation
plus hover from every read, concrete key, and nested schema key in a small group.
Schema-only, metadata, unbound, and same-named-root cases are deliberate controls.
Escaped YAML keys retain quote-free source ranges. Reserved data keys such as
`vars` do not introduce duplicate bindings; task-vars, vars-file, set-fact,
and passed-role values exercise all actions, with module-argument negatives.
Passed-field cases check full-path callee/entry-point targets, lists and quoted
YAML keys, intermediate dictionaries, and negative collisions. Both complete
reference answers are requested from all 27 explicit sites of a field group,
including unrelated roots and roles, unresolved calls, and ordinary task vars.
The separate `test/role_parameter_edits_e2e.zig` stdio scenario checks unsaved
argument-spec documentation and shifted key ranges without changing fixture
files on disk.

## Independent stdio suites

`make e2e` / `zig build e2e` runs all of these roots against the installed
`zig-out/bin/zals`. Each can also be selected separately:

| Build target | Test root | Contract |
| --- | --- | --- |
| `navigation-e2e` | `test/e2e.zig` | Read-only semantic navigation with complete written location oracles |
| `standalone-role-e2e` | `test/standalone_role_e2e.zig` | Root-level Role repositories, both YAML extensions, split defaults/vars precedence, root/field navigation, templates, and Role-relative task includes |
| `field-expressions-e2e` | `test/field_expressions_e2e.zig` | Dot/static-subscript reads, YAML quoting/source spans, expression contexts, literal/plugin/method negatives |
| `field-lexical-boundaries-e2e` | `test/field_lexical_boundaries_e2e.zig` | Raw literals, field-assignment targets, genuine RHS/capture reads, whitespace markers |
| `field-parameter-edits-e2e` | `test/field_parameter_edits_e2e.zig` | Changed full-path contracts/values, complete Workspace references, and callee vars-load overlays |
| `role-parameter-edits-e2e` | `test/role_parameter_edits_e2e.zig` | Unsaved argument-spec ranges and hover |
| `collection-symbols-e2e` | `test/collection_symbols_e2e.zig` | Collection layouts, member symbols, open buffers, and watcher boundaries |
| `navigation-uris-e2e` | `test/navigation_uris_e2e.zig` | Absolute and escaped targets from relative/absolute search paths |
| `selected-venv-e2e` | `test/selected_venv_e2e.zig` | Selected installations, per-file module docs, discovery, and cache isolation |

The standalone Role suite runs two isolated, read-only Workspaces from
[`test/fixtures/standalone-role/`](../fixtures/standalone-role/README.md).
Each Workspace is itself one Role, with no `roles/<name>/`, collection metadata,
or `ansible.cfg`. It checks disk-indexed Role symbols before opening documents,
complete reference lists in both declaration modes from every explicit read and
binding, ordered definitions/implementations, exact hover ranges and Role
precedence labels, split defaults, and nested task includes that require the
Role's `tasks/` fallback. Installed dependencies and the user's HOME are isolated;
validation is disabled so the suite needs no Ansible executables. Neovim filetype
detection/attachment remains covered separately by `make neovim-test`.

Field-expression coverage and literal-escape limitations are in
[`test/field_expressions_e2e.md`](../field_expressions_e2e.md); raw/assignment
boundaries in
[`test/field_lexical_boundaries_e2e.md`](../field_lexical_boundaries_e2e.md);
post-review binding/load boundaries, JSON dependencies, and index reuse in
[`test/field_navigation_review_e2e.md`](../field_navigation_review_e2e.md).

The last suite requires `ansible` and `ansible-doc` on PATH (see
[`test/selected_venv_e2e.md`](../selected_venv_e2e.md)); the other suites do not
require those executables. CI installs `ansible-core==2.19.2` on Python 3.12
before the aggregate target. All fixture files are ordinary checked-in data;
no suite installs collections or executes a playbook.

The build tracks the server and every relevant fixture/dependency file as run
inputs. The module-docs suite always runs because changes to the external
Ansible installation are not represented by those file inputs. These suites
remain separate from `make test` and the existing Python smoke targets.
Run one suite with `make e2e SUITE=<step>` (`make zig ARGS="build -l"` lists
the steps).

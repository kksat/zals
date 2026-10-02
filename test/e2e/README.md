# Navigation E2E suite

Run `make e2e` to build zals and run **one** Zig E2E test over the named
cases. It starts one stdio server with an isolated HOME and the checked-in
collections/roles paths, waits for `ansible/workspaceIndexReady`, then opens
source files with
their unchanged on-disk contents. It does not install collections, copy the
fixture, run Ansible, send edits, or test file watching.

Cases live in `cases/{roles,collections,files,variables,role_parameters}.zig`. Each named case
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
The separate `test/role_parameter_edits_e2e.zig` stdio scenario checks unsaved
argument-spec documentation and shifted key ranges without changing fixture
files on disk.

# Selected virtual environment regression suite

`make e2e` includes this independent Zig black-box stdio LSP runner. Run it alone:

```sh
DEVELOPER_DIR=/nonexistent zig build selected-venv-e2e --summary all
```

POSIX and Windows layouts use separate selected environments: `Lib` and `lib`
cannot coexist reliably in one checked-in directory on case-insensitive macOS.
The Windows fixture also checks root-before-site-packages precedence.

The environment override is the existing macOS SDK workaround; it is unnecessary
on Linux. The runner uses `test/e2e/client.zig` and `anchor.zig`, starts the built
`zig-out/bin/zals`, and waits for Workspace indexing. Static fixtures live in
`test/fixtures/selected-venv/`; the `.venv` and `other-env` directories model
installation layouts, not runnable Python environments. HOME and XDG cache are
isolated. Expected definitions name exact files and zero-width file-start ranges;
hover assertions use authored documentation strings. No real repository is read
or changed by the tests.

## TDD evidence

Each new failing behavior was tested over LSP before its minimal production fix.
Commands were run with `DEVELOPER_DIR=/nonexistent` on macOS.

1. **Root-installed Collection definition and hover**
   - RED: `zig build selected-venv-e2e` → exit 1, `0/1 passed`,
     `Expected definition .venv/ansible_collections/fixture/root/galaxy.yml, got null`.
   - GREEN: same command with `--summary all` → exit 0, `1/1 tests passed`.
2. **Windows and all POSIX site-packages coexist with the root**
   - RED: `zig build selected-venv-e2e` → exit 1, `1/2 passed`,
     `Expected definition .venv/lib/python3.12/site-packages/ansible_collections/fixture/posix/galaxy.yml, got null`.
   - GREEN: same command with `--summary all` → exit 0, `2/2 tests passed`.
3. **Preserved contracts**, characterization (not a new defect): exactly selected
   environment, empty disable, absolute paths, CLI override, root before
   site-packages, adjacent before configured, configured before selected, and
   environment before config → exit 0, `3/3 tests passed` before the fixture
   portability split, `4/4 tests passed` afterward.
4. **Root-installed module definition and hover**
   - RED: `zig build selected-venv-e2e` → exit 1, `4/5 passed`,
     `Expected definition .venv/ansible_collections/fixture/root/plugins/modules/probe.py, got null`.
   - GREEN: same command with `--summary all` → exit 0, `5/5 tests passed`.
5. **Module discovery for completion**
   - RED: `zig build selected-venv-e2e` → exit 1, `5/6 passed`,
     `MissingSelectedVenvModuleCompletion`.
   - GREEN: same command with `--summary all` → exit 0, `6/6 tests passed`.
6. **Schema-aware module option semantic tokens**
   - RED: `zig build selected-venv-e2e` → exit 1, `6/7 passed`,
     expected the advertised `method` token index 0, found `property` index 3.
   - GREEN: same command with `--summary all` → exit 0, `7/7 tests passed`.
7. **Completion resolve preserves per-file context**
   - RED: `zig build selected-venv-e2e` → exit 1, `7/8 passed`,
     `MissingResolvedDocumentation`.
   - GREEN: same command with `--summary all` → exit 0, `8/8 tests passed`.
8. **Safety checks**, already green after contextual isolation: two opened
   Workspaces with the same FQCN and different module files/docs; change selection,
   disable it, and change back without reusing stale docs; two nearest config
   files with distinct paths plus explicit config precedence. The final suite
   passes `10/10` tests over LSP at this stage.
9. **Relative environment path meaning survives child cwd changes**
   - RED: `zig build selected-venv-e2e` → exit 1, `10/11 passed`,
     root module definition returned `null` from a nested source directory.
   - GREEN: same command with `--summary all` → exit 0, `11/11 tests passed`.

## Direct `ansible_collections` path normalization follow-up

10. **Absolute direct environment path, automatic venv selection disabled**
    - RED: `DEVELOPER_DIR=/nonexistent zig build selected-venv-e2e` → exit 1,
      `11/12 passed`. Expected
      `.venv/ansible_collections/fixture/root/galaxy.yml`; zals incorrectly
      returned `adjacent/collections/ansible_collections/fixture/root/galaxy.yml`
      from Workspace fallback.
    - Minimal common-boundary normalization, then GREEN: same command with
      `--summary all` → exit 0, `12/12 tests passed`. Hover compares the complete
      authored root Collection README, not a generic Collection header.
11. **Relative direct environment path preserves cwd meaning**
    - RED: same command → exit 1, `12/13 passed`. Navigation found the intended
      metadata but returned the invalid relative URI
      `file://test/fixtures/selected-venv/.venv/ansible_collections/fixture/root/galaxy.yml`
      instead of its absolute file URI.
    - Make effective roots absolute against the server cwd, then GREEN:
      same command with `--summary all` → exit 0, `13/13 tests passed`.
      The same black-box test also verifies the Collection role definition and
      module definition/hover from a nested source directory.
12. **Characterizations**, already green: a nearest config path naming
    `../../.venv/ansible_collections`, complete Collection hover, role and module
    definitions; mixed direct/parent aliases preserve first-path precedence
    when reversed and do not duplicate module completion entries. An intentionally
    unresolved runtime redirect verifies filesystem discovery independently of
    the ansible-doc catalog. Result: `15/15 tests passed`.

The direct-config fixture is `test/fixtures/selected-venv/configs/direct/`, with
an explicit Collection role under `.venv/ansible_collections/fixture/root/roles/probe/`
and redirect routes in that Collection's `meta/runtime.yml`. The root Collection
metadata includes Ansible's mandatory `authors` and `readme` fields. A direct
host `ansible-doc -l --json -t module` check with only the root fixture path
confirmed `fixture.root.probe` is in the catalog and `fixture.root.unresolved_probe`
is not. Expected locations and documentation are authored in the test; no
answers are harvested from zals.

Follow-up verification: `DEVELOPER_DIR=/nonexistent zig build test e2e --summary all`
passed `227/227` tests on the child branch (211 unit, existing navigation's 265
cases, and all 15 selected-venv LSP tests). `make smoke` and `git diff --check`
also passed.

Module tests execute the host's `ansible-doc` using only checked-in Python
`DOCUMENTATION` strings; they do not install dependencies, activate a venv, or
execute the fixture modules. Ansible is a prerequisite, as for the server.
The existing navigation-only E2E runner still requires no Ansible execution.

Final broader checks: `DEVELOPER_DIR=/nonexistent zig build test e2e --summary all`
passed 211 unit tests, the existing navigation suite's 265 cases, and this suite;
`make smoke` passed the references, code actions, role navigation, and Workspace
smoke tests. `git diff --check` and formatting checks passed.

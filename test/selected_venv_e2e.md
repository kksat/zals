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

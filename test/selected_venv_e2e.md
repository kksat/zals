# Selected virtual environment suite

Run: `make e2e SUITE=selected-venv-e2e` (part of `make e2e`). Requires
`ansible` and `ansible-doc` from `ansible-core` on PATH; CI uses Python 3.12
and `ansible-core==2.19.2`.

## Seam and fixtures

A Zig black-box stdio runner using `test/e2e/client.zig` and `anchor.zig`; it
starts the built `zig-out/bin/zals` and waits for Workspace indexing. Static
fixtures live in `test/fixtures/selected-venv/`; the `.venv` and `other-env`
directories model installation layouts, not runnable Python environments. HOME
and XDG cache are isolated. Expected definitions name exact files and zero-width
file-start ranges; hover assertions use authored documentation strings. No real
repository is read or changed.

POSIX and Windows layouts use separate selected environments: `Lib` and `lib`
cannot coexist reliably in one checked-in directory on case-insensitive macOS.
The direct-config fixture is `test/fixtures/selected-venv/configs/direct/`, with
an explicit Collection role under `.venv/ansible_collections/fixture/root/roles/probe/`
and redirect routes in that Collection's `meta/runtime.yml`. Root Collection
metadata includes Ansible's mandatory `authors` and `readme` fields.

Module tests run the host's `ansible-doc` against checked-in Python
`DOCUMENTATION` strings only; they install nothing, activate no venv, and
execute no fixture module.

## Covered behavior

- **Root-installed Collections and modules**: definition and hover for
  `.venv/ansible_collections/...` directly under the venv root.
- **Layouts**: Windows `Lib/site-packages` and all POSIX `lib/pythonX.Y/site-packages`
  layouts coexist with the root; the root wins over site-packages.
- **Precedence**: exactly the selected environment; empty value disables it;
  absolute paths; CLI override; adjacent before configured, configured before
  selected, environment before config.
- **Module discovery**: completion lists selected-venv modules; completion
  resolve keeps per-file context; schema-aware module options get the `method`
  semantic token.
- **Isolation**: two opened Workspaces with the same FQCN resolve to their own
  module files/docs; changing, disabling, and restoring the selection never
  reuses stale docs; two nearest config files keep distinct paths.
- **Relative paths**: relative environment paths keep their meaning when the
  child process runs from a nested source directory, and resolve against the
  server cwd into absolute file URIs.
- **Direct `ansible_collections` paths**: a configured path ending in
  `ansible_collections` is normalized to its parent, as Ansible does, with
  automatic venv selection disabled; mixed direct/parent aliases keep
  first-path precedence without duplicate completions. An unresolved runtime
  redirect checks filesystem discovery independently of the `ansible-doc`
  catalog.

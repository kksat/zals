# Collections installed in a selected virtual environment

Select exactly one environment with `ansible.python.venvPath` (default `.venv`)
or `zals --venv <path>` (takes precedence). Relative paths are relative to the
Workspace root; absolute paths are supported. Set the selection to `""` to
disable environment collection lookup. zals does not select `VIRTUAL_ENV` or
search other environments.

For Collection and Role navigation, module definition/hover and option docs,
module completion/resolve, and semantic tokens, these installations are supported:

```text
<venv>/ansible_collections/<namespace>/<collection>/
<venv>/Lib/site-packages/ansible_collections/<namespace>/<collection>/
<venv>/lib/python*/site-packages/ansible_collections/<namespace>/<collection>/
```

Search order remains: the source file's adjacent `collections/` directory,
`ANSIBLE_COLLECTIONS_PATH` (legacy `ANSIBLE_COLLECTIONS_PATHS`) or the nearest
`ansible.cfg` collections path or dumped defaults, the selected environment's
root and site-packages, then Workspace collection directories. An explicit
configured path still wins over the selected environment. Collections installed
in an environment are dependencies, not Workspace symbols.

Module documentation is read using the `ansible-doc` on the server's PATH, with
the effective per-file collections paths and the source directory supplied to
that child process. Selecting a venv controls collection discovery; it does not
activate its Python interpreter. `ansible-doc` and `ansible` are still required
for module docs and builtin discovery. Collection modules can be discovered on
disk even when `ansible` is unavailable.

Libraries are isolated per ordered collections paths and source directory, so
the same module FQCN in two Workspaces can have different definitions and docs.
Changing the selected environment or a configured path selects a different
library. Contextual docs use an in-memory cache, not the process-wide disk cache;
a restart still requires loading their catalog and lazily fetching full docs.
The server never changes its own environment, other Workspaces' settings, or the
selected environment's files. Restart after installing or replacing collections
at an unchanged path (live installation invalidation is not part of this change).

No Galaxy installation or writes to the selected environment are needed.
See [ADR-0037](adr/0037-selected-venv-collections.md).

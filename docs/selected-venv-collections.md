# Collections installed in a selected virtual environment

Select exactly one environment with `ansible.python.venvPath` (default `.venv`)
or `zals --venv <path>` (takes precedence). Relative paths are relative to the
Workspace root; absolute paths are supported. Set the selection to `""` to
disable environment collection lookup. zals does not select `VIRTUAL_ENV` or
search other environments.

For Collection and Role navigation, these installations are supported together:

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

No Galaxy installation or writes to the selected environment are needed.
See [ADR-0037](adr/0037-selected-venv-collections.md).

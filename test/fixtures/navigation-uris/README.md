# Navigation URI fixture

`workspace/` is the only indexed Workspace, isolated by the checked-in
`fixture-workspace-root` marker. `role-path/` and `collection-path/` are
installed dependencies outside it. Their unique names cannot resolve through
adjacent roles or editor fallback.

The stdio server starts with this directory as its cwd and explicit relative
`ANSIBLE_ROLES_PATH=role-path` and
`ANSIBLE_COLLECTIONS_PATH=collection-path`, plus an isolated HOME/cache and
disabled virtual-environment lookup. An absolute-path control uses the same
files. `escaped %20#roles/` adds a separate installed role in a path with a
space, literal `%20`, and hash; its `import_tasks` exercises navigation after
opening the exact escaped URI returned by the server. Tests open unchanged
fixture files, wait for the index, and assert complete definition/implementation
locations, explicit escaped URI suffixes, and exact existing targets.

Run from the repository root:

```sh
make build
DEVELOPER_DIR=/nonexistent zig test test/navigation_uris_e2e.zig --test-filter 'stdio navigation'
```

`DEVELOPER_DIR` is the macOS SDK workaround from ADR-0019; other platforms may
omit it. The root suite imports only test-side LSP transport/anchor helpers,
never server providers or URI-conversion code.

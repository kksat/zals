# Standalone Role repository fixtures

These synthetic fixtures model repositories such as RHEL10-CIS: each repository
root is one Role, not a playbook project containing `roles/<name>/` and not a
Collection. They are small authored examples, not copies of an external project.

- `hardening-yml/` has `meta/main.yml`, split `defaults/main/*.yml`, and
  `vars/main.yml`.
- `hardening-yaml/` has `meta/main.yaml`, split `defaults/main/*.yaml`, and
  nested `vars/main/nested/settings.yaml`.

Both contain argument specs, nested tasks, handlers, and an `etc/` Jinja template.
Each has its own `fixture-workspace-root` marker (a trackable substitute for
`.git`), and neither requires `ansible.cfg`, role paths, or installed collections.

`hardening_config.port` is `80` in defaults and `8080` in vars, with a schema-only
argument-spec declaration. Navigation should rank vars before defaults before
the schema, and implementation should omit the schema. Task, handler, and
Jinja reads all share complete Workspace reference groups with their bindings.
`os_check` and `audit_enabled` come from separate defaults files and are read in
bare `when` expressions. `tasks/nested/check.*` imports `shared.*`, which exists
only at `tasks/shared.*`, requiring Role-relative resolution rather than a
source-directory or Workspace-root match.

Run `make e2e SUITE=standalone-role-e2e`. Expected locations are explicitly written
in `test/standalone_role_e2e.zig`; marker helpers calculate coordinates only.
The test reads unchanged fixtures, waits for indexing, and uses the real stdio
LSP interface. `make e2e` and the aggregate CI E2E job also include this suite.

# Rollout navigation fixture

A deliberately small Ansible project with a dense relationship graph. The
`example.rollout` collection deploys an application through preflight,
snapshot, deployment, migration, verification, notification, and rollback.
Playbooks call those roles directly and through includes; roles depend on one
another and share variables and task files.

`example.shared` is a second Workspace collection. `fixture.metrics` lives in
`test/dependencies/ansible_collections/` outside this Workspace but on the
configured collections path. `fixture.missing` is deliberately absent;
`fixture.notes` is a README-only path stub for definition fallback, not a
Galaxy-installed collection.
`roles/deploy` deliberately collides with `example.rollout.roles/deploy`; the
playbooks select different targets according to their collection context.
`playbooks/collection-overrides.yml` contrasts play, task, and block
collection declarations for the two `notify` Roles.
`ops/roles/check` and `services/roles/check` exercise ambiguous editor fallback.
The `metadata_only` Role deliberately has metadata but no main task file.

`fixture.inputs` and `fixture.other` have same-named receiver roles and
same-named input variables. `playbooks/role-inputs.yml` exercises parameter
navigation from roles entries and include/import tasks, selected argument-spec
entry points, per-task collection context, and unresolved/schema-only negatives.
`roles/yaml_receiver` uses `meta/main.yaml` and YAML defaults/main tasks.
Their root-variable references remain Workspace-wide, while passed-key
contracts and implementations stay specific to the called Role.

Files under `negative/` contain intentional non-matches or missing targets;
positive playbooks remain structurally valid Ansible. The marker file is
`fixture-workspace-root` because Git cannot check in a nested `.git` file.

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
`playbooks/field-inputs.yml` adds nested parameter paths, list elements,
intermediate keys, quoted YAML keys, and selected entry-point contracts.
Same-leaf fields under another root and another collection deliberately share
Workspace-wide references but are excluded from callee/path implementations.
Schema-only, unresolved, nonmatching-path, and ordinary task-vars cases are
negative controls. Buffer edits are tested separately without changing disk.

`roles/field_nav` describes the same field in a list default, a quoted key
under an unrelated vars root, and a nested argument-spec option. Two differently
named receivers deliberately join that field-name group without loop tracing.
Schema-only and unbound members, a same-named root variable, and metadata keys
exercise the separate field/root groups and all four navigation actions. Static
quoted subscripts share the dot-read group; a called same-named member is a
non-match for every action.

`playbooks/metadata-names.yml` reads variables and fields spelled like keys in
files that are not Variable files: `galaxy.yml`, `requirements.yml`,
`execution-environment.yml`, collection `meta/runtime.yml`,
`docker-compose.yml`, `molecule/default/molecule.yml`, `mkdocs.yml`,
`changelogs/changelog.yaml`, `inventory.yml`, and the preflight Role's
`templates/compose.yml.j2`. None of them binds these names. Its loads target
`playbooks/settings/release-metadata.yml` (`vars_files`) and
`runtime-metadata.yml` (`include_vars`), which lie outside any `vars/`
directory and bind only because they are loaded. `group_vars/all.yml` and
`host_vars/localhost.yml` bind without a load.
`playbooks/settings/receiver-values.yml` is deliberately unloaded on disk, so
its `region_name` joins no field group; buffer scenarios load it from the
receiver Role. That Role's `templates/settings.yml.j2` spells the same
`input_config.endpoint.region_name` path and must never be a callee binding.

Files under `negative/` contain intentional non-matches or missing targets;
positive playbooks remain structurally valid Ansible. The marker file is
`fixture-workspace-root` because Git cannot check in a nested `.git` file.

# Native CEL Rule Authoring and Diagnostics Migration

Zals evaluates native Ansible diagnostics in process using Common Expression
Language (CEL) via the `zig-cel` package dependency (commit `445a967`). Built-in and custom
rules use the same one-rule-per-file `.cel` interface.

## Rule file format

Each `.cel` file contains a single `zals.Rule{ ... }` declaration:

```cel
zals.Rule{
  id: "custom/no-raw-curl",
  target: "task",
  severity: "warning",
  field: "action",
  schema_version: 1,
  condition: node.short_action == "shell" && node.command.basename == "curl",
  message: "Use ansible.builtin.uri instead of shelling out to curl at " +
    location.path + ":" + string(location.line)
}
```

- `id`, `target`, `severity`, optional `field`, and optional `schema_version`
  must be CEL literals (constant-foldable expressions are rejected).
- `condition` must evaluate to `bool` (`true` reports a diagnostic; `false`
  skips `message` evaluation).
- `message` must evaluate to `string`.
- See [`docs/cel-rule-environment.json`](cel-rule-environment.json) for the
  complete machine-readable v1 environment schema, bindings, target fields,
  supported functions, and resource limits.
- For editor completion, hover docs, go-to-definition, and static type checking
  with [`cells`](https://github.com/stefanvanburen/cells), Zals ships a
  `cel-go` environment config and compiled protobuf descriptor set under
  `docs/cel/`:
  - `docs/cel/cel.yaml` — declares `node`, `location`, `document`, `context`,
    `metadata`, and `options`.
  - `docs/cel/zals.proto` — documented protobuf definitions for `zals.Rule`,
    `zals.Node`, per-target messages (`zals.Task`, `zals.Play`, `zals.RoleRef`,
    `zals.VarDef`, `zals.RoleMeta`, `zals.GalaxyMeta`, `zals.ArgumentSpecEntry`,
    `zals.ArgumentSpec`, `zals.ParseIssue`), `zals.Location`, `zals.Document`,
    `zals.Metadata`, `zals.TypedValue`, and `zals.CommandInfo`.
  - `docs/cel/zals.binpb` — compiled `FileDescriptorSet` with source comments
    (`protoc --include_imports --include_source_info -I docs/cel --descriptor_set_out=docs/cel/zals.binpb docs/cel/zals.proto`).
  - CLI check: `cells check --config=docs/cel/cel.yaml --descriptor-set=docs/cel/zals.binpb path/to/rule.cel`.
  - To narrow `node` strictly to one target in a folder of rules (for example,
    task-only rules), drop a local `cel.yaml` in that folder setting
    `node`'s `type_name` to `zals.Task` (or `zals.Play`, `zals.RoleMeta`, etc.).
- Rule targets for `meta/argument_specs.yml` are `argument_spec_entry` (one
  node per role entry point) and `argument_spec` (one node per option, with
  nested suboptions flattened into dotted `path` values such as `conf.mode`);
  `document.has_argument_specs` reports whether the file defines an
  `argument_specs` mapping with at least one entry point.

## Configuration and migration notes

- **Provider defaults:** Native CEL (`ansible.validation.cel.enabled`) and
  native schema (`ansible.validation.schema.enabled`) diagnostics are enabled
  by default. External diagnostics (`ansible.validation.lint.enabled`) now
  default to `false`.
- **No disabled-provider fallback:** When `ansible.validation.lint.enabled` is
  `false`, Zals runs neither `ansible-lint` nor `ansible-playbook --syntax-check`.
- **No cross-source deduplication:** When multiple providers are enabled and
  report the same issue, findings from each source (`zals-cel`, `ansible-schema`,
  `ansible-lint`) remain independently visible.
- **Workspace-wide scope and opt-in built-ins:** Native CEL diagnostics cover
  unopened eligible Workspace files (`.yml`/`.yaml`) as well as open buffers,
  and enable every implemented built-in rule by default (including upstream
  opt-in rules such as `only-builtins`).
- **LSP settings only:** Native CEL rules do not read `.ansible-lint`
  configuration files and do not honor `tags: [skip_ansible_lint]`. Use LSP
  settings (`ansible.validation.cel.disabledRules`, `ansible.validation.cel.rules`)
  and source-level `# noqa` comments (`# noqa` or `# noqa: <rule-id>`).
- **Custom rules and trust:** Global rule files use explicit absolute paths in
  `ansible.validation.cel.globalRuleFiles`. Workspace rule files use explicit
  relative paths in `ansible.validation.cel.workspaceRuleFiles` and require
  explicit opt-in via `ansible.validation.cel.allowWorkspaceRules: true`.
  Invalid saved custom rules deactivate individually, clear their previous
  findings, and report diagnostics against the `.cel` file without stopping
  other rules.

const m = @import("../model.zig");

const rollout = "playbooks/rollout.yml";
const common = "playbooks/tasks/common.yml";
const release = "playbooks/vars/release.yml";
const runtime = "playbooks/vars/runtime.yml";
const nonstandard = "negative/nonstandard-paths.yml";
const preflight = "ansible_collections/example/rollout/roles/preflight/tasks/main.yml";
const snapshot_tasks = "ansible_collections/example/rollout/roles/snapshot/tasks/main.yml";
const snapshot_handler = "ansible_collections/example/rollout/roles/snapshot/handlers/main.yml";
const snapshot_details = "ansible_collections/example/rollout/roles/snapshot/tasks/details.yml";
const migrate = "ansible_collections/example/rollout/roles/migrate/tasks/main.yml";
const rollback = "ansible_collections/example/rollout/roles/rollback/tasks/main.yml";
const negative = "negative/files.yml";

// Every site naming this same target, including both include/import modules
// and both scalar/map/key-value argument spellings. References are a multiset.
const common_refs: []const m.ExpectedLocation = &.{
    m.span(rollout, "ansible.builtin.include_tasks: <tasks/common.yml>"),
    m.span(rollout, "ansible.builtin.import_tasks: file=<tasks/common.yml>"),
    m.span(rollout, "ansible.builtin.include_tasks:\n        file: <tasks/common.yml>"),
    m.span(rollout, "ansible.builtin.import_tasks: <tasks/common.yml>"),
};
const release_refs: []const m.ExpectedLocation = &.{
    m.span(rollout, "vars_files:\n    - <vars/release.yml>"),
    m.span(nonstandard, "vars_files: <playbooks/vars/release.yml>"),
};
const runtime_refs: []const m.ExpectedLocation = &.{
    m.span(rollout, "ansible.builtin.include_vars: <vars/runtime.yml>"),
    m.span(rollout, "ansible.builtin.include_vars: file=<vars/runtime.yml>"),
    m.span(nonstandard, "ansible.builtin.include_vars: file=<playbooks/vars/runtime.yml>"),
};
const details_refs: []const m.ExpectedLocation = &.{
    m.span(snapshot_tasks, "file: <details.yml>"),
    m.span(snapshot_handler, "ansible.builtin.import_tasks: <details.yml>"),
};

pub const all = [_]m.Case{
    .{
        .name = "file/include_tasks scalar: definition opens a playbook-adjacent task file",
        .method = .definition,
        .from = m.cursor(rollout, "ansible.builtin.include_tasks: <tasks/common.yml>"),
        .expected = &.{m.fileStart(common)},
    },
    .{
        .name = "file/include_tasks scalar: references include all spellings of this task target",
        .method = .references,
        .from = m.cursor(rollout, "ansible.builtin.include_tasks: <tasks/common.yml>"),
        .expected = common_refs,
    },
    .{
        .name = "file/import_tasks file= argument: definition opens the same target",
        .method = .definition,
        .from = m.cursor(rollout, "ansible.builtin.import_tasks: file=<tasks/common.yml>"),
        .expected = &.{m.fileStart(common)},
    },
    .{
        .name = "file/import_tasks file= argument: references include includes and imports",
        .method = .references,
        .from = m.cursor(rollout, "ansible.builtin.import_tasks: file=<tasks/common.yml>"),
        .expected = common_refs,
    },
    .{
        .name = "file/include_tasks file map: definition opens the same target",
        .method = .definition,
        .from = m.cursor(rollout, "ansible.builtin.include_tasks:\n        file: <tasks/common.yml>"),
        .expected = &.{m.fileStart(common)},
    },
    .{
        .name = "file/include_tasks file map: references include the full target group",
        .method = .references,
        .from = m.cursor(rollout, "ansible.builtin.include_tasks:\n        file: <tasks/common.yml>"),
        .expected = common_refs,
    },
    .{
        .name = "file/import_tasks scalar: definition opens the same target",
        .method = .definition,
        .from = m.cursor(rollout, "ansible.builtin.import_tasks: <tasks/common.yml>"),
        .expected = &.{m.fileStart(common)},
    },
    .{
        .name = "file/import_tasks scalar: references include the full target group",
        .method = .references,
        .from = m.cursor(rollout, "ansible.builtin.import_tasks: <tasks/common.yml>"),
        .expected = common_refs,
    },
    .{
        .name = "file/vars_files list entry: definition opens the vars file",
        .method = .definition,
        .from = m.cursor(rollout, "vars_files:\n    - <vars/release.yml>"),
        .expected = &.{m.fileStart(release)},
    },
    .{
        .name = "file/vars_files list entry: references include scalar-path form",
        .method = .references,
        .from = m.cursor(rollout, "vars_files:\n    - <vars/release.yml>"),
        .expected = release_refs,
    },
    .{
        .name = "file/vars_files scalar: definition finds the Workspace-root path",
        .method = .definition,
        .from = m.cursor(nonstandard, "vars_files: <playbooks/vars/release.yml>"),
        .expected = &.{m.fileStart(release)},
    },
    .{
        .name = "file/vars_files scalar: references include list entries by resolved path",
        .method = .references,
        .from = m.cursor(nonstandard, "vars_files: <playbooks/vars/release.yml>"),
        .expected = release_refs,
    },
    .{
        .name = "file/include_vars scalar: definition opens runtime vars",
        .method = .definition,
        .from = m.cursor(rollout, "ansible.builtin.include_vars: <vars/runtime.yml>"),
        .expected = &.{m.fileStart(runtime)},
    },
    .{
        .name = "file/include_vars scalar: references include both key-value sites",
        .method = .references,
        .from = m.cursor(rollout, "ansible.builtin.include_vars: <vars/runtime.yml>"),
        .expected = runtime_refs,
    },
    .{
        .name = "file/include_vars file= argument: definition opens runtime vars",
        .method = .definition,
        .from = m.cursor(rollout, "ansible.builtin.include_vars: file=<vars/runtime.yml>"),
        .expected = &.{m.fileStart(runtime)},
    },
    .{
        .name = "file/include_vars file= argument: references include all runtime vars paths",
        .method = .references,
        .from = m.cursor(rollout, "ansible.builtin.include_vars: file=<vars/runtime.yml>"),
        .expected = runtime_refs,
    },
    .{
        .name = "file/include_vars root-relative file= argument: definition opens runtime vars",
        .method = .definition,
        .from = m.cursor(nonstandard, "ansible.builtin.include_vars: file=<playbooks/vars/runtime.yml>"),
        .expected = &.{m.fileStart(runtime)},
    },
    .{
        .name = "file/include_vars root-relative file= argument: references join local paths",
        .method = .references,
        .from = m.cursor(nonstandard, "ansible.builtin.include_vars: file=<playbooks/vars/runtime.yml>"),
        .expected = runtime_refs,
    },
    .{
        .name = "file/role include_tasks scalar: definition opens same-role task file",
        .method = .definition,
        .from = m.cursor(preflight, "ansible.builtin.include_tasks: <steps.yml>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/preflight/tasks/steps.yml")},
    },
    .{
        .name = "file/role include_tasks scalar: references stay on this resolved file",
        .method = .references,
        .from = m.cursor(preflight, "ansible.builtin.include_tasks: <steps.yml>"),
        .expected = &.{m.span(preflight, "ansible.builtin.include_tasks: <steps.yml>")},
    },
    .{
        .name = "file/role include_vars file map: definition falls back to the role vars directory",
        .method = .definition,
        .from = m.cursor(preflight, "file: <overrides.yml>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/preflight/vars/overrides.yml")},
    },
    .{
        .name = "file/role include_vars file map: references name only this role vars file",
        .method = .references,
        .from = m.cursor(preflight, "file: <overrides.yml>"),
        .expected = &.{m.span(preflight, "file: <overrides.yml>")},
    },
    .{
        .name = "file/role include_tasks file= argument: definition opens migrate tasks",
        .method = .definition,
        .from = m.cursor(migrate, "ansible.builtin.include_tasks: file=<migrate-data.yml>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/migrate/tasks/migrate-data.yml")},
    },
    .{
        .name = "file/role include_tasks file= argument: references include this site",
        .method = .references,
        .from = m.cursor(migrate, "ansible.builtin.include_tasks: file=<migrate-data.yml>"),
        .expected = &.{m.span(migrate, "ansible.builtin.include_tasks: file=<migrate-data.yml>")},
    },
    .{
        .name = "file/role import_tasks file map: definition opens snapshot details",
        .method = .definition,
        .from = m.cursor(snapshot_tasks, "file: <details.yml>"),
        .expected = &.{m.fileStart(snapshot_details)},
    },
    .{
        .name = "file/role import_tasks file map: references include the handler fallback",
        .method = .references,
        .from = m.cursor(snapshot_tasks, "file: <details.yml>"),
        .expected = details_refs,
    },
    .{
        .name = "file/handler import_tasks scalar: definition falls back to role tasks directory",
        .method = .definition,
        .from = m.cursor(snapshot_handler, "ansible.builtin.import_tasks: <details.yml>"),
        .expected = &.{m.fileStart(snapshot_details)},
    },
    .{
        .name = "file/handler import_tasks scalar: references include the task-side import",
        .method = .references,
        .from = m.cursor(snapshot_handler, "ansible.builtin.import_tasks: <details.yml>"),
        .expected = details_refs,
    },
    .{
        .name = "file/rollback include_tasks: definition opens recovery tasks",
        .method = .definition,
        .from = m.cursor(rollback, "ansible.builtin.include_tasks: <recover.yml>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/rollback/tasks/recover.yml")},
    },
    .{
        .name = "file/rollback include_tasks: references name this one target",
        .method = .references,
        .from = m.cursor(rollback, "ansible.builtin.include_tasks: <recover.yml>"),
        .expected = &.{m.span(rollback, "ansible.builtin.include_tasks: <recover.yml>")},
    },
    .{
        .name = "file/missing relative task target: definition has no location",
        .method = .definition,
        .from = m.cursor(negative, "ansible.builtin.include_tasks: <no-such-file.yml>"),
        .expected = &.{},
    },
    .{
        .name = "file/missing relative task target: references still find this site",
        .method = .references,
        .from = m.cursor(negative, "ansible.builtin.include_tasks: <no-such-file.yml>"),
        .expected = &.{m.span(negative, "ansible.builtin.include_tasks: <no-such-file.yml>")},
    },
    .{
        .name = "file/missing absolute task target: definition has no location",
        .method = .definition,
        .from = m.cursor(negative, "ansible.builtin.include_tasks: </__zals_e2e_missing__/absent.yml>"),
        .expected = &.{},
    },
    .{
        .name = "file/missing absolute task target: references still find this site",
        .method = .references,
        .from = m.cursor(negative, "ansible.builtin.include_tasks: </__zals_e2e_missing__/absent.yml>"),
        .expected = &.{m.span(negative, "ansible.builtin.include_tasks: </__zals_e2e_missing__/absent.yml>")},
    },
    .{
        .name = "file/computed include_tasks path: not a static file reference for definition",
        .method = .definition,
        .from = m.cursor(negative, "ansible.builtin.include_tasks: \"<{{ file_choice }}>\""),
        .expected = &.{},
    },
    .{
        .name = "file/computed include_tasks path: not a static file reference for references",
        .method = .references,
        .from = m.cursor(negative, "ansible.builtin.include_tasks: \"<{{ file_choice }}>\""),
        .expected = &.{},
    },
    .{
        .name = "file/computed include_vars map path: not a static file reference",
        .method = .definition,
        .from = m.cursor(negative, "file: \"<{{ file_choice }}>\""),
        .expected = &.{},
    },
    .{
        .name = "file/template src is outside the include/import file-navigation grammar",
        .method = .definition,
        .from = m.cursor(preflight, "src: <notice.j2>"),
        .expected = &.{},
    },
};

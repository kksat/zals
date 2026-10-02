const m = @import("../model.zig");

// Complete Workspace reference sets by resolved role directory. The same
// spelling may belong to another role; Installed roles have Workspace sites
// but no references indexed from their own task files.
const preflight_refs = &[_]m.ExpectedLocation{
    m.span("playbooks/rollout.yml", "- role: <example.rollout.preflight>"),
};
const rollout_deploy_refs = &[_]m.ExpectedLocation{
    m.span("playbooks/rollout.yml", "- role: <deploy>"),
};
const project_deploy_refs = &[_]m.ExpectedLocation{
    m.span("playbooks/project.yml", "    - <deploy>"),
    m.span("playbooks/project.yml", "        name: <deploy>"),
};
const verify_refs = &[_]m.ExpectedLocation{
    m.span("playbooks/rollout.yml", "    - <example.rollout.verify>"),
    m.span("ansible_collections/example/rollout/roles/deploy/tasks/main.yml", "    name: <verify>"),
    m.span("requirements.yml", "  - <example.rollout.verify>"),
};
const snapshot_refs = &[_]m.ExpectedLocation{
    m.span("playbooks/rollout.yml", "import_role: \"name=<example.rollout.snapshot>\""),
    m.span("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - <example.rollout.snapshot>"),
    m.span("ansible_collections/example/rollout/roles/rollback/tasks/main.yml", "    name: <example.rollout.snapshot>"),
    m.span("playbooks/rollback.yml", "        name: <example.rollout.snapshot>"),
    m.span("requirements.yml", "  - src: <example.rollout.snapshot>"),
};
const rollout_notify_refs = &[_]m.ExpectedLocation{
    m.span("playbooks/rollout.yml", "include_role: name=<notify>"),
    m.span("negative/nonstandard-paths.yml", "    - name: <example.rollout.notify>"),
    m.span("playbooks/collection-overrides.yml", "Notify with the play collection\n      ansible.builtin.include_role:\n        name: <notify>"),
};
const shared_notify_refs = &[_]m.ExpectedLocation{
    m.span("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - role: <example.shared.notify>"),
    m.span("ansible_collections/example/rollout/roles/notify/tasks/main.yml", "    name: <example.shared.notify>"),
    m.span("playbooks/rollback.yml", "        name: <example.shared.notify>"),
    m.span("playbooks/collection-overrides.yml", "Notify with a task collection override\n      collections:\n        - example.shared\n      ansible.builtin.include_role:\n        name: <notify>"),
    m.span("playbooks/collection-overrides.yml", "- name: Import the shared notifier\n          ansible.builtin.import_role:\n            name: <notify>"),
};
const installed_report_refs = &[_]m.ExpectedLocation{
    m.span("playbooks/dependency.yml", "    - <fixture.metrics.report>"),
    m.span("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - name: <fixture.metrics.report>"),
    m.span("ansible_collections/example/rollout/roles/notify/tasks/main.yml", "    name: <fixture.metrics.report>"),
    m.span("playbooks/rollback.yml", "        name: <fixture.metrics.report>"),
};
const check_fallback_refs = &[_]m.ExpectedLocation{
    m.span("playbooks/ambiguous.yml", "    - <check>"),
    m.span("ops/playbooks/check.yml", "    - <check>"),
    m.span("services/playbooks/check.yml", "    - <check>"),
};
const ops_check_refs = &[_]m.ExpectedLocation{
    m.span("playbooks/ambiguous.yml", "    - <check>"),
    m.span("ops/playbooks/check.yml", "    - <check>"),
};
const services_check_refs = &[_]m.ExpectedLocation{
    m.span("playbooks/ambiguous.yml", "    - <check>"),
    m.span("services/playbooks/check.yml", "    - <check>"),
};

pub const all = [_]m.Case{
    .{
        .name = "role/roles map FQCN: definition prefers argument specs over metadata and tasks",
        .method = .definition,
        .from = m.cursor("playbooks/rollout.yml", "- role: <example.rollout.preflight>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/preflight/meta/argument_specs.yml")},
    },
    .{
        .name = "role/roles map FQCN: implementation opens main tasks",
        .method = .implementation,
        .from = m.cursor("playbooks/rollout.yml", "- role: <example.rollout.preflight>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/preflight/tasks/main.yml")},
    },
    .{
        .name = "role/roles map FQCN: references include the invocation",
        .method = .references,
        .from = m.cursor("playbooks/rollout.yml", "- role: <example.rollout.preflight>"),
        .expected = preflight_refs,
    },
    .{
        .name = "role/roles map short name: declared collection wins over project role",
        .method = .definition,
        .from = m.cursor("playbooks/rollout.yml", "- role: <deploy>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/deploy/tasks/main.yml")},
    },
    .{
        .name = "role/roles map short name: implementation selects collection role",
        .method = .implementation,
        .from = m.cursor("playbooks/rollout.yml", "- role: <deploy>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/deploy/tasks/main.yml")},
    },
    .{
        .name = "role/roles map short name: references exclude same-named project role",
        .method = .references,
        .from = m.cursor("playbooks/rollout.yml", "- role: <deploy>"),
        .expected = rollout_deploy_refs,
    },
    .{
        .name = "role/roles string short name: project definition without collection declaration",
        .method = .definition,
        .from = m.cursor("playbooks/project.yml", "    - <deploy>"),
        .expected = &.{m.fileStart("roles/deploy/tasks/main.yml")},
    },
    .{
        .name = "role/roles string short name: project implementation",
        .method = .implementation,
        .from = m.cursor("playbooks/project.yml", "    - <deploy>"),
        .expected = &.{m.fileStart("roles/deploy/tasks/main.yml")},
    },
    .{
        .name = "role/roles string short name: project refs exclude collection deploy",
        .method = .references,
        .from = m.cursor("playbooks/project.yml", "    - <deploy>"),
        .expected = project_deploy_refs,
    },
    .{
        .name = "role/roles name map FQCN: definition resolves collection role",
        .method = .definition,
        .from = m.cursor("negative/nonstandard-paths.yml", "    - name: <example.rollout.notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/roles name map FQCN: implementation opens main tasks",
        .method = .implementation,
        .from = m.cursor("negative/nonstandard-paths.yml", "    - name: <example.rollout.notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/roles name map FQCN: references join short invocation",
        .method = .references,
        .from = m.cursor("negative/nonstandard-paths.yml", "    - name: <example.rollout.notify>"),
        .expected = rollout_notify_refs,
    },
    .{
        .name = "role/include_role map: project deploy definition",
        .method = .definition,
        .from = m.cursor("playbooks/project.yml", "        name: <deploy>"),
        .expected = &.{m.fileStart("roles/deploy/tasks/main.yml")},
    },
    .{
        .name = "role/include_role map: project deploy implementation",
        .method = .implementation,
        .from = m.cursor("playbooks/project.yml", "        name: <deploy>"),
        .expected = &.{m.fileStart("roles/deploy/tasks/main.yml")},
    },
    .{
        .name = "role/include_role map: project deploy references",
        .method = .references,
        .from = m.cursor("playbooks/project.yml", "        name: <deploy>"),
        .expected = project_deploy_refs,
    },
    .{
        .name = "role/roles string FQCN: definition opens main tasks",
        .method = .definition,
        .from = m.cursor("playbooks/rollout.yml", "    - <example.rollout.verify>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/verify/tasks/main.yml")},
    },
    .{
        .name = "role/roles string FQCN: implementation opens main tasks",
        .method = .implementation,
        .from = m.cursor("playbooks/rollout.yml", "    - <example.rollout.verify>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/verify/tasks/main.yml")},
    },
    .{
        .name = "role/roles string FQCN: references join sibling short name and requirement",
        .method = .references,
        .from = m.cursor("playbooks/rollout.yml", "    - <example.rollout.verify>"),
        .expected = verify_refs,
    },
    .{
        .name = "role/include_role map FQCN: definition of migration",
        .method = .definition,
        .from = m.cursor("playbooks/rollout.yml", "        name: <example.rollout.migrate>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/migrate/tasks/main.yml")},
    },
    .{
        .name = "role/include_role map FQCN: implementation of migration",
        .method = .implementation,
        .from = m.cursor("playbooks/rollout.yml", "        name: <example.rollout.migrate>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/migrate/tasks/main.yml")},
    },
    .{
        .name = "role/include_role map FQCN: migration references",
        .method = .references,
        .from = m.cursor("playbooks/rollout.yml", "        name: <example.rollout.migrate>"),
        .expected = &.{m.span("playbooks/rollout.yml", "        name: <example.rollout.migrate>")},
    },
    .{
        .name = "role/include_role map sibling short name: definition",
        .method = .definition,
        .from = m.cursor("ansible_collections/example/rollout/roles/deploy/tasks/main.yml", "    name: <verify>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/verify/tasks/main.yml")},
    },
    .{
        .name = "role/include_role map sibling short name: references join FQCN",
        .method = .references,
        .from = m.cursor("ansible_collections/example/rollout/roles/deploy/tasks/main.yml", "    name: <verify>"),
        .expected = verify_refs,
    },
    .{
        .name = "role/requirements bare role: definition",
        .method = .definition,
        .from = m.cursor("requirements.yml", "  - <example.rollout.verify>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/verify/tasks/main.yml")},
    },
    .{
        .name = "role/requirements bare role: implementation",
        .method = .implementation,
        .from = m.cursor("requirements.yml", "  - <example.rollout.verify>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/verify/tasks/main.yml")},
    },
    .{
        .name = "role/requirements bare role: references",
        .method = .references,
        .from = m.cursor("requirements.yml", "  - <example.rollout.verify>"),
        .expected = verify_refs,
    },
    .{
        .name = "role/import_role quoted key-value: definition prefers snapshot metadata",
        .method = .definition,
        .from = m.cursor("playbooks/rollout.yml", "import_role: \"name=<example.rollout.snapshot>\""),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/snapshot/meta/main.yml")},
    },
    .{
        .name = "role/import_role quoted key-value: implementation skips metadata",
        .method = .implementation,
        .from = m.cursor("playbooks/rollout.yml", "import_role: \"name=<example.rollout.snapshot>\""),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/snapshot/tasks/main.yml")},
    },
    .{
        .name = "role/import_role quoted key-value: references across task, metadata and requirements",
        .method = .references,
        .from = m.cursor("playbooks/rollout.yml", "import_role: \"name=<example.rollout.snapshot>\""),
        .expected = snapshot_refs,
    },
    .{
        .name = "role/dependency string: definition prefers metadata",
        .method = .definition,
        .from = m.cursor("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - <example.rollout.snapshot>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/snapshot/meta/main.yml")},
    },
    .{
        .name = "role/dependency string: implementation opens snapshot main tasks",
        .method = .implementation,
        .from = m.cursor("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - <example.rollout.snapshot>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/snapshot/tasks/main.yml")},
    },
    .{
        .name = "role/dependency string: references",
        .method = .references,
        .from = m.cursor("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - <example.rollout.snapshot>"),
        .expected = snapshot_refs,
    },
    .{
        .name = "role/import_role map: snapshot definition ignores tasks_from",
        .method = .definition,
        .from = m.cursor("playbooks/rollback.yml", "        name: <example.rollout.snapshot>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/snapshot/meta/main.yml")},
    },
    .{
        .name = "role/import_role map: snapshot implementation ignores tasks_from",
        .method = .implementation,
        .from = m.cursor("ansible_collections/example/rollout/roles/rollback/tasks/main.yml", "    name: <example.rollout.snapshot>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/snapshot/tasks/main.yml")},
    },
    .{
        .name = "role/import_role map: snapshot references",
        .method = .references,
        .from = m.cursor("ansible_collections/example/rollout/roles/rollback/tasks/main.yml", "    name: <example.rollout.snapshot>"),
        .expected = snapshot_refs,
    },
    .{
        .name = "role/requirements src role: definition",
        .method = .definition,
        .from = m.cursor("requirements.yml", "  - src: <example.rollout.snapshot>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/snapshot/meta/main.yml")},
    },
    .{
        .name = "role/requirements src role: implementation",
        .method = .implementation,
        .from = m.cursor("requirements.yml", "  - src: <example.rollout.snapshot>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/snapshot/tasks/main.yml")},
    },
    .{
        .name = "role/requirements src role: references",
        .method = .references,
        .from = m.cursor("requirements.yml", "  - src: <example.rollout.snapshot>"),
        .expected = snapshot_refs,
    },
    .{
        .name = "role/include_role key-value short name: definition uses declared rollout collection",
        .method = .definition,
        .from = m.cursor("playbooks/rollout.yml", "include_role: name=<notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/include_role key-value short name: implementation",
        .method = .implementation,
        .from = m.cursor("playbooks/rollout.yml", "include_role: name=<notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/include_role key-value short name: references join FQCN, exclude shared notify",
        .method = .references,
        .from = m.cursor("playbooks/rollout.yml", "include_role: name=<notify>"),
        .expected = rollout_notify_refs,
    },
    .{
        .name = "role/play collection: short notifier definition selects rollout",
        .method = .definition,
        .from = m.cursor("playbooks/collection-overrides.yml", "Notify with the play collection\n      ansible.builtin.include_role:\n        name: <notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/play collection: short notifier implementation selects rollout",
        .method = .implementation,
        .from = m.cursor("playbooks/collection-overrides.yml", "Notify with the play collection\n      ansible.builtin.include_role:\n        name: <notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/play collection: references exclude task/block overrides",
        .method = .references,
        .from = m.cursor("playbooks/collection-overrides.yml", "Notify with the play collection\n      ansible.builtin.include_role:\n        name: <notify>"),
        .expected = rollout_notify_refs,
    },
    .{
        .name = "role/task collection overrides play: definition selects shared notifier",
        .method = .definition,
        .from = m.cursor("playbooks/collection-overrides.yml", "Notify with a task collection override\n      collections:\n        - example.shared\n      ansible.builtin.include_role:\n        name: <notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/shared/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/task collection overrides play: implementation selects shared notifier",
        .method = .implementation,
        .from = m.cursor("playbooks/collection-overrides.yml", "Notify with a task collection override\n      collections:\n        - example.shared\n      ansible.builtin.include_role:\n        name: <notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/shared/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/task collection overrides play: references join shared FQCN aliases",
        .method = .references,
        .from = m.cursor("playbooks/collection-overrides.yml", "Notify with a task collection override\n      collections:\n        - example.shared\n      ansible.builtin.include_role:\n        name: <notify>"),
        .expected = shared_notify_refs,
    },
    .{
        .name = "role/block collection overrides play: definition selects shared notifier",
        .method = .definition,
        .from = m.cursor("playbooks/collection-overrides.yml", "- name: Import the shared notifier\n          ansible.builtin.import_role:\n            name: <notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/shared/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/block collection overrides play: implementation selects shared notifier",
        .method = .implementation,
        .from = m.cursor("playbooks/collection-overrides.yml", "- name: Import the shared notifier\n          ansible.builtin.import_role:\n            name: <notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/shared/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/block collection overrides play: references exclude rollout notify",
        .method = .references,
        .from = m.cursor("playbooks/collection-overrides.yml", "- name: Import the shared notifier\n          ansible.builtin.import_role:\n            name: <notify>"),
        .expected = shared_notify_refs,
    },
    .{
        .name = "role/dependency role map: shared notify definition",
        .method = .definition,
        .from = m.cursor("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - role: <example.shared.notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/shared/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/dependency role map: shared notify implementation",
        .method = .implementation,
        .from = m.cursor("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - role: <example.shared.notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/shared/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/dependency role map: shared notify references exclude rollout notify",
        .method = .references,
        .from = m.cursor("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - role: <example.shared.notify>"),
        .expected = shared_notify_refs,
    },
    .{
        .name = "role/import_role map: shared notify definition",
        .method = .definition,
        .from = m.cursor("ansible_collections/example/rollout/roles/notify/tasks/main.yml", "    name: <example.shared.notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/shared/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/import_role map: shared notify implementation",
        .method = .implementation,
        .from = m.cursor("ansible_collections/example/rollout/roles/notify/tasks/main.yml", "    name: <example.shared.notify>"),
        .expected = &.{m.fileStart("ansible_collections/example/shared/roles/notify/tasks/main.yml")},
    },
    .{
        .name = "role/import_role map: shared notify references",
        .method = .references,
        .from = m.cursor("ansible_collections/example/rollout/roles/notify/tasks/main.yml", "    name: <example.shared.notify>"),
        .expected = shared_notify_refs,
    },
    .{
        .name = "role/dependency name map: Installed definition from configured collections path",
        .method = .definition,
        .from = m.cursor("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - name: <fixture.metrics.report>"),
        .expected = &.{m.fileStart("@deps/ansible_collections/fixture/metrics/roles/report/tasks/main.yml")},
    },
    .{
        .name = "role/dependency name map: Installed implementation",
        .method = .implementation,
        .from = m.cursor("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - name: <fixture.metrics.report>"),
        .expected = &.{m.fileStart("@deps/ansible_collections/fixture/metrics/roles/report/tasks/main.yml")},
    },
    .{
        .name = "role/dependency name map: Installed references are Workspace-only",
        .method = .references,
        .from = m.cursor("ansible_collections/example/rollout/roles/preflight/meta/main.yml", "  - name: <fixture.metrics.report>"),
        .expected = installed_report_refs,
    },
    .{
        .name = "role/roles string Installed FQCN: definition",
        .method = .definition,
        .from = m.cursor("playbooks/dependency.yml", "    - <fixture.metrics.report>"),
        .expected = &.{m.fileStart("@deps/ansible_collections/fixture/metrics/roles/report/tasks/main.yml")},
    },
    .{
        .name = "role/roles string Installed FQCN: implementation",
        .method = .implementation,
        .from = m.cursor("playbooks/dependency.yml", "    - <fixture.metrics.report>"),
        .expected = &.{m.fileStart("@deps/ansible_collections/fixture/metrics/roles/report/tasks/main.yml")},
    },
    .{
        .name = "role/roles string Installed FQCN: references exclude dependency files",
        .method = .references,
        .from = m.cursor("playbooks/dependency.yml", "    - <fixture.metrics.report>"),
        .expected = installed_report_refs,
    },
    .{
        .name = "role/requirements Galaxy name: definition resolves one-dot role on roles path",
        .method = .definition,
        .from = m.cursor("requirements.yml", "  - name: <partner.health>"),
        .expected = &.{m.fileStart("roles/partner.health/tasks/main.yml")},
    },
    .{
        .name = "role/requirements Galaxy name: implementation",
        .method = .implementation,
        .from = m.cursor("requirements.yml", "  - name: <partner.health>"),
        .expected = &.{m.fileStart("roles/partner.health/tasks/main.yml")},
    },
    .{
        .name = "role/requirements Galaxy name: references",
        .method = .references,
        .from = m.cursor("requirements.yml", "  - name: <partner.health>"),
        .expected = &.{m.span("requirements.yml", "  - name: <partner.health>")},
    },
    .{
        .name = "role/roles string: definition uses .yaml main tasks",
        .method = .definition,
        .from = m.cursor("playbooks/health.yml", "    - <healthcheck>"),
        .expected = &.{m.fileStart("roles/healthcheck/tasks/main.yaml")},
    },
    .{
        .name = "role/roles string: implementation uses .yaml main tasks",
        .method = .implementation,
        .from = m.cursor("playbooks/health.yml", "    - <healthcheck>"),
        .expected = &.{m.fileStart("roles/healthcheck/tasks/main.yaml")},
    },
    .{
        .name = "role/roles string .yaml main tasks: references",
        .method = .references,
        .from = m.cursor("playbooks/health.yml", "    - <healthcheck>"),
        .expected = &.{m.span("playbooks/health.yml", "    - <healthcheck>")},
    },
    .{
        .name = "role/ambiguous editor fallback: definitions ordered ops then services",
        .method = .definition,
        .from = m.cursor("playbooks/ambiguous.yml", "    - <check>"),
        .expected = &.{ m.fileStart("ops/roles/check/tasks/main.yml"), m.fileStart("services/roles/check/tasks/main.yml") },
    },
    .{
        .name = "role/ambiguous editor fallback: implementations ordered ops then services",
        .method = .implementation,
        .from = m.cursor("playbooks/ambiguous.yml", "    - <check>"),
        .expected = &.{ m.fileStart("ops/roles/check/tasks/main.yml"), m.fileStart("services/roles/check/tasks/main.yml") },
    },
    .{
        .name = "role/ambiguous editor fallback: references overlap both adjacent roles",
        .method = .references,
        .from = m.cursor("playbooks/ambiguous.yml", "    - <check>"),
        .expected = check_fallback_refs,
    },
    .{
        .name = "role/adjacent ops role: definition selects ops",
        .method = .definition,
        .from = m.cursor("ops/playbooks/check.yml", "    - <check>"),
        .expected = &.{m.fileStart("ops/roles/check/tasks/main.yml")},
    },
    .{
        .name = "role/adjacent ops role: references also find ambiguous fallback",
        .method = .references,
        .from = m.cursor("ops/playbooks/check.yml", "    - <check>"),
        .expected = ops_check_refs,
    },
    .{
        .name = "role/adjacent services role: implementation selects services",
        .method = .implementation,
        .from = m.cursor("services/playbooks/check.yml", "    - <check>"),
        .expected = &.{m.fileStart("services/roles/check/tasks/main.yml")},
    },
    .{
        .name = "role/adjacent services role: references exclude ops",
        .method = .references,
        .from = m.cursor("services/playbooks/check.yml", "    - <check>"),
        .expected = services_check_refs,
    },
    .{
        .name = "role/unresolved FQCN: definition does not fall through to module",
        .method = .definition,
        .from = m.cursor("negative/roles.yml", "    - <example.missing.deploy>"),
        .expected = &.{},
    },
    .{
        .name = "role/unresolved FQCN: implementation has no target",
        .method = .implementation,
        .from = m.cursor("negative/roles.yml", "    - <example.missing.deploy>"),
        .expected = &.{},
    },
    .{
        .name = "role/unresolved FQCN: references find only this site, not identical missing name",
        .method = .references,
        .from = m.cursor("negative/roles.yml", "    - <example.missing.deploy>"),
        .expected = &.{m.span("negative/roles.yml", "    - <example.missing.deploy>")},
    },
    .{
        .name = "role/unresolved repeated FQCN: references find only second site",
        .method = .references,
        .from = m.cursor("negative/roles.yml", "        name: <example.missing.deploy>"),
        .expected = &.{m.span("negative/roles.yml", "        name: <example.missing.deploy>")},
    },
    .{
        .name = "role/unresolved short name: definition has no target",
        .method = .definition,
        .from = m.cursor("negative/roles.yml", "    - <absent_role>"),
        .expected = &.{},
    },
    .{
        .name = "role/unresolved short name: references include only self",
        .method = .references,
        .from = m.cursor("negative/roles.yml", "    - <absent_role>"),
        .expected = &.{m.span("negative/roles.yml", "    - <absent_role>")},
    },
    .{
        .name = "role/negative task name: not a role reference",
        .method = .references,
        .from = m.cursor("negative/roles.yml", "    - name: <deploy>"),
        .expected = &.{},
    },
    .{
        .name = "role/negative role key: cursor must be on value",
        .method = .implementation,
        .from = m.cursor("playbooks/rollout.yml", "- <role>: example.rollout.preflight"),
        .expected = &.{},
    },
    .{
        .name = "role/Jinja-valued include name: implementation binds the variable, not a static role",
        .method = .implementation,
        .from = m.cursor("negative/roles.yml", "name: \"{{ <dynamic_role> }}\""),
        .expected = &.{m.span("negative/roles.yml", "<dynamic_role>: example.rollout.deploy")},
    },
    .{
        .name = "role/negative requirement URL source: not a role reference",
        .method = .references,
        .from = m.cursor("requirements.yml", "src: <https://example.invalid/role.git>"),
        .expected = &.{},
    },
    .{
        .name = "role/negative requirement URL source: no role definition",
        .method = .definition,
        .from = m.cursor("requirements.yml", "src: <https://example.invalid/role.git>"),
        .expected = &.{},
    },
    .{
        .name = "role/negative tasks_from: not a role reference",
        .method = .references,
        .from = m.cursor("playbooks/rollback.yml", "tasks_from: <details>"),
        .expected = &.{},
    },
    .{
        .name = "role/metadata-only target: definition opens metadata",
        .method = .definition,
        .from = m.cursor("negative/roles.yml", "    - <metadata_only>"),
        .expected = &.{m.fileStart("roles/metadata_only/meta/main.yml")},
    },
    .{
        .name = "role/metadata-only target: implementation has no main task file",
        .method = .implementation,
        .from = m.cursor("negative/roles.yml", "    - <metadata_only>"),
        .expected = &.{},
    },
    .{
        .name = "role/metadata-only target: references still find the invocation",
        .method = .references,
        .from = m.cursor("negative/roles.yml", "    - <metadata_only>"),
        .expected = &.{m.span("negative/roles.yml", "    - <metadata_only>")},
    },
    .{
        .name = "role/rollback play: definition opens the rollback main task file",
        .method = .definition,
        .from = m.cursor("playbooks/rollback.yml", "    - <example.rollout.rollback>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/rollback/tasks/main.yml")},
    },
    .{
        .name = "role/rollback play: implementation opens the rollback main task file",
        .method = .implementation,
        .from = m.cursor("playbooks/rollback.yml", "    - <example.rollout.rollback>"),
        .expected = &.{m.fileStart("ansible_collections/example/rollout/roles/rollback/tasks/main.yml")},
    },
    .{
        .name = "role/rollback play: references include its sole invocation",
        .method = .references,
        .from = m.cursor("playbooks/rollback.yml", "    - <example.rollout.rollback>"),
        .expected = &.{m.span("playbooks/rollback.yml", "    - <example.rollout.rollback>")},
    },
};

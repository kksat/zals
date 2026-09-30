const m = @import("../model.zig");

const rollout = "playbooks/rollout.yml";
const release = "playbooks/vars/release.yml";
const runtime = "playbooks/vars/runtime.yml";
const common = "playbooks/tasks/common.yml";
const preflight = "ansible_collections/example/rollout/roles/preflight/";
const deploy = "ansible_collections/example/rollout/roles/deploy/";
const shared_notify = "ansible_collections/example/shared/roles/notify/tasks/main.yml";
const verify = "ansible_collections/example/rollout/roles/verify/tasks/main.yml";
const snapshot = "ansible_collections/example/rollout/roles/snapshot/tasks/main.yml";
const migration = "ansible_collections/example/rollout/roles/migrate/tasks/migrate-data.yml";
const recovery = "ansible_collections/example/rollout/roles/rollback/tasks/recover.yml";
const pf_tasks = preflight ++ "tasks/main.yml";
const pf_steps = preflight ++ "tasks/steps.yml";
const pf_template = preflight ++ "templates/notice.j2";
const pf_defaults = preflight ++ "defaults/main.yml";
const pf_vars = preflight ++ "vars/main.yml";
const pf_overrides = preflight ++ "vars/overrides.yml";
const pf_specs = preflight ++ "meta/argument_specs.yml";
const deploy_tasks = deploy ++ "tasks/main.yml";
const deploy_defaults = deploy ++ "defaults/main.yml";

// Whole-Workspace, name-based reference answers. Each declaration mode is an
// independent oracle: in particular, repeated reads on different lines are
// separate locations, even when they resolve to the same definition.
const release_tag_reads: []const m.ExpectedLocation = &.{
    m.span(pf_tasks, "🚀 {{ <release_tag> }} on port"),
    m.span(pf_template, "Rollout {{ <release_tag> }}"),
    m.span(deploy_tasks, "for {{ <release_tag> }}"),
    m.span(snapshot, "Snapshot for {{ <release_tag> }}"),
    m.span(migration, "Data migrated for {{ <release_tag> }}"),
    m.span(verify, "{{ <release_tag> }} ready"),
    m.span(recovery, "Restored {{ <release_tag> }}"),
    m.span(shared_notify, "Notifying about {{ <release_tag> }}"),
    m.span(rollout, "🚀 {{ <release_tag> }}: {{ runtime_label }}"),
    m.span(rollout, "{{ <release_tag> }} is staged"),
    m.span(rollout, "label: \"{{ <release_tag> }}\""),
    m.span(common, "{{ <release_tag> }} on {{ app_port }}"),
};
const release_tag_with_declarations: []const m.ExpectedLocation = &.{
    m.span(pf_tasks, "🚀 {{ <release_tag> }} on port"),
    m.span(pf_template, "Rollout {{ <release_tag> }}"),
    m.span(deploy_tasks, "for {{ <release_tag> }}"),
    m.span(snapshot, "Snapshot for {{ <release_tag> }}"),
    m.span(migration, "Data migrated for {{ <release_tag> }}"),
    m.span(verify, "{{ <release_tag> }} ready"),
    m.span(recovery, "Restored {{ <release_tag> }}"),
    m.span(shared_notify, "Notifying about {{ <release_tag> }}"),
    m.span(rollout, "🚀 {{ <release_tag> }}: {{ runtime_label }}"),
    m.span(rollout, "{{ <release_tag> }} is staged"),
    m.span(rollout, "label: \"{{ <release_tag> }}\""),
    m.span(common, "{{ <release_tag> }} on {{ app_port }}"),
    m.span(rollout, "      <release_tag>: release-candidate"),
    m.span(release, "<release_tag>: release-from-vars-file"),
    m.span(pf_defaults, "<release_tag>: candidate"),
    m.span(pf_specs, "      <release_tag>:"),
};
const app_port_reads: []const m.ExpectedLocation = &.{
    m.span(pf_tasks, "port {{ <app_port> }}"),
    m.span(common, "on {{ <app_port> }}"),
};
const app_port_with_declarations: []const m.ExpectedLocation = &.{
    m.span(pf_tasks, "port {{ <app_port> }}"),
    m.span(common, "on {{ <app_port> }}"),
    m.span(pf_defaults, "<app_port>: 8080"),
    m.span(pf_specs, "      <app_port>:"),
};
const preflight_ready_reads: []const m.ExpectedLocation = &.{
    m.span(pf_steps, "{{ <preflight_ready> }}:"),
    m.span(pf_template, "{% if <preflight_ready> %}"),
};
const preflight_ready_with_declaration: []const m.ExpectedLocation = &.{
    m.span(pf_steps, "{{ <preflight_ready> }}:"),
    m.span(pf_template, "{% if <preflight_ready> %}"),
    m.span(pf_tasks, "    <preflight_ready>: true"),
};
const deployment_result_reads: []const m.ExpectedLocation = &.{
    m.span(deploy_tasks, "{{ <deployment_result>.msg }}"),
    m.span(deploy_tasks, "when: <deployment_result> is defined"),
};
const deployment_result_with_declaration: []const m.ExpectedLocation = &.{
    m.span(deploy_tasks, "{{ <deployment_result>.msg }}"),
    m.span(deploy_tasks, "when: <deployment_result> is defined"),
    m.span(deploy_tasks, "register: <deployment_result>"),
};
const deploy_image_reads: []const m.ExpectedLocation = &.{
    m.span(deploy_tasks, "Deploy {{ <deploy_image> }}"),
};
const deploy_image_with_declarations: []const m.ExpectedLocation = &.{
    m.span(deploy_tasks, "Deploy {{ <deploy_image> }}"),
    m.span(rollout, "      <deploy_image>: example/app:candidate"),
    m.span(deploy_defaults, "<deploy_image>: example/app:stable"),
};
const target_item_reads: []const m.ExpectedLocation = &.{
    m.span(verify, "msg: \"{{ <target_item> }}\""),
};
const target_item_with_declaration: []const m.ExpectedLocation = &.{
    m.span(verify, "msg: \"{{ <target_item> }}\""),
    m.span(verify, "loop_var: <target_item>"),
};
const file_choice_reads: []const m.ExpectedLocation = &.{
    m.span("negative/files.yml", "include_tasks: \"{{ <file_choice> }}\""),
    m.span("negative/files.yml", "file: \"{{ <file_choice> }}\""),
};
const file_choice_with_declaration: []const m.ExpectedLocation = &.{
    m.span("negative/files.yml", "include_tasks: \"{{ <file_choice> }}\""),
    m.span("negative/files.yml", "file: \"{{ <file_choice> }}\""),
    m.span("negative/files.yml", "<file_choice>: missing.yml"),
};

pub const all = [_]m.Case{
    // Jinja interpolation: parameter > vars_file > default > argument spec.
    .{
        .name = "variable/Jinja Unicode prefix: release_tag references without declarations",
        .method = .references,
        .from = m.cursor(rollout, "🚀 {{ <release_tag> }}: {{ runtime_label }}"),
        .include_declaration = false,
        .expected = release_tag_reads,
    },
    .{
        .name = "variable/Jinja Unicode prefix: release_tag references with declarations",
        .method = .references,
        .from = m.cursor(pf_tasks, "🚀 {{ <release_tag> }} on port"),
        .include_declaration = true,
        .expected = release_tag_with_declarations,
    },
    .{
        .name = "variable/Jinja role reference: ordered role parameter, vars_file, default, spec",
        .method = .definition,
        .from = m.cursor(pf_tasks, "🚀 {{ <release_tag> }} on port"),
        .expected = &.{
            m.span(rollout, "      <release_tag>: release-candidate"),
            m.span(release, "<release_tag>: release-from-vars-file"),
            m.span(pf_defaults, "<release_tag>: candidate"),
            m.span(pf_specs, "      <release_tag>:"),
        },
    },
    .{
        .name = "variable/Jinja playbook reference: precedence and elsewhere definitions",
        .method = .definition,
        .from = m.cursor(rollout, "🚀 {{ <release_tag> }}: {{ runtime_label }}"),
        .expected = &.{
            m.span(rollout, "      <release_tag>: release-candidate"),
            m.span(release, "<release_tag>: release-from-vars-file"),
            m.span(pf_defaults, "<release_tag>: candidate"),
            m.span(pf_specs, "      <release_tag>:"),
        },
    },
    .{
        .name = "variable/shared task file: including playbook supplies reachable release_tag",
        .method = .definition,
        .from = m.cursor(common, "{{ <release_tag> }} on {{ app_port }}"),
        .expected = &.{
            m.span(rollout, "      <release_tag>: release-candidate"),
            m.span(release, "<release_tag>: release-from-vars-file"),
            m.span(pf_defaults, "<release_tag>: candidate"),
            m.span(pf_specs, "      <release_tag>:"),
        },
    },
    .{
        .name = "variable/Jinja template: release_tag is a Workspace reference",
        .method = .references,
        .from = m.cursor(pf_template, "Rollout {{ <release_tag> }}"),
        .include_declaration = false,
        .expected = release_tag_reads,
    },
    .{
        .name = "variable/Jinja template: definition follows invoking playbook",
        .method = .definition,
        .from = m.cursor(pf_template, "Rollout {{ <release_tag> }}"),
        .expected = &.{
            m.span(rollout, "      <release_tag>: release-candidate"),
            m.span(release, "<release_tag>: release-from-vars-file"),
            m.span(pf_defaults, "<release_tag>: candidate"),
            m.span(pf_specs, "      <release_tag>:"),
        },
    },
    .{
        .name = "variable/Jinja shared tasks: app_port references without declarations",
        .method = .references,
        .from = m.cursor(common, "on {{ <app_port> }}"),
        .include_declaration = false,
        .expected = app_port_reads,
    },
    .{
        .name = "variable/Jinja spec and default: app_port references with declarations",
        .method = .references,
        .from = m.cursor(pf_tasks, "port {{ <app_port> }}"),
        .include_declaration = true,
        .expected = app_port_with_declarations,
    },
    .{
        .name = "variable/Jinja role scope: app_port default before spec",
        .method = .definition,
        .from = m.cursor(pf_tasks, "port {{ <app_port> }}"),
        .expected = &.{
            m.span(pf_defaults, "<app_port>: 8080"),
            m.span(pf_specs, "      <app_port>:"),
        },
    },
    .{
        .name = "variable/Jinja task file scope: app_port definitions elsewhere",
        .method = .definition,
        .from = m.cursor(common, "on {{ <app_port> }}"),
        .expected = &.{
            m.span(pf_defaults, "<app_port>: 8080"),
            m.span(pf_specs, "      <app_port>:"),
        },
    },
    .{
        .name = "variable/default key cursor: find app_port reads without declarations",
        .method = .references,
        .from = m.cursor(pf_defaults, "<app_port>: 8080"),
        .include_declaration = false,
        .expected = app_port_reads,
    },
    .{
        .name = "variable/argument_specs option cursor: find app_port reads and declarations",
        .method = .references,
        .from = m.cursor(pf_specs, "      <app_port>:"),
        .include_declaration = true,
        .expected = app_port_with_declarations,
    },
    .{
        .name = "variable/role parameter key cursor: find release_tag references",
        .method = .references,
        .from = m.cursor(rollout, "      <release_tag>: release-candidate"),
        .include_declaration = false,
        .expected = release_tag_reads,
    },
    .{
        .name = "variable/Jinja role vars: readiness_label definition",
        .method = .definition,
        .from = m.cursor(pf_tasks, "{{ <readiness_label> }}"),
        .expected = &.{m.span(pf_vars, "<readiness_label>: ready")},
    },
    .{
        .name = "variable/Jinja role vars: readiness_label references without declaration",
        .method = .references,
        .from = m.cursor(pf_tasks, "{{ <readiness_label> }}"),
        .include_declaration = false,
        .expected = &.{m.span(pf_tasks, "{{ <readiness_label> }}")},
    },
    .{
        .name = "variable/Jinja role vars: readiness_label references with declaration",
        .method = .references,
        .from = m.cursor(pf_tasks, "{{ <readiness_label> }}"),
        .include_declaration = true,
        .expected = &.{
            m.span(pf_tasks, "{{ <readiness_label> }}"),
            m.span(pf_vars, "<readiness_label>: ready"),
        },
    },
    .{
        .name = "variable/role vars key cursor: find readiness_label reads",
        .method = .references,
        .from = m.cursor(pf_vars, "<readiness_label>: ready"),
        .include_declaration = false,
        .expected = &.{m.span(pf_tasks, "{{ <readiness_label> }}")},
    },
    .{
        .name = "variable/Jinja in included steps: include_vars target definition",
        .method = .definition,
        .from = m.cursor(pf_steps, "{{ <shared_note> }}"),
        .expected = &.{m.span(pf_overrides, "<shared_note>: checked")},
    },
    .{
        .name = "variable/Jinja in included steps: include_vars reference without declaration",
        .method = .references,
        .from = m.cursor(pf_steps, "{{ <shared_note> }}"),
        .include_declaration = false,
        .expected = &.{m.span(pf_steps, "{{ <shared_note> }}")},
    },
    .{
        .name = "variable/Jinja in included steps: include_vars reference with declaration",
        .method = .references,
        .from = m.cursor(pf_steps, "{{ <shared_note> }}"),
        .include_declaration = true,
        .expected = &.{
            m.span(pf_steps, "{{ <shared_note> }}"),
            m.span(pf_overrides, "<shared_note>: checked"),
        },
    },
    .{
        .name = "variable/Jinja in template: set_fact reference without declaration",
        .method = .references,
        .from = m.cursor(pf_template, "{% if <preflight_ready> %}"),
        .include_declaration = false,
        .expected = preflight_ready_reads,
    },
    .{
        .name = "variable/Jinja in template: set_fact reference with declaration",
        .method = .references,
        .from = m.cursor(pf_steps, "{{ <preflight_ready> }}:"),
        .include_declaration = true,
        .expected = preflight_ready_with_declaration,
    },
    .{
        .name = "variable/Jinja statement: set_fact definition",
        .method = .definition,
        .from = m.cursor(pf_template, "{% if <preflight_ready> %}"),
        .expected = &.{m.span(pf_tasks, "    <preflight_ready>: true")},
    },
    .{
        .name = "variable/Jinja role invocation parameter outranks role default",
        .method = .definition,
        .from = m.cursor(deploy_tasks, "Deploy {{ <deploy_image> }}"),
        .expected = &.{
            m.span(rollout, "      <deploy_image>: example/app:candidate"),
            m.span(deploy_defaults, "<deploy_image>: example/app:stable"),
        },
    },
    .{
        .name = "variable/Jinja role invocation parameter references without declarations",
        .method = .references,
        .from = m.cursor(deploy_tasks, "Deploy {{ <deploy_image> }}"),
        .include_declaration = false,
        .expected = deploy_image_reads,
    },
    .{
        .name = "variable/Jinja role invocation parameter references with declarations",
        .method = .references,
        .from = m.cursor(deploy_tasks, "Deploy {{ <deploy_image> }}"),
        .include_declaration = true,
        .expected = deploy_image_with_declarations,
    },
    .{
        .name = "variable/Jinja register attribute root: references without declaration",
        .method = .references,
        .from = m.cursor(deploy_tasks, "{{ <deployment_result>.msg }}"),
        .include_declaration = false,
        .expected = deployment_result_reads,
    },
    .{
        .name = "variable/bare when and Jinja share register references with declaration",
        .method = .references,
        .from = m.cursor(deploy_tasks, "when: <deployment_result> is defined"),
        .include_declaration = true,
        .expected = deployment_result_with_declaration,
    },
    .{
        .name = "variable/bare when: register definition",
        .method = .definition,
        .from = m.cursor(deploy_tasks, "when: <deployment_result> is defined"),
        .expected = &.{m.span(deploy_tasks, "register: <deployment_result>")},
    },
    .{
        .name = "variable/Jinja playbook: vars_prompt definition",
        .method = .definition,
        .from = m.cursor(rollout, "when: <rollout_approval> | bool"),
        .expected = &.{m.span(rollout, "- name: <rollout_approval>")},
    },
    .{
        .name = "variable/bare when: vars_prompt references without declaration",
        .method = .references,
        .from = m.cursor(rollout, "when: <rollout_approval> | bool"),
        .include_declaration = false,
        .expected = &.{m.span(rollout, "when: <rollout_approval> | bool")},
    },
    .{
        .name = "variable/bare when: vars_prompt references with declaration",
        .method = .references,
        .from = m.cursor(rollout, "when: <rollout_approval> | bool"),
        .include_declaration = true,
        .expected = &.{
            m.span(rollout, "when: <rollout_approval> | bool"),
            m.span(rollout, "- name: <rollout_approval>"),
        },
    },
    .{
        .name = "variable/Jinja playbook: repeated include_vars target definition",
        .method = .definition,
        .from = m.cursor(rollout, "{{ release_tag }}: {{ <runtime_label> }}"),
        .expected = &.{m.span(runtime, "<runtime_label>: smoke-test")},
    },
    .{
        .name = "variable/Jinja playbook: include_vars references without declaration",
        .method = .references,
        .from = m.cursor(rollout, "{{ release_tag }}: {{ <runtime_label> }}"),
        .include_declaration = false,
        .expected = &.{m.span(rollout, "{{ release_tag }}: {{ <runtime_label> }}")},
    },
    .{
        .name = "variable/Jinja playbook: include_vars references with declaration once",
        .method = .references,
        .from = m.cursor(rollout, "{{ release_tag }}: {{ <runtime_label> }}"),
        .include_declaration = true,
        .expected = &.{
            m.span(rollout, "{{ release_tag }}: {{ <runtime_label> }}"),
            m.span(runtime, "<runtime_label>: smoke-test"),
        },
    },
    .{
        .name = "variable/Jinja block vars: definition",
        .method = .definition,
        .from = m.cursor(rollout, "{{ <block_marker> }}"),
        .expected = &.{m.span(rollout, "<block_marker>: in-block")},
    },
    .{
        .name = "variable/Jinja block vars: references without declaration",
        .method = .references,
        .from = m.cursor(rollout, "{{ <block_marker> }}"),
        .include_declaration = false,
        .expected = &.{m.span(rollout, "{{ <block_marker> }}")},
    },
    .{
        .name = "variable/Jinja block vars: references with declaration",
        .method = .references,
        .from = m.cursor(rollout, "{{ <block_marker> }}"),
        .include_declaration = true,
        .expected = &.{
            m.span(rollout, "{{ <block_marker> }}"),
            m.span(rollout, "<block_marker>: in-block"),
        },
    },
    .{
        .name = "variable/Jinja task vars: definition",
        .method = .definition,
        .from = m.cursor(rollout, "{{ <task_marker> }}"),
        .expected = &.{m.span(rollout, "<task_marker>: in-task")},
    },
    .{
        .name = "variable/Jinja task vars: references without declaration",
        .method = .references,
        .from = m.cursor(rollout, "{{ <task_marker> }}"),
        .include_declaration = false,
        .expected = &.{m.span(rollout, "{{ <task_marker> }}")},
    },
    .{
        .name = "variable/Jinja task vars: references with declaration",
        .method = .references,
        .from = m.cursor(rollout, "{{ <task_marker> }}"),
        .include_declaration = true,
        .expected = &.{
            m.span(rollout, "{{ <task_marker> }}"),
            m.span(rollout, "<task_marker>: in-task"),
        },
    },
    // All bare-expression keys in the committed fixture, including a list
    // element of assert.that and Ansible's with_* family.
    .{
        .name = "variable/bare assert.that list item: play vars definition",
        .method = .definition,
        .from = m.cursor(verify, "- <release_ready>"),
        .expected = &.{m.span(rollout, "<release_ready>: true")},
    },
    .{
        .name = "variable/bare assert.that list item: references without declaration",
        .method = .references,
        .from = m.cursor(verify, "- <release_ready>"),
        .include_declaration = false,
        .expected = &.{m.span(verify, "- <release_ready>")},
    },
    .{
        .name = "variable/bare assert.that list item: references with declaration",
        .method = .references,
        .from = m.cursor(verify, "- <release_ready>"),
        .include_declaration = true,
        .expected = &.{
            m.span(verify, "- <release_ready>"),
            m.span(rollout, "<release_ready>: true"),
        },
    },
    .{
        .name = "variable/bare assert.that comparison: play vars definition",
        .method = .definition,
        .from = m.cursor(verify, "- <rollout_phase> == 'staged'"),
        .expected = &.{m.span(rollout, "<rollout_phase>: staged")},
    },
    .{
        .name = "variable/bare assert.that comparison: references without declaration",
        .method = .references,
        .from = m.cursor(verify, "- <rollout_phase> == 'staged'"),
        .include_declaration = false,
        .expected = &.{m.span(verify, "- <rollout_phase> == 'staged'")},
    },
    .{
        .name = "variable/bare assert.that comparison: references with declaration",
        .method = .references,
        .from = m.cursor(verify, "- <rollout_phase> == 'staged'"),
        .include_declaration = true,
        .expected = &.{
            m.span(verify, "- <rollout_phase> == 'staged'"),
            m.span(rollout, "<rollout_phase>: staged"),
        },
    },
    .{
        .name = "variable/bare changed_when: vars_file definition",
        .method = .definition,
        .from = m.cursor(verify, "changed_when: <verify_changed>"),
        .expected = &.{m.span(release, "<verify_changed>: false")},
    },
    .{
        .name = "variable/bare changed_when: references without declaration",
        .method = .references,
        .from = m.cursor(verify, "changed_when: <verify_changed>"),
        .include_declaration = false,
        .expected = &.{m.span(verify, "changed_when: <verify_changed>")},
    },
    .{
        .name = "variable/bare changed_when: references with declaration",
        .method = .references,
        .from = m.cursor(verify, "changed_when: <verify_changed>"),
        .include_declaration = true,
        .expected = &.{
            m.span(verify, "changed_when: <verify_changed>"),
            m.span(release, "<verify_changed>: false"),
        },
    },
    .{
        .name = "variable/bare failed_when: vars_file definition",
        .method = .definition,
        .from = m.cursor(verify, "failed_when: <verify_failed>"),
        .expected = &.{m.span(release, "<verify_failed>: false")},
    },
    .{
        .name = "variable/bare failed_when: references without declaration",
        .method = .references,
        .from = m.cursor(verify, "failed_when: <verify_failed>"),
        .include_declaration = false,
        .expected = &.{m.span(verify, "failed_when: <verify_failed>")},
    },
    .{
        .name = "variable/bare failed_when: references with declaration",
        .method = .references,
        .from = m.cursor(verify, "failed_when: <verify_failed>"),
        .include_declaration = true,
        .expected = &.{
            m.span(verify, "failed_when: <verify_failed>"),
            m.span(release, "<verify_failed>: false"),
        },
    },
    .{
        .name = "variable/bare until: vars_file definition",
        .method = .definition,
        .from = m.cursor(verify, "until: <verify_complete>"),
        .expected = &.{m.span(release, "<verify_complete>: true")},
    },
    .{
        .name = "variable/bare until: references without declaration",
        .method = .references,
        .from = m.cursor(verify, "until: <verify_complete>"),
        .include_declaration = false,
        .expected = &.{m.span(verify, "until: <verify_complete>")},
    },
    .{
        .name = "variable/bare until: references with declaration",
        .method = .references,
        .from = m.cursor(verify, "until: <verify_complete>"),
        .include_declaration = true,
        .expected = &.{
            m.span(verify, "until: <verify_complete>"),
            m.span(release, "<verify_complete>: true"),
        },
    },
    .{
        .name = "variable/bare loop: vars_file definition",
        .method = .definition,
        .from = m.cursor(verify, "loop: <rollout_targets>"),
        .expected = &.{m.span(release, "<rollout_targets>: [api, worker]")},
    },
    .{
        .name = "variable/bare loop: references without declaration",
        .method = .references,
        .from = m.cursor(verify, "loop: <rollout_targets>"),
        .include_declaration = false,
        .expected = &.{m.span(verify, "loop: <rollout_targets>")},
    },
    .{
        .name = "variable/bare loop: references with declaration",
        .method = .references,
        .from = m.cursor(verify, "loop: <rollout_targets>"),
        .include_declaration = true,
        .expected = &.{
            m.span(verify, "loop: <rollout_targets>"),
            m.span(release, "<rollout_targets>: [api, worker]"),
        },
    },
    .{
        .name = "variable/bare with_items: vars_file definition",
        .method = .definition,
        .from = m.cursor(verify, "with_items: <optional_targets>"),
        .expected = &.{m.span(release, "<optional_targets>: [metrics]")},
    },
    .{
        .name = "variable/bare with_items: references without declaration",
        .method = .references,
        .from = m.cursor(verify, "with_items: <optional_targets>"),
        .include_declaration = false,
        .expected = &.{m.span(verify, "with_items: <optional_targets>")},
    },
    .{
        .name = "variable/bare with_items: references with declaration",
        .method = .references,
        .from = m.cursor(verify, "with_items: <optional_targets>"),
        .include_declaration = true,
        .expected = &.{
            m.span(verify, "with_items: <optional_targets>"),
            m.span(release, "<optional_targets>: [metrics]"),
        },
    },
    .{
        .name = "variable/Jinja loop_var: definition outranks all other sites",
        .method = .definition,
        .from = m.cursor(verify, "{{ <target_item> }}"),
        .expected = &.{m.span(verify, "loop_var: <target_item>")},
    },
    .{
        .name = "variable/Jinja loop_var: references without declaration",
        .method = .references,
        .from = m.cursor(verify, "{{ <target_item> }}"),
        .include_declaration = false,
        .expected = target_item_reads,
    },
    .{
        .name = "variable/Jinja loop_var: references with declaration",
        .method = .references,
        .from = m.cursor(verify, "{{ <target_item> }}"),
        .include_declaration = true,
        .expected = target_item_with_declaration,
    },
    .{
        .name = "variable/Jinja service root: vars_file map definition",
        .method = .definition,
        .from = m.cursor(verify, "{{ <service>.name | default('unnamed') }}"),
        .expected = &.{m.span(release, "<service>:\n  name: rollout-api")},
    },
    .{
        .name = "variable/Jinja attribute root: references without declaration",
        .method = .references,
        .from = m.cursor(verify, "{{ <service>.name | default('unnamed') }}"),
        .include_declaration = false,
        .expected = &.{m.span(verify, "{{ <service>.name | default('unnamed') }}")},
    },
    .{
        .name = "variable/Jinja attribute root: references with declaration",
        .method = .references,
        .from = m.cursor(verify, "{{ <service>.name | default('unnamed') }}"),
        .include_declaration = true,
        .expected = &.{
            m.span(verify, "{{ <service>.name | default('unnamed') }}"),
            m.span(release, "<service>:\n  name: rollout-api"),
        },
    },
    .{
        .name = "variable/Jinja computed paths: only root variable reads",
        .method = .references,
        .from = m.cursor("negative/files.yml", "include_tasks: \"{{ <file_choice> }}\""),
        .include_declaration = false,
        .expected = file_choice_reads,
    },
    .{
        .name = "variable/Jinja computed paths: include declaration independently",
        .method = .references,
        .from = m.cursor("negative/files.yml", "file: \"{{ <file_choice> }}\""),
        .include_declaration = true,
        .expected = file_choice_with_declaration,
    },
    .{
        .name = "variable/Jinja computed paths: play vars definition",
        .method = .definition,
        .from = m.cursor("negative/files.yml", "include_tasks: \"{{ <file_choice> }}\""),
        .expected = &.{m.span("negative/files.yml", "<file_choice>: missing.yml")},
    },
    // A different collection's notify role does not receive rollout's role
    // parameter or vars file. The server currently conflates the short
    // example.rollout.notify invocation with example.shared.notify by basename.
    // Name-based references still see the shared role's read above.
    .{
        .name = "variable/scope boundary: shared notifier has only elsewhere definitions",
        .method = .definition,
        .from = m.cursor(shared_notify, "Notifying about {{ <release_tag> }}"),
        .expected = &.{
            m.span(pf_defaults, "<release_tag>: candidate"),
            m.span(pf_specs, "      <release_tag>:"),
            m.span(rollout, "      <release_tag>: release-candidate"),
            m.span(release, "<release_tag>: release-from-vars-file"),
        },
    },
    .{
        .name = "variable/unbound Jinja item: no definition",
        .method = .definition,
        .from = m.cursor(verify, "msg: \"{{ <item> }}\""),
        .expected = &.{},
    },
    .{
        .name = "variable/unbound Jinja item: references without declaration",
        .method = .references,
        .from = m.cursor(verify, "msg: \"{{ <item> }}\""),
        .include_declaration = false,
        .expected = &.{m.span(verify, "msg: \"{{ <item> }}\"")},
    },
    .{
        .name = "variable/unbound Jinja item: references with declaration",
        .method = .references,
        .from = m.cursor(verify, "msg: \"{{ <item> }}\""),
        .include_declaration = true,
        .expected = &.{m.span(verify, "msg: \"{{ <item> }}\"")},
    },
    .{
        .name = "variable/non-match: attribute is not a variable definition",
        .method = .definition,
        .from = m.cursor(verify, "{{ service.<name> | default('unnamed') }}"),
        .expected = &.{},
    },
    .{
        .name = "variable/non-match: attribute is not a reference",
        .method = .references,
        .from = m.cursor(verify, "{{ service.<name> | default('unnamed') }}"),
        .include_declaration = false,
        .expected = &.{},
    },
    .{
        .name = "variable/non-match: filter is not a variable definition",
        .method = .definition,
        .from = m.cursor(verify, "service.name | <default>('unnamed')"),
        .expected = &.{},
    },
    .{
        .name = "variable/non-match: filter is not a reference",
        .method = .references,
        .from = m.cursor(verify, "service.name | <default>('unnamed')"),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable/non-match: test is not a variable definition",
        .method = .definition,
        .from = m.cursor(deploy_tasks, "deployment_result is <defined>"),
        .expected = &.{},
    },
    .{
        .name = "variable/non-match: test is not a reference",
        .method = .references,
        .from = m.cursor(deploy_tasks, "deployment_result is <defined>"),
        .include_declaration = false,
        .expected = &.{},
    },
    .{
        .name = "variable/non-match: quoted literal in bare expression is not a definition",
        .method = .definition,
        .from = m.cursor(verify, "rollout_phase == '<staged>'"),
        .expected = &.{},
    },
    .{
        .name = "variable/non-match: quoted literal in bare expression is not a reference",
        .method = .references,
        .from = m.cursor(verify, "rollout_phase == '<staged>'"),
        .include_declaration = true,
        .expected = &.{},
    },
    .{
        .name = "variable/include_vars outranks vars_files for the same name",
        .method = .definition,
        .from = m.cursor(rollout, "Channel {{ <rollout_channel> }}"),
        .expected = &.{
            m.span(runtime, "<rollout_channel>: active"),
            m.span(release, "<rollout_channel>: planned"),
        },
    },
    .{
        .name = "variable/include_vars and vars_files: references without declarations",
        .method = .references,
        .from = m.cursor(rollout, "Channel {{ <rollout_channel> }}"),
        .include_declaration = false,
        .expected = &.{m.span(rollout, "Channel {{ <rollout_channel> }}")},
    },
    .{
        .name = "variable/include_vars and vars_files: references with both declarations",
        .method = .references,
        .from = m.cursor(rollout, "Channel {{ <rollout_channel> }}"),
        .include_declaration = true,
        .expected = &.{
            m.span(rollout, "Channel {{ <rollout_channel> }}"),
            m.span(runtime, "<rollout_channel>: active"),
            m.span(release, "<rollout_channel>: planned"),
        },
    },
    .{
        .name = "variable/include_vars file= Workspace-root fallback outranks play vars",
        .method = .definition,
        .from = m.cursor("negative/nonstandard-paths.yml", "msg: \"{{ <root_loaded_flag> }}\""),
        .expected = &.{
            m.span(runtime, "<root_loaded_flag>: true"),
            m.span("negative/nonstandard-paths.yml", "<root_loaded_flag>: false"),
        },
    },
    .{
        .name = "variable/include_vars file= root fallback: references without declarations",
        .method = .references,
        .from = m.cursor("negative/nonstandard-paths.yml", "msg: \"{{ <root_loaded_flag> }}\""),
        .include_declaration = false,
        .expected = &.{m.span("negative/nonstandard-paths.yml", "msg: \"{{ <root_loaded_flag> }}\"")},
    },
    .{
        .name = "variable/include_vars file= root fallback: references with both declarations",
        .method = .references,
        .from = m.cursor("negative/nonstandard-paths.yml", "msg: \"{{ <root_loaded_flag> }}\""),
        .include_declaration = true,
        .expected = &.{
            m.span("negative/nonstandard-paths.yml", "msg: \"{{ <root_loaded_flag> }}\""),
            m.span(runtime, "<root_loaded_flag>: true"),
            m.span("negative/nonstandard-paths.yml", "<root_loaded_flag>: false"),
        },
    },
    .{
        .name = "variable/bare when in Role: deployment_enabled default definition",
        .method = .definition,
        .from = m.cursor(pf_tasks, "when: <deployment_enabled> | bool"),
        .expected = &.{m.span(pf_defaults, "<deployment_enabled>: true")},
    },
    .{
        .name = "variable/bare when in Role: deployment_enabled reads without declarations",
        .method = .references,
        .from = m.cursor(pf_tasks, "when: <deployment_enabled> | bool"),
        .include_declaration = false,
        .expected = &.{m.span(pf_tasks, "when: <deployment_enabled> | bool")},
    },
    .{
        .name = "variable/bare when in Role: deployment_enabled reads with declaration",
        .method = .references,
        .from = m.cursor(pf_tasks, "when: <deployment_enabled> | bool"),
        .include_declaration = true,
        .expected = &.{
            m.span(pf_tasks, "when: <deployment_enabled> | bool"),
            m.span(pf_defaults, "<deployment_enabled>: true"),
        },
    },
    .{
        .name = "variable/Jinja-valued role name: dynamic_role resolves as a play var",
        .method = .definition,
        .from = m.cursor("negative/roles.yml", "name: \"{{ <dynamic_role> }}\""),
        .expected = &.{m.span("negative/roles.yml", "<dynamic_role>: example.rollout.deploy")},
    },
    .{
        .name = "variable/Jinja-valued role name: dynamic_role reads without declaration",
        .method = .references,
        .from = m.cursor("negative/roles.yml", "name: \"{{ <dynamic_role> }}\""),
        .include_declaration = false,
        .expected = &.{m.span("negative/roles.yml", "name: \"{{ <dynamic_role> }}\"")},
    },
    .{
        .name = "variable/Jinja-valued role name: dynamic_role reads with declaration",
        .method = .references,
        .from = m.cursor("negative/roles.yml", "name: \"{{ <dynamic_role> }}\""),
        .include_declaration = true,
        .expected = &.{
            m.span("negative/roles.yml", "name: \"{{ <dynamic_role> }}\""),
            m.span("negative/roles.yml", "<dynamic_role>: example.rollout.deploy"),
        },
    },
};

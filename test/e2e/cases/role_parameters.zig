const m = @import("../model.zig");

const play = "playbooks/role-inputs.yml";
const receiver = "ansible_collections/fixture/inputs/roles/receiver/";
const other = "ansible_collections/fixture/other/roles/receiver/";
const specs = receiver ++ "meta/argument_specs.yml";
const main_option = "main:\n    options:\n      <input_value>:";
const setup_option = "setup:\n    options:\n      <input_value>:";
const bindings: []const m.ExpectedLocation = &.{
    m.span(receiver ++ "vars/main.yml", "<input_value>: receiver-vars"),
    m.span(receiver ++ "defaults/main.yml", "<input_value>: receiver-default"),
};

// Two independently enumerated complete answers, shared by all explicit
// origins below. A parameter's role/entry point narrows definition, not
// ADR-0032's Workspace-wide name-based reference search.
const reads: []const m.ExpectedLocation = &.{
    m.span(receiver ++ "tasks/main.yml", "{{ <input_value> }}"),
    m.span(receiver ++ "tasks/setup.yaml", "{{ <input_value> }}"),
    m.span(other ++ "tasks/main.yml", "{{ <input_value> }}"),
};
const reads_and_bindings: []const m.ExpectedLocation = &.{
    m.span(receiver ++ "tasks/main.yml", "{{ <input_value> }}"),
    m.span(receiver ++ "tasks/setup.yaml", "{{ <input_value> }}"),
    m.span(other ++ "tasks/main.yml", "{{ <input_value> }}"),
    m.span(play, "<input_value>: from-roles-map"),
    m.span(play, "<input_value>: from-role-vars"),
    m.span(play, "<input_value>: from-include"),
    m.span(play, "<input_value>: from-task-collection"),
    m.span(play, "<input_value>: from-import"),
    m.span(play, "<input_value>: from-kv-include"),
    m.span(play, "<input_value>: from-unresolved-role"),
    m.span(specs, main_option),
    m.span(specs, setup_option),
    m.span(receiver ++ "vars/main.yml", "<input_value>: receiver-vars"),
    m.span(receiver ++ "defaults/main.yml", "<input_value>: receiver-default"),
    m.span(other ++ "meta/argument_specs.yml", "      <input_value>:"),
    m.span(other ++ "defaults/main.yml", "<input_value>: other-default"),
};

const origins = [_]struct { name: []const u8, at: m.Anchor }{
    .{ .name = "main read", .at = m.cursor(receiver ++ "tasks/main.yml", "{{ <input_value> }}") },
    .{ .name = "setup read", .at = m.cursor(receiver ++ "tasks/setup.yaml", "{{ <input_value> }}") },
    .{ .name = "other role read", .at = m.cursor(other ++ "tasks/main.yml", "{{ <input_value> }}") },
    .{ .name = "roles-map key", .at = m.cursor(play, "<input_value>: from-roles-map") },
    .{ .name = "role-vars key", .at = m.cursor(play, "<input_value>: from-role-vars") },
    .{ .name = "include_role key", .at = m.cursor(play, "<input_value>: from-include") },
    .{ .name = "task-collection key", .at = m.cursor(play, "<input_value>: from-task-collection") },
    .{ .name = "import_role key", .at = m.cursor(play, "<input_value>: from-import") },
    .{ .name = "key-value include key", .at = m.cursor(play, "<input_value>: from-kv-include") },
    .{ .name = "unresolved role key", .at = m.cursor(play, "<input_value>: from-unresolved-role") },
    .{ .name = "main option", .at = m.cursor(specs, main_option) },
    .{ .name = "setup option", .at = m.cursor(specs, setup_option) },
    .{ .name = "role-vars binding", .at = m.cursor(receiver ++ "vars/main.yml", "<input_value>: receiver-vars") },
    .{ .name = "role-default binding", .at = m.cursor(receiver ++ "defaults/main.yml", "<input_value>: receiver-default") },
    .{ .name = "other role option", .at = m.cursor(other ++ "meta/argument_specs.yml", "      <input_value>:") },
    .{ .name = "other role binding", .at = m.cursor(other ++ "defaults/main.yml", "<input_value>: other-default") },
};

fn symmetricReferenceCases() [origins.len * 4]m.Case {
    var cases: [origins.len * 4]m.Case = undefined;
    for (origins, 0..) |origin, i| {
        cases[i * 4] = .{
            .name = "role parameter/references from " ++ origin.name ++ ": reads only",
            .method = .references,
            .from = origin.at,
            .include_declaration = false,
            .expected = reads,
        };
        cases[i * 4 + 1] = .{
            .name = "role parameter/references from " ++ origin.name ++ ": reads and bindings",
            .method = .references,
            .from = origin.at,
            .include_declaration = true,
            .expected = reads_and_bindings,
        };
        cases[i * 4 + 2] = .{
            .name = "role parameter/prepareRename from " ++ origin.name,
            .method = .prepare_rename,
            .from = origin.at,
            .placeholder = "input_value",
            .expected = &.{m.span(origin.at.path, origin.at.snippet)},
        };
        cases[i * 4 + 3] = .{
            .name = "role parameter/rename from " ++ origin.name ++ ": all reads and bindings",
            .method = .rename,
            .from = origin.at,
            .new_name = "renamed_input_value",
            .expected = reads_and_bindings,
        };
    }
    return cases;
}

pub const all = [_]m.Case{
    .{
        .name = "role parameter/yaml metadata fallback: definition opens the option",
        .method = .definition,
        .from = m.cursor(play, "<yaml_input>: from-yaml-role"),
        .expected = &.{m.span("roles/yaml_receiver/meta/main.yaml", "      <yaml_input>:")},
    },
    .{
        .name = "role parameter/yaml role main absent as yml: implementation opens its yaml default",
        .method = .implementation,
        .from = m.cursor(play, "<yaml_input>: from-yaml-role"),
        .expected = &.{m.span("roles/yaml_receiver/defaults/main.yaml", "<yaml_input>: yaml-default")},
    },
    .{
        .name = "role parameter/yaml metadata fallback: hover documents the option",
        .method = .hover,
        .from = m.cursor(play, "<yaml_input>: from-yaml-role"),
        .expected = &.{m.span(play, "<yaml_input>: from-yaml-role")},
        .markdown_contains = &.{ "Receiver input documented in YAML metadata", "meta/main.yaml" },
    },
    .{
        .name = "role parameter/include_role key: definition is the called role option",
        .method = .definition,
        .from = m.cursor(play, "<input_value>: from-include"),
        .expected = &.{m.span(specs, main_option)},
    },
    .{
        .name = "role parameter/include_role key: implementation ranks concrete callee bindings",
        .method = .implementation,
        .from = m.cursor(play, "<input_value>: from-include"),
        .expected = bindings,
    },
    .{
        .name = "role parameter/include_role key: hover documents the main option",
        .method = .hover,
        .from = m.cursor(play, "<input_value>: from-include"),
        .expected = &.{m.span(play, "<input_value>: from-include")},
        .markdown_contains = &.{ "Main receiver input", "entry point `main`" },
        .markdown_excludes = &.{"Setup receiver input"},
    },
    .{
        .name = "role parameter/import_role key: definition honors tasks_from yaml entry point",
        .method = .definition,
        .from = m.cursor(play, "<input_value>: from-import"),
        .expected = &.{m.span(specs, setup_option)},
    },
    .{
        .name = "role parameter/import_role key: implementation is not the role task file",
        .method = .implementation,
        .from = m.cursor(play, "<input_value>: from-import"),
        .expected = bindings,
    },
    .{
        .name = "role parameter/import_role key: hover documents the setup option",
        .method = .hover,
        .from = m.cursor(play, "<input_value>: from-import"),
        .expected = &.{m.span(play, "<input_value>: from-import")},
        .markdown_contains = &.{ "Setup receiver input", "entry point `setup`" },
        .markdown_excludes = &.{"Main receiver input"},
    },
    .{
        .name = "role parameter/key-value include: definition honors tasks_from yml entry point",
        .method = .definition,
        .from = m.cursor(play, "<input_value>: from-kv-include"),
        .expected = &.{m.span(specs, setup_option)},
    },
    .{
        .name = "role parameter/key-value include: implementation ranks callee bindings",
        .method = .implementation,
        .from = m.cursor(play, "<input_value>: from-kv-include"),
        .expected = bindings,
    },
    .{
        .name = "role parameter/roles-map key: definition uses the main option",
        .method = .definition,
        .from = m.cursor(play, "<input_value>: from-roles-map"),
        .expected = &.{m.span(specs, main_option)},
    },
    .{
        .name = "role parameter/roles-map key: implementation ranks callee bindings",
        .method = .implementation,
        .from = m.cursor(play, "<input_value>: from-roles-map"),
        .expected = bindings,
    },
    .{
        .name = "role parameter/role-vars key: definition uses the main option",
        .method = .definition,
        .from = m.cursor(play, "<input_value>: from-role-vars"),
        .expected = &.{m.span(specs, main_option)},
    },
    .{
        .name = "role parameter/role-vars key: implementation ranks callee bindings",
        .method = .implementation,
        .from = m.cursor(play, "<input_value>: from-role-vars"),
        .expected = bindings,
    },
    .{
        .name = "role parameter/task-local collection: definition excludes the same-name receiver",
        .method = .definition,
        .from = m.cursor(play, "<input_value>: from-task-collection"),
        .expected = &.{m.span(other ++ "meta/argument_specs.yml", "      <input_value>:")},
    },
    .{
        .name = "role parameter/task-local collection: implementation excludes the same-name receiver",
        .method = .implementation,
        .from = m.cursor(play, "<input_value>: from-task-collection"),
        .expected = &.{m.span(other ++ "defaults/main.yml", "<input_value>: other-default")},
    },
    .{
        .name = "role parameter/task-local collection: hover documents the selected receiver",
        .method = .hover,
        .from = m.cursor(play, "<input_value>: from-task-collection"),
        .expected = &.{m.span(play, "<input_value>: from-task-collection")},
        .markdown_contains = &.{"Other receiver input"},
        .markdown_excludes = &.{"Main receiver input"},
    },
    .{
        .name = "role parameter/schema-only input: definition opens the contract",
        .method = .definition,
        .from = m.cursor(play, "<receiver_declared_only>: provided-schema-only"),
        .expected = &.{m.span(specs, "      <receiver_declared_only>:")},
    },
    .{
        .name = "role parameter/schema-only input: no concrete callee implementation",
        .method = .implementation,
        .from = m.cursor(play, "<receiver_declared_only>: provided-schema-only"),
        .expected = &.{},
    },
    .{
        .name = "role parameter/unresolved role: implementation never borrows another callee's value",
        .method = .implementation,
        .from = m.cursor(play, "<input_value>: from-unresolved-role"),
        .expected = &.{},
    },
} ++ symmetricReferenceCases();

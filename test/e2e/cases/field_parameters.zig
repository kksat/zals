const m = @import("../model.zig");
const play = "playbooks/field-inputs.yml";
const receiver = "ansible_collections/fixture/inputs/roles/receiver/";
const other = "ansible_collections/fixture/other/roles/receiver/";
const specs = receiver ++ "meta/argument_specs.yml";
const yaml_role = "roles/yaml_receiver/";
const main_leaf = "              <region_name>:\n                type: str\n                description: Main endpoint region contract.";
const setup_leaf = "              <region_name>:\n                type: str\n                description: Setup endpoint region contract.";
const wrong_root_leaf = "              <region_name>:\n                type: str\n                description: Wrong root region contract.";
const list_leaf = "              <region_name>:\n                type: str\n                description: List endpoint region contract.";
const other_leaf = "              <region_name>:\n                type: str\n                description: Other endpoint region contract.";
const yaml_leaf = "              \"<region_name>\":\n                type: str\n                description: YAML endpoint region contract.";
const bindings: []const m.ExpectedLocation = &.{
    m.span(receiver ++ "vars/main.yml", "    <region_name>: receiver-region-vars"),
    m.span(receiver ++ "defaults/main.yml", "    <region_name>: receiver-region-default"),
};

// These two complete lists are independently authored. Callee/path/entry-point
// context changes contracts and implementations, NEVER reference membership.
const reads: []const m.ExpectedLocation = &.{
    m.span(receiver ++ "tasks/main.yml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(receiver ++ "tasks/setup.yaml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(other ++ "tasks/main.yml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(play, "{{ local.<region_name> }}"),
};
const reads_and_declarations: []const m.ExpectedLocation = &.{
    m.span(receiver ++ "tasks/main.yml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(receiver ++ "tasks/setup.yaml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(other ++ "tasks/main.yml", "{{ input_config.endpoint.<region_name> }}"),
    m.span(play, "{{ local.<region_name> }}"),
    m.span(play, "          <region_name>: passed-role-map-region"),
    m.span(play, "            <region_name>: passed-role-vars-region"),
    m.span(play, "            <region_name>: passed-main-region"),
    m.span(play, "            <region_name>: passed-setup-region"),
    m.span(play, "            <region_name>: passed-kv-region"),
    m.span(play, "            <region_name>: passed-other-region"),
    m.span(play, "              <region_name>: passed-list-region"),
    m.span(play, "            \"<region_name>\": passed-yaml-region"),
    m.span(play, "            <region_name>: unresolved-region"),
    m.span(play, "            <region_name>: wrong-path-region"),
    m.span(play, "            <region_name>: non-role-vars-region"),
    m.span(receiver ++ "vars/main.yml", "    <region_name>: receiver-region-vars"),
    m.span(receiver ++ "defaults/main.yml", "    <region_name>: receiver-region-default"),
    m.span(receiver ++ "defaults/main.yml", "    <region_name>: wrong-root-region"),
    m.span(receiver ++ "defaults/main.yml", "      <region_name>: receiver-list-region"),
    m.span(other ++ "defaults/main.yml", "    <region_name>: other-region-default"),
    m.span(yaml_role ++ "defaults/main.yaml", "    \"<region_name>\": yaml-region-default"),
    m.span(specs, main_leaf),
    m.span(specs, setup_leaf),
    m.span(specs, wrong_root_leaf),
    m.span(specs, list_leaf),
    m.span(other ++ "meta/argument_specs.yml", other_leaf),
    m.span(yaml_role ++ "meta/main.yaml", yaml_leaf),
};
const reference_origins = [_]struct { name: []const u8, at: m.Anchor }{
    .{ .name = "main read", .at = m.cursor(receiver ++ "tasks/main.yml", "{{ input_config.endpoint.<region_name> }}") },
    .{ .name = "setup read", .at = m.cursor(receiver ++ "tasks/setup.yaml", "{{ input_config.endpoint.<region_name> }}") },
    .{ .name = "other role read", .at = m.cursor(other ++ "tasks/main.yml", "{{ input_config.endpoint.<region_name> }}") },
    .{ .name = "ordinary local read", .at = m.cursor(play, "{{ local.<region_name> }}") },
    .{ .name = "roles-map key", .at = m.cursor(play, "          <region_name>: passed-role-map-region") },
    .{ .name = "role-vars key", .at = m.cursor(play, "            <region_name>: passed-role-vars-region") },
    .{ .name = "include key", .at = m.cursor(play, "            <region_name>: passed-main-region") },
    .{ .name = "import key", .at = m.cursor(play, "            <region_name>: passed-setup-region") },
    .{ .name = "key-value include key", .at = m.cursor(play, "            <region_name>: passed-kv-region") },
    .{ .name = "task-collection key", .at = m.cursor(play, "            <region_name>: passed-other-region") },
    .{ .name = "list element key", .at = m.cursor(play, "              <region_name>: passed-list-region") },
    .{ .name = "quoted YAML role key", .at = m.cursor(play, "            \"<region_name>\": passed-yaml-region") },
    .{ .name = "unresolved role key", .at = m.cursor(play, "            <region_name>: unresolved-region") },
    .{ .name = "wrong intermediate path key", .at = m.cursor(play, "            <region_name>: wrong-path-region") },
    .{ .name = "ordinary task-vars key", .at = m.cursor(play, "            <region_name>: non-role-vars-region") },
    .{ .name = "vars binding", .at = m.cursor(receiver ++ "vars/main.yml", "    <region_name>: receiver-region-vars") },
    .{ .name = "default binding", .at = m.cursor(receiver ++ "defaults/main.yml", "    <region_name>: receiver-region-default") },
    .{ .name = "wrong-root binding", .at = m.cursor(receiver ++ "defaults/main.yml", "    <region_name>: wrong-root-region") },
    .{ .name = "list binding", .at = m.cursor(receiver ++ "defaults/main.yml", "      <region_name>: receiver-list-region") },
    .{ .name = "other role binding", .at = m.cursor(other ++ "defaults/main.yml", "    <region_name>: other-region-default") },
    .{ .name = "YAML role binding", .at = m.cursor(yaml_role ++ "defaults/main.yaml", "    \"<region_name>\": yaml-region-default") },
    .{ .name = "main option", .at = m.cursor(specs, main_leaf) },
    .{ .name = "setup option", .at = m.cursor(specs, setup_leaf) },
    .{ .name = "wrong-root option", .at = m.cursor(specs, wrong_root_leaf) },
    .{ .name = "list option", .at = m.cursor(specs, list_leaf) },
    .{ .name = "other role option", .at = m.cursor(other ++ "meta/argument_specs.yml", other_leaf) },
    .{ .name = "YAML role option", .at = m.cursor(yaml_role ++ "meta/main.yaml", yaml_leaf) },
};
fn referenceCases() [reference_origins.len * 2]m.Case {
    var out: [reference_origins.len * 2]m.Case = undefined;
    for (reference_origins, 0..) |origin, i| {
        out[i * 2] = .{ .name = "field parameter/references from " ++ origin.name ++ ": reads", .method = .references, .from = origin.at, .include_declaration = false, .expected = reads };
        out[i * 2 + 1] = .{ .name = "field parameter/references from " ++ origin.name ++ ": reads and declarations", .method = .references, .from = origin.at, .include_declaration = true, .expected = reads_and_declarations };
    }
    return out;
}

const passed_origins = [_]struct {
    name: []const u8,
    at: m.Anchor,
    definition: m.ExpectedLocation,
    implementation: []const m.ExpectedLocation,
    description: []const u8,
    not_description: []const u8,
    entry: []const u8,
    full_path: []const u8 = "input_config.endpoint.region_name",
}{
    .{ .name = "roles-map", .at = m.cursor(play, "          <region_name>: passed-role-map-region"), .definition = m.span(specs, main_leaf), .implementation = bindings, .description = "Main endpoint region contract.", .not_description = "Wrong root region contract.", .entry = "main" },
    .{ .name = "role-vars", .at = m.cursor(play, "            <region_name>: passed-role-vars-region"), .definition = m.span(specs, main_leaf), .implementation = bindings, .description = "Main endpoint region contract.", .not_description = "Setup endpoint region contract.", .entry = "main" },
    .{ .name = "include", .at = m.cursor(play, "            <region_name>: passed-main-region"), .definition = m.span(specs, main_leaf), .implementation = bindings, .description = "Main endpoint region contract.", .not_description = "Wrong root region contract.", .entry = "main" },
    .{ .name = "import selected entry", .at = m.cursor(play, "            <region_name>: passed-setup-region"), .definition = m.span(specs, setup_leaf), .implementation = bindings, .description = "Setup endpoint region contract.", .not_description = "Main endpoint region contract.", .entry = "setup" },
    .{ .name = "key-value include", .at = m.cursor(play, "            <region_name>: passed-kv-region"), .definition = m.span(specs, setup_leaf), .implementation = bindings, .description = "Setup endpoint region contract.", .not_description = "Main endpoint region contract.", .entry = "setup" },
    .{ .name = "task-collection override", .at = m.cursor(play, "            <region_name>: passed-other-region"), .definition = m.span(other ++ "meta/argument_specs.yml", other_leaf), .implementation = &.{m.span(other ++ "defaults/main.yml", "    <region_name>: other-region-default")}, .description = "Other endpoint region contract.", .not_description = "Main endpoint region contract.", .entry = "main" },
    .{ .name = "list element", .at = m.cursor(play, "              <region_name>: passed-list-region"), .definition = m.span(specs, list_leaf), .implementation = &.{m.span(receiver ++ "defaults/main.yml", "      <region_name>: receiver-list-region")}, .description = "List endpoint region contract.", .not_description = "Main endpoint region contract.", .entry = "main", .full_path = "input_configs.endpoint.region_name" },
    .{ .name = "YAML quoted key", .at = m.cursor(play, "            \"<region_name>\": passed-yaml-region"), .definition = m.span(yaml_role ++ "meta/main.yaml", yaml_leaf), .implementation = &.{m.span(yaml_role ++ "defaults/main.yaml", "    \"<region_name>\": yaml-region-default")}, .description = "YAML endpoint region contract.", .not_description = "Main endpoint region contract.", .entry = "main" },
};
fn passedCases() [passed_origins.len * 3]m.Case {
    var out: [passed_origins.len * 3]m.Case = undefined;
    for (passed_origins, 0..) |origin, i| {
        out[i * 3] = .{ .name = "field parameter/" ++ origin.name ++ ": exact full-path contract", .method = .definition, .from = origin.at, .expected = &.{origin.definition} };
        out[i * 3 + 1] = .{ .name = "field parameter/" ++ origin.name ++ ": only ranked concrete callee path", .method = .implementation, .from = origin.at, .expected = origin.implementation };
        out[i * 3 + 2] = .{
            .name = "field parameter/" ++ origin.name ++ ": only selected contract hover",
            .method = .hover,
            .from = origin.at,
            .expected = &.{m.span(origin.at.path, origin.at.snippet)},
            .markdown_contains = &.{ "**Role parameter field** `" ++ origin.full_path ++ "`", origin.description, "entry point `" ++ origin.entry ++ "`" },
            .markdown_excludes = &.{ origin.not_description, "No definition found" },
        };
    }
    return out;
}

const schema_only = m.cursor(play, "            <declared_only_region>: passed-schema-only-region");
const schema_leaf = "              <declared_only_region>:\n                type: str\n                description: Schema-only endpoint region contract.";
const endpoint = m.cursor(play, "          <endpoint>:\n            region_name: passed-main-region");
const endpoint_spec = "          <endpoint>:\n            type: dict\n            options:\n              region_name:\n                type: str\n                description: Main endpoint region contract.";
pub const all = passedCases() ++ referenceCases() ++ [_]m.Case{
    .{ .name = "field parameter/schema-only: exact schema definition", .method = .definition, .from = schema_only, .expected = &.{m.span(specs, schema_leaf)} },
    .{ .name = "field parameter/schema-only: caller's supplied value is not callee implementation", .method = .implementation, .from = schema_only, .expected = &.{} },
    .{ .name = "field parameter/schema-only: no reads", .method = .references, .from = schema_only, .include_declaration = false, .expected = &.{} },
    .{ .name = "field parameter/schema-only: complete declarations", .method = .references, .from = schema_only, .include_declaration = true, .expected = &.{ m.span(play, "            <declared_only_region>: passed-schema-only-region"), m.span(specs, schema_leaf) } },
    .{ .name = "field parameter/schema-only option: no reads", .method = .references, .from = m.cursor(specs, schema_leaf), .include_declaration = false, .expected = &.{} },
    .{ .name = "field parameter/schema-only option: same complete declarations", .method = .references, .from = m.cursor(specs, schema_leaf), .include_declaration = true, .expected = &.{ m.span(play, "            <declared_only_region>: passed-schema-only-region"), m.span(specs, schema_leaf) } },
    .{
        .name = "field parameter/schema-only: documented hover",
        .method = .hover,
        .from = schema_only,
        .expected = &.{m.span(play, "            <declared_only_region>: passed-schema-only-region")},
        .markdown_contains = &.{ "**Role parameter field** `input_config.endpoint.declared_only_region`", "Schema-only endpoint region contract." },
        .markdown_excludes = &.{"receiver-region-default"},
    },
    .{
        .name = "field parameter/no schema: concrete callee path still implements the field",
        .method = .implementation,
        .from = m.cursor(play, "            <concrete_only_region>: passed-without-schema"),
        .expected = &.{m.span(receiver ++ "defaults/main.yml", "    <concrete_only_region>: receiver-without-schema")},
    },
    .{
        .name = "field parameter/no schema: definition retains ordinary field fallback",
        .method = .definition,
        .from = m.cursor(play, "            <concrete_only_region>: passed-without-schema"),
        .expected = &.{ m.span(play, "            <concrete_only_region>: passed-without-schema"), m.span(receiver ++ "defaults/main.yml", "    <concrete_only_region>: receiver-without-schema") },
    },
    .{
        .name = "field parameter/no schema: hover does not claim a callee contract",
        .method = .hover,
        .from = m.cursor(play, "            <concrete_only_region>: passed-without-schema"),
        .expected = &.{m.span(play, "            <concrete_only_region>: passed-without-schema")},
        .markdown_contains = &.{ "**Variable field** `concrete_only_region`", "passed-without-schema", "receiver-without-schema" },
        .markdown_excludes = &.{ "**Role parameter field**", "No definition found" },
    },
    .{
        .name = "field parameter/unresolved: fallback hover is not a guessed callee contract",
        .method = .hover,
        .from = m.cursor(play, "            <region_name>: unresolved-region"),
        .expected = &.{m.span(play, "            <region_name>: unresolved-region")},
        .markdown_contains = &.{"**Variable field** `region_name`"},
        .markdown_excludes = &.{"**Role parameter field**"},
    },
    .{
        .name = "field parameter/nonmatching intermediate path: fallback hover does not assert a contract",
        .method = .hover,
        .from = m.cursor(play, "            <region_name>: wrong-path-region"),
        .expected = &.{m.span(play, "            <region_name>: wrong-path-region")},
        .markdown_contains = &.{"**Variable field** `region_name`"},
        .markdown_excludes = &.{"**Role parameter field**"},
    },
    .{ .name = "field parameter/unresolved: no guessed implementation", .method = .implementation, .from = m.cursor(play, "            <region_name>: unresolved-region"), .expected = &.{} },
    .{ .name = "field parameter/nonmatching intermediate path: no leaf-name implementation", .method = .implementation, .from = m.cursor(play, "            <region_name>: wrong-path-region"), .expected = &.{} },
    .{
        .name = "field parameter/ordinary task-vars control: not a callee contract",
        .method = .hover,
        .from = m.cursor(play, "            <region_name>: non-role-vars-region"),
        .expected = &.{m.span(play, "            <region_name>: non-role-vars-region")},
        .markdown_contains = &.{"**Variable field** `region_name`"},
        .markdown_excludes = &.{"**Role parameter field**"},
    },
    .{ .name = "field parameter/intermediate dictionary key: its own schema option", .method = .definition, .from = endpoint, .expected = &.{m.span(specs, endpoint_spec)} },
    .{ .name = "field parameter/intermediate dictionary key: exact callee mapping keys", .method = .implementation, .from = endpoint, .expected = &.{ m.span(receiver ++ "vars/main.yml", "  <endpoint>:\n    region_name: receiver-region-vars"), m.span(receiver ++ "defaults/main.yml", "  <endpoint>:\n    region_name: receiver-region-default") } },
};

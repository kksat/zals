const m = @import("../model.zig");

const tasks = "roles/field_nav/tasks/main.yml";
const specs = "roles/field_nav/meta/argument_specs.yml";
const defaults = "roles/field_nav/defaults/main.yml";
const vars = "roles/field_nav/vars/main.yml";

// Separate authored answers, never assembled from server output or by adding
// declarations to the reads-only oracle. Receiver/root names are immaterial.
const reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 {{ field_item.<resourcegroup_name> }} /"),
    m.span(tasks, "/ {{ field_backup.<resourcegroup_name> }}"),
    m.span(tasks, "🛰 {{ static_item['<resourcegroup_name>'] }} /"),
    m.span(tasks, "/ {{ static_backup[\"<resourcegroup_name>\"] }}"),
};
const reads_and_declarations: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 {{ field_item.<resourcegroup_name> }} /"),
    m.span(tasks, "/ {{ field_backup.<resourcegroup_name> }}"),
    m.span(defaults, "  - <resourcegroup_name>: default-group"),
    m.span(specs, "          <resourcegroup_name>:"),
    m.span(vars, "  \"<resourcegroup_name>\": vars-group"),
    m.span(tasks, "🛰 {{ static_item['<resourcegroup_name>'] }} /"),
    m.span(tasks, "/ {{ static_backup[\"<resourcegroup_name>\"] }}"),
};
const definitions: []const m.ExpectedLocation = &.{
    m.span(vars, "  \"<resourcegroup_name>\": vars-group"),
    m.span(defaults, "  - <resourcegroup_name>: default-group"),
    m.span(specs, "          <resourcegroup_name>:"),
};
const implementations: []const m.ExpectedLocation = &.{
    m.span(vars, "  \"<resourcegroup_name>\": vars-group"),
    m.span(defaults, "  - <resourcegroup_name>: default-group"),
};
const origins = [_]struct { name: []const u8, at: m.Anchor }{
    .{ .name = "list receiver read", .at = m.cursor(tasks, "🛰 {{ field_item.<resourcegroup_name> }} /") },
    .{ .name = "unrelated receiver read", .at = m.cursor(tasks, "/ {{ field_backup.<resourcegroup_name> }}") },
    .{ .name = "default list key", .at = m.cursor(defaults, "  - <resourcegroup_name>: default-group") },
    .{ .name = "quoted vars key", .at = m.cursor(vars, "  \"<resourcegroup_name>\": vars-group") },
    .{ .name = "nested argument-spec option", .at = m.cursor(specs, "          <resourcegroup_name>:") },
    .{ .name = "single-quoted subscript", .at = m.cursor(tasks, "🛰 {{ static_item['<resourcegroup_name>'] }} /") },
    .{ .name = "double-quoted subscript", .at = m.cursor(tasks, "/ {{ static_backup[\"<resourcegroup_name>\"] }}") },
};

fn ordinaryCases() [origins.len * 5]m.Case {
    var out: [origins.len * 5]m.Case = undefined;
    for (origins, 0..) |origin, i| {
        out[i * 5] = .{ .name = "field/from " ++ origin.name ++ ": reads only", .method = .references, .from = origin.at, .include_declaration = false, .expected = reads };
        out[i * 5 + 1] = .{ .name = "field/from " ++ origin.name ++ ": reads and declarations", .method = .references, .from = origin.at, .include_declaration = true, .expected = reads_and_declarations };
        out[i * 5 + 2] = .{ .name = "field/from " ++ origin.name ++ ": ordered parsed definitions", .method = .definition, .from = origin.at, .expected = definitions };
        out[i * 5 + 3] = .{ .name = "field/from " ++ origin.name ++ ": ordered concrete implementations", .method = .implementation, .from = origin.at, .expected = implementations };
        out[i * 5 + 4] = .{
            .name = "field/from " ++ origin.name ++ ": values and nested option documentation",
            .method = .hover,
            .from = origin.at,
            .expected = &.{m.span(origin.at.path, origin.at.snippet)},
            .markdown_contains = &.{ "**Variable field** `resourcegroup_name`", "**Active:** `vars-group`", "**Shadowed:**", "default-group", "Resource group field contract." },
            .markdown_excludes = &.{ "No definition found", "Ansible task keyword" },
        };
    }
    return out;
}

const schema_only_origins = [_]struct { name: []const u8, at: m.Anchor }{
    .{ .name = "read", .at = m.cursor(tasks, "{{ field_item.<declared_only_field> }}") },
    .{ .name = "option", .at = m.cursor(specs, "          <declared_only_field>:") },
};
fn schemaOnlyCases() [schema_only_origins.len * 5]m.Case {
    var out: [schema_only_origins.len * 5]m.Case = undefined;
    for (schema_only_origins, 0..) |origin, i| {
        out[i * 5] = .{
            .name = "field/schema-only " ++ origin.name ++ ": references without declarations",
            .method = .references,
            .from = origin.at,
            .include_declaration = false,
            .expected = &.{m.span(tasks, "{{ field_item.<declared_only_field> }}")},
        };
        out[i * 5 + 1] = .{
            .name = "field/schema-only " ++ origin.name ++ ": references with declarations",
            .method = .references,
            .from = origin.at,
            .include_declaration = true,
            .expected = &.{ m.span(tasks, "{{ field_item.<declared_only_field> }}"), m.span(specs, "          <declared_only_field>:") },
        };
        out[i * 5 + 2] = .{ .name = "field/schema-only " ++ origin.name ++ ": definition", .method = .definition, .from = origin.at, .expected = &.{m.span(specs, "          <declared_only_field>:")} };
        out[i * 5 + 3] = .{ .name = "field/schema-only " ++ origin.name ++ ": no concrete implementation", .method = .implementation, .from = origin.at, .expected = &.{} };
        out[i * 5 + 4] = .{
            .name = "field/schema-only " ++ origin.name ++ ": description hover",
            .method = .hover,
            .from = origin.at,
            .expected = &.{m.span(origin.at.path, origin.at.snippet)},
            .markdown_contains = &.{ "**Variable field** `declared_only_field`", "Schema-only field contract." },
            .markdown_excludes = &.{ "No definition found", "default-group", "vars-group" },
        };
    }
    return out;
}

fn escapedKeyCases() [10]m.Case {
    var out: [10]m.Case = undefined;
    const escaped_origins = [_]struct { name: []const u8, at: m.Anchor }{
        .{ .name = "read", .at = m.cursor(tasks, "{{ escaped_item.<escaped_key> }}") },
        .{ .name = "escaped declaration", .at = m.cursor(vars, "  \"<\\u0065scaped_key>\": escaped-value") },
    };
    for (escaped_origins, 0..) |origin, i| {
        out[i * 5] = .{ .name = "field/escaped YAML key from " ++ origin.name ++ ": reads", .method = .references, .from = origin.at, .include_declaration = false, .expected = &.{m.span(tasks, "{{ escaped_item.<escaped_key> }}")} };
        out[i * 5 + 1] = .{ .name = "field/escaped YAML key from " ++ origin.name ++ ": quote-free declaration", .method = .references, .from = origin.at, .include_declaration = true, .expected = &.{ m.span(tasks, "{{ escaped_item.<escaped_key> }}"), m.span(vars, "  \"<\\u0065scaped_key>\": escaped-value") } };
        out[i * 5 + 2] = .{ .name = "field/escaped YAML key from " ++ origin.name ++ ": quote-free definition", .method = .definition, .from = origin.at, .expected = &.{m.span(vars, "  \"<\\u0065scaped_key>\": escaped-value")} };
        out[i * 5 + 3] = .{ .name = "field/escaped YAML key from " ++ origin.name ++ ": quote-free implementation", .method = .implementation, .from = origin.at, .expected = &.{m.span(vars, "  \"<\\u0065scaped_key>\": escaped-value")} };
        out[i * 5 + 4] = .{ .name = "field/escaped YAML key from " ++ origin.name ++ ": parsed value hover", .method = .hover, .from = origin.at, .expected = &.{m.span(origin.at.path, origin.at.snippet)}, .markdown_contains = &.{ "**Variable field** `escaped_key`", "escaped-value" } };
    }
    return out;
}

fn reservedDataCases() [40]m.Case {
    const groups = [_]struct { name: []const u8, read: m.Anchor, key: m.Anchor, value: []const u8 }{
        .{ .name = "task vars", .read = m.cursor(tasks, "{{ record.<reserved_leaf> }}"), .key = m.cursor(tasks, "          <reserved_leaf>: present-once"), .value = "present-once" },
        .{ .name = "vars file", .read = m.cursor(tasks, "{{ record.<loaded_reserved_leaf> }}"), .key = m.cursor("playbooks/vars/reserved.yml", "      <loaded_reserved_leaf>: loaded-once"), .value = "loaded-once" },
        .{ .name = "set_fact", .read = m.cursor(tasks, "{{ record.<set_fact_reserved_leaf> }}"), .key = m.cursor(tasks, "          <set_fact_reserved_leaf>: fact-once"), .value = "fact-once" },
        .{ .name = "role parameter", .read = m.cursor("playbooks/field-inputs.yml", "{{ record.<call_reserved_leaf> }}"), .key = m.cursor("playbooks/field-inputs.yml", "            <call_reserved_leaf>: role-data-once"), .value = "role-data-once" },
    };
    var out: [40]m.Case = undefined;
    for (groups, 0..) |group, g| {
        const from = [_]m.Anchor{ group.read, group.key };
        for (from, 0..) |origin, n| {
            const i = g * 10 + n * 5;
            out[i] = .{ .name = "field/reserved data under " ++ group.name ++ ": symmetric reads", .method = .references, .from = origin, .include_declaration = false, .expected = &.{m.span(group.read.path, group.read.snippet)} };
            out[i + 1] = .{ .name = "field/reserved data under " ++ group.name ++ ": exactly one declaration", .method = .references, .from = origin, .include_declaration = true, .expected = &.{ m.span(group.read.path, group.read.snippet), m.span(group.key.path, group.key.snippet) } };
            out[i + 2] = .{ .name = "field/reserved data under " ++ group.name ++ ": exactly one definition", .method = .definition, .from = origin, .expected = &.{m.span(group.key.path, group.key.snippet)} };
            out[i + 3] = .{ .name = "field/reserved data under " ++ group.name ++ ": concrete implementation respects binding context", .method = .implementation, .from = origin, .expected = if (g == 3 and n == 1) &.{} else &.{m.span(group.key.path, group.key.snippet)} };
            out[i + 4] = .{ .name = "field/reserved data under " ++ group.name ++ ": one candidate hover", .method = .hover, .from = origin, .expected = &.{m.span(origin.path, origin.snippet)}, .markdown_contains = &.{group.value}, .markdown_excludes = &.{"**Shadowed:**"} };
        }
    }
    return out;
}

const called = m.cursor(tasks, "{{ field_item.<resourcegroup_name>() }}");
const description = m.cursor(specs, "            <description>: Resource group field contract.");
const unbound = m.cursor(tasks, "{{ field_item.<unbound_field> }}");
const root = m.cursor(tasks, "/ {{ <unbound_field> }}");
pub const all = ordinaryCases() ++ schemaOnlyCases() ++ escapedKeyCases() ++ reservedDataCases() ++ [_]m.Case{
    .{ .name = "field/module argument control: no definition", .method = .definition, .from = m.cursor("negative/field-module-options.yml", "{{ record.<module_data_leaf> }}"), .expected = &.{} },
    .{ .name = "field/module argument control: no implementation", .method = .implementation, .from = m.cursor("negative/field-module-options.yml", "{{ record.<module_data_leaf> }}"), .expected = &.{} },
    .{ .name = "field/module argument control: hover cannot use nonbinding data", .method = .hover, .from = m.cursor("negative/field-module-options.yml", "{{ record.<module_data_leaf> }}"), .expected = &.{m.span("negative/field-module-options.yml", "{{ record.<module_data_leaf> }}")}, .markdown_contains = &.{"No definition found"}, .markdown_excludes = &.{"module-option-not-binding"} },
    .{ .name = "field/module argument key: no reads", .method = .references, .from = m.cursor("negative/field-module-options.yml", "          <module_data_leaf>: module-option-not-binding"), .include_declaration = false, .expected = &.{} },
    .{ .name = "field/module argument key: no declarations", .method = .references, .from = m.cursor("negative/field-module-options.yml", "          <module_data_leaf>: module-option-not-binding"), .include_declaration = true, .expected = &.{} },
    .{ .name = "field/module argument key: no definition", .method = .definition, .from = m.cursor("negative/field-module-options.yml", "          <module_data_leaf>: module-option-not-binding"), .expected = &.{} },
    .{ .name = "field/module argument key: no implementation", .method = .implementation, .from = m.cursor("negative/field-module-options.yml", "          <module_data_leaf>: module-option-not-binding"), .expected = &.{} },
    .{ .name = "field/module argument key: no field hover", .method = .hover, .from = m.cursor("negative/field-module-options.yml", "          <module_data_leaf>: module-option-not-binding"), .expected = &.{} },
    .{
        .name = "field/module argument reserved key: not a variable-value binding",
        .method = .references,
        .from = m.cursor("negative/field-module-options.yml", "{{ record.<module_data_leaf> }}"),
        .include_declaration = true,
        .expected = &.{m.span("negative/field-module-options.yml", "{{ record.<module_data_leaf> }}")},
    },
    .{
        .name = "field/role parameter reserved data key: a value is not role entry directives",
        .method = .references,
        .from = m.cursor("playbooks/field-inputs.yml", "{{ record.<call_reserved_leaf> }}"),
        .include_declaration = true,
        .expected = &.{ m.span("playbooks/field-inputs.yml", "{{ record.<call_reserved_leaf> }}"), m.span("playbooks/field-inputs.yml", "            <call_reserved_leaf>: role-data-once") },
    },
    .{
        .name = "field/set_fact reserved data key: structured fact value is not directives",
        .method = .references,
        .from = m.cursor(tasks, "{{ record.<set_fact_reserved_leaf> }}"),
        .include_declaration = true,
        .expected = &.{ m.span(tasks, "{{ record.<set_fact_reserved_leaf> }}"), m.span(tasks, "          <set_fact_reserved_leaf>: fact-once") },
    },
    .{
        .name = "field/vars-file reserved data key: top-level variables are not directives",
        .method = .references,
        .from = m.cursor(tasks, "{{ record.<loaded_reserved_leaf> }}"),
        .include_declaration = true,
        .expected = &.{ m.span(tasks, "{{ record.<loaded_reserved_leaf> }}"), m.span("playbooks/vars/reserved.yml", "      <loaded_reserved_leaf>: loaded-once") },
    },
    .{
        .name = "field/reserved data key: one parsed declaration not a repeated binding map",
        .method = .references,
        .from = m.cursor(tasks, "{{ record.<reserved_leaf> }}"),
        .include_declaration = true,
        .expected = &.{ m.span(tasks, "{{ record.<reserved_leaf> }}"), m.span(tasks, "          <reserved_leaf>: present-once") },
    },
    .{ .name = "field/called member: no references without declarations", .method = .references, .from = called, .include_declaration = false, .expected = &.{} },
    .{ .name = "field/called member: no references with declarations", .method = .references, .from = called, .include_declaration = true, .expected = &.{} },
    .{ .name = "field/called member: no field definition", .method = .definition, .from = called, .expected = &.{} },
    .{ .name = "field/called member: no field implementation", .method = .implementation, .from = called, .expected = &.{} },
    .{ .name = "field/called member: no field hover", .method = .hover, .from = called, .expected = &.{} },
    .{ .name = "field/metadata description: no reads", .method = .references, .from = description, .include_declaration = false, .expected = &.{} },
    .{ .name = "field/metadata description: not a field declaration", .method = .references, .from = description, .include_declaration = true, .expected = &.{} },
    .{ .name = "field/metadata description: no field definition", .method = .definition, .from = description, .expected = &.{} },
    .{ .name = "field/metadata description: no field implementation", .method = .implementation, .from = description, .expected = &.{} },
    .{ .name = "field/metadata description: no field hover", .method = .hover, .from = description, .expected = &.{} },
    .{ .name = "field/unbound: only its own field read", .method = .references, .from = unbound, .include_declaration = false, .expected = &.{m.span(tasks, "{{ field_item.<unbound_field> }}")} },
    .{ .name = "field/unbound: root key is not a field declaration", .method = .references, .from = unbound, .include_declaration = true, .expected = &.{m.span(tasks, "{{ field_item.<unbound_field> }}")} },
    .{ .name = "field/unbound: root definition is not a field definition", .method = .definition, .from = unbound, .expected = &.{} },
    .{ .name = "field/unbound: root value is not a field implementation", .method = .implementation, .from = unbound, .expected = &.{} },
    .{
        .name = "field/unbound: hover excludes the same-named root value",
        .method = .hover,
        .from = unbound,
        .expected = &.{m.span(tasks, "{{ field_item.<unbound_field> }}")},
        .markdown_contains = &.{ "**Variable field** `unbound_field`", "No definition found" },
        .markdown_excludes = &.{"unrelated-root-value"},
    },
    .{ .name = "field/root control: reads exclude the member", .method = .references, .from = root, .include_declaration = false, .expected = &.{m.span(tasks, "/ {{ <unbound_field> }}")} },
    .{ .name = "field/root control: declarations exclude the member", .method = .references, .from = root, .include_declaration = true, .expected = &.{ m.span(tasks, "/ {{ <unbound_field> }}"), m.span(defaults, "<unbound_field>: unrelated-root-value") } },
    .{ .name = "field/root control: definition remains a root key", .method = .definition, .from = root, .expected = &.{m.span(defaults, "<unbound_field>: unrelated-root-value")} },
    .{ .name = "field/root control: implementation remains a root value", .method = .implementation, .from = root, .expected = &.{m.span(defaults, "<unbound_field>: unrelated-root-value")} },
    .{
        .name = "field/root control: hover remains a root value",
        .method = .hover,
        .from = root,
        .expected = &.{m.span(tasks, "/ {{ <unbound_field> }}")},
        .markdown_contains = &.{ "**Variable** `unbound_field`", "unrelated-root-value" },
        .markdown_excludes = &.{"**Variable field**"},
    },
    .{
        .name = "field/vars-file mapping: metadata names are not field declarations",
        .method = .references,
        .from = m.cursor("ansible_collections/example/rollout/roles/verify/tasks/main.yml", "{{ service.<name> | default('unnamed') }}"),
        .include_declaration = true,
        .expected = &.{
            m.span("ansible_collections/example/rollout/roles/verify/tasks/main.yml", "{{ service.<name> | default('unnamed') }}"),
            m.span("playbooks/vars/release.yml", "  <name>: rollout-api"),
        },
    },
    .{
        .name = "field/non-match: requirements metadata name is not a variable value key",
        .method = .references,
        .from = m.cursor("requirements.yml", "- <name>: fixture.missing"),
        .include_declaration = true,
        .expected = &.{},
    },
};

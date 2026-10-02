//! Independent, read-only field-expression contract at the public stdio LSP seam.
//! Oracles are authored spans, never discovered from server output or fixture scans.
const std = @import("std");
const m = @import("e2e/model.zig");
const anchor = @import("e2e/anchor.zig");
const lsp = @import("e2e/client.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const defaults = "roles/expressions/defaults/main.yml";
const tasks = "roles/expressions/tasks/main.yml";

const quoted_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 {{ record.<field_name> }} /"),
    m.span(tasks, "{{ other['<field_name>'] }}"),
    m.span(tasks, "{{ spare[\"<field_name>\"] }}"),
};
const quoted_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 {{ record.<field_name> }} /"),
    m.span(tasks, "{{ other['<field_name>'] }}"),
    m.span(tasks, "{{ spare[\"<field_name>\"] }}"),
    m.span(defaults, "  - <field_name>: first"),
    m.span(defaults, "  <field_name>: second"),
};

test "stdio static quoted subscripts share the dot-read and binding-key field group" {
    try checkGroup(&.{
        m.cursor(tasks, "🛰 {{ record.<field_name> }} /"),
        m.cursor(tasks, "{{ other['<field_name>'] }}"),
        m.cursor(tasks, "{{ spare[\"<field_name>\"] }}"),
        m.cursor(defaults, "  - <field_name>: first"),
        m.cursor(defaults, "  <field_name>: second"),
    }, quoted_reads, quoted_with_definitions);
}

const yaml_template = "roles/expressions/templates/yaml-quotes.j2";
const yaml_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 yaml-single {{ object[''<yaml_field>''] }}"),
    m.span(tasks, "when: 'object[''<yaml_field>''] == ''single-active'''"),
    m.span(tasks, "🛰 yaml-double {{ object[\\\"<yaml_field>\\\"] }}"),
    m.span(tasks, "when: \"object[\\\"<yaml_field>\\\"] == \\\"double-active\\\"\""),
    m.span(tasks, "yaml-single-statement {% if object[''<yaml_field>''] %}"),
    m.span(tasks, "yaml-double-statement {% if object[\\\"<yaml_field>\\\"] %}"),
    m.span(tasks, "🛰 \\U0001F6F0 yaml-unicode {{ object[\\\"<\\u0079aml_field>\\\"] }}"),
    m.span(tasks, "yaml-plain {{ object.<yaml_field> }}"),
    m.span(tasks, "🛰 yaml-literal {{ object['<yaml_field>'] }}"),
    m.span(tasks, "yaml-folded {{ object[\"<yaml_field>\"] }}"),
    m.span(yaml_template, "🛰 yaml-template {{ object['<yaml_field>'] }}"),
};
const yaml_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 yaml-single {{ object[''<yaml_field>''] }}"),
    m.span(tasks, "when: 'object[''<yaml_field>''] == ''single-active'''"),
    m.span(tasks, "🛰 yaml-double {{ object[\\\"<yaml_field>\\\"] }}"),
    m.span(tasks, "when: \"object[\\\"<yaml_field>\\\"] == \\\"double-active\\\"\""),
    m.span(tasks, "yaml-single-statement {% if object[''<yaml_field>''] %}"),
    m.span(tasks, "yaml-double-statement {% if object[\\\"<yaml_field>\\\"] %}"),
    m.span(tasks, "🛰 \\U0001F6F0 yaml-unicode {{ object[\\\"<\\u0079aml_field>\\\"] }}"),
    m.span(tasks, "yaml-plain {{ object.<yaml_field> }}"),
    m.span(tasks, "🛰 yaml-literal {{ object['<yaml_field>'] }}"),
    m.span(tasks, "yaml-folded {{ object[\"<yaml_field>\"] }}"),
    m.span(yaml_template, "🛰 yaml-template {{ object['<yaml_field>'] }}"),
    m.span(defaults, "  <yaml_field>: quoted-value"),
};
const yaml_origins: []const m.Anchor = &.{
    m.cursor(tasks, "🛰 yaml-single {{ object[''<yaml_field>''] }}"),
    m.cursor(tasks, "when: 'object[''<yaml_field>''] == ''single-active'''"),
    m.cursor(tasks, "🛰 yaml-double {{ object[\\\"<yaml_field>\\\"] }}"),
    m.cursor(tasks, "when: \"object[\\\"<yaml_field>\\\"] == \\\"double-active\\\"\""),
    m.cursor(tasks, "yaml-single-statement {% if object[''<yaml_field>''] %}"),
    m.cursor(tasks, "yaml-double-statement {% if object[\\\"<yaml_field>\\\"] %}"),
    m.cursor(tasks, "🛰 \\U0001F6F0 yaml-unicode {{ object[\\\"<\\u0079aml_field>\\\"] }}"),
    m.cursor(tasks, "yaml-plain {{ object.<yaml_field> }}"),
    m.cursor(tasks, "🛰 yaml-literal {{ object['<yaml_field>'] }}"),
    m.cursor(tasks, "yaml-folded {{ object[\"<yaml_field>\"] }}"),
    m.cursor(yaml_template, "🛰 yaml-template {{ object['<yaml_field>'] }}"),
    m.cursor(defaults, "  <yaml_field>: quoted-value"),
};

test "stdio YAML scalar quoting preserves the complete field group and original UTF-16 spans" {
    try checkGroup(yaml_origins, yaml_reads, yaml_with_definitions);
}

test "stdio quoted YAML fields have exact definition implementation and hover spans" {
    try checkNavigation(yaml_origins, &.{m.span(defaults, "  <yaml_field>: quoted-value")}, &.{ "**Variable field** `yaml_field`", "quoted-value" }, &.{ "**Variable**", "root-quoted-value" });
}

const yaml_root_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 yaml-dynamic-single {{ object[<yaml_field>] }}"),
    m.span(tasks, "🛰 yaml-dynamic-double {{ object[<yaml_field>] }}"),
    m.span(tasks, "yaml-root-escape {{ <\\u0079aml_field> }}"),
    m.span(tasks, "when: \"object[<yaml_field>] == \\\"dynamic-active\\\"\""),
};
const yaml_roots_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 yaml-dynamic-single {{ object[<yaml_field>] }}"),
    m.span(tasks, "🛰 yaml-dynamic-double {{ object[<yaml_field>] }}"),
    m.span(tasks, "yaml-root-escape {{ <\\u0079aml_field> }}"),
    m.span(tasks, "when: \"object[<yaml_field>] == \\\"dynamic-active\\\"\""),
    m.span(defaults, "\n<yaml_field>: root-quoted-value"),
};
const yaml_root_origins: []const m.Anchor = &.{
    m.cursor(tasks, "🛰 yaml-dynamic-single {{ object[<yaml_field>] }}"),
    m.cursor(tasks, "🛰 yaml-dynamic-double {{ object[<yaml_field>] }}"),
    m.cursor(tasks, "yaml-root-escape {{ <\\u0079aml_field> }}"),
    m.cursor(tasks, "when: \"object[<yaml_field>] == \\\"dynamic-active\\\"\""),
    m.cursor(defaults, "\n<yaml_field>: root-quoted-value"),
};

test "stdio quoted YAML dynamic and escaped roots do not acquire same-named field bindings" {
    try checkGroup(yaml_root_origins, yaml_root_reads, yaml_roots_with_definitions);
    try checkNavigation(yaml_root_origins, &.{m.span(defaults, "\n<yaml_field>: root-quoted-value")}, &.{ "**Variable** `yaml_field`", "root-quoted-value" }, &.{ "**Variable field**", "\nquoted-value" });
    // Two YAML backslashes become one Jinja backslash; the Jinja key escape
    // remains a raw name, NOT an alias of the ordinary yaml_field group.
    try checkGroup(&.{
        m.cursor(tasks, "yaml-jinja-escape {{ object['<\\\\u0079aml_field>'] }}"),
    }, &.{
        m.span(tasks, "yaml-jinja-escape {{ object['<\\\\u0079aml_field>'] }}"),
    }, &.{
        m.span(tasks, "yaml-jinja-escape {{ object['<\\\\u0079aml_field>'] }}"),
    });
}

const filter_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "plain-filter {{ record.<filter_field> |"),
    m.span(tasks, "plain-test {{ record.<filter_field> is"),
    m.span(tasks, "qualified-filter {{ record.<filter_field> |"),
    m.span(tasks, "qualified-test {{ record.<filter_field> is"),
    m.span(tasks, "apply(other.<filter_field>)"),
    m.span(tasks, "check(other['<filter_field>'])"),
};
const filter_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "plain-filter {{ record.<filter_field> |"),
    m.span(tasks, "plain-test {{ record.<filter_field> is"),
    m.span(tasks, "qualified-filter {{ record.<filter_field> |"),
    m.span(tasks, "qualified-test {{ record.<filter_field> is"),
    m.span(tasks, "apply(other.<filter_field>)"),
    m.span(tasks, "check(other['<filter_field>'])"),
    m.span(defaults, "  <filter_field>: value"),
};

test "stdio filter and test names are not field reads, including dotted qualified names" {
    try checkGroup(&.{
        m.cursor(tasks, "plain-filter {{ record.<filter_field> |"),
        m.cursor(tasks, "plain-test {{ record.<filter_field> is"),
        m.cursor(tasks, "qualified-filter {{ record.<filter_field> |"),
        m.cursor(tasks, "qualified-test {{ record.<filter_field> is"),
        m.cursor(tasks, "apply(other.<filter_field>)"),
        m.cursor(tasks, "check(other['<filter_field>'])"),
        m.cursor(defaults, "  <filter_field>: value"),
    }, filter_reads, filter_with_definitions);
    try checkGroup(&.{
        m.cursor(tasks, "plain-filter {{ record.filter_field | <filter_field> }}"),
        m.cursor(tasks, "plain-test {{ record.filter_field is <filter_field> }}"),
        m.cursor(tasks, "| <acme>.tools.filter_field"),
        m.cursor(tasks, "| acme.<tools>.filter_field"),
        m.cursor(tasks, "| acme.tools.<filter_field>"),
        m.cursor(tasks, "is not <acme>.tools.filter_field"),
        m.cursor(tasks, "is not acme.<tools>.filter_field"),
        m.cursor(tasks, "is not acme.tools.<filter_field>"),
        m.cursor(tasks, "| acme.<filter_field>.apply"),
        m.cursor(tasks, "| acme.filter_field.<apply>"),
        m.cursor(tasks, "is acme.<filter_field>.check"),
        m.cursor(tasks, "is acme.filter_field.<check>"),
        m.cursor(tasks, "| acme.tools.<apply>(other"),
        m.cursor(tasks, "is acme.tools.<check>(other"),
    }, &.{}, &.{});
}

const method_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "stored {{ item.<method_field> }}"),
    m.span(tasks, "spaced-call {{ item.method_field (other.<method_field>) }}"),
    m.span(tasks, "returned-field {{ item.invoke().<method_field> }}"),
    m.span(tasks, "method-argument {{ item.invoke(other['<method_field>']) }}"),
};
const method_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "stored {{ item.<method_field> }}"),
    m.span(tasks, "spaced-call {{ item.method_field (other.<method_field>) }}"),
    m.span(tasks, "returned-field {{ item.invoke().<method_field> }}"),
    m.span(tasks, "method-argument {{ item.invoke(other['<method_field>']) }}"),
    m.span(defaults, "  <method_field>: stored-value"),
};

test "stdio called methods are not field reads but their arguments and return-value fields are" {
    try checkGroup(&.{
        m.cursor(tasks, "dot-call {{ item.<method_field>() }}"),
        m.cursor(tasks, "spaced-call {{ item.<method_field> ("),
        m.cursor(tasks, "bracket-call {{ item['<method_field>']() }}"),
        m.cursor(tasks, "double-call {{ item[ \"<method_field>\" ] () }}"),
        m.cursor(tasks, "returned-field {{ item.<invoke>()."),
        m.cursor(tasks, "method-argument {{ item.<invoke>(other"),
    }, &.{}, &.{});
    try checkGroup(&.{
        m.cursor(tasks, "stored {{ item.<method_field> }}"),
        m.cursor(tasks, "spaced-call {{ item.method_field (other.<method_field>) }}"),
        m.cursor(tasks, "returned-field {{ item.invoke().<method_field> }}"),
        m.cursor(tasks, "method-argument {{ item.invoke(other['<method_field>']) }}"),
        m.cursor(defaults, "  <method_field>: stored-value"),
    }, method_reads, method_with_definitions);
}

const literal_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "genuine {{ record.<literal_field> }}"),
};
const literal_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "genuine {{ record.<literal_field> }}"),
    m.span(defaults, "  <literal_field>: stored-literal"),
};

test "stdio quoted strings and comments are not field reads" {
    try checkGroup(&.{
        m.cursor(tasks, "single-string {{ 'record.<literal_field>' }}"),
        m.cursor(tasks, "double-string {{ \"record.<literal_field>\" }}"),
        m.cursor(tasks, "escaped-single {{ 'it\\'s record.<literal_field>' }}"),
        m.cursor(tasks, "escaped-double {{ \"say \\\"record.<literal_field>\\\"\" }}"),
        m.cursor(tasks, "literal-list {{ ['<literal_field>',"),
        m.cursor(tasks, "literal-list {{ ['literal_field', \"<literal_field>\"]"),
        m.cursor(tasks, "literal-map {{ {'<literal_field>':"),
        m.cursor(tasks, "literal-map {{ {'literal_field': \"<literal_field>\"}"),
        m.cursor(tasks, "{# comment {{ record.<literal_field> }} #}"),
        m.cursor(tasks, "outside record.<literal_field>"),
        m.cursor(tasks, "# YAML comment {{ record.<literal_field> }}"),
    }, &.{}, &.{});
    try checkGroup(&.{
        m.cursor(tasks, "genuine {{ record.<literal_field> }}"),
        m.cursor(defaults, "  <literal_field>: stored-literal"),
    }, literal_reads, literal_with_definitions);
}

const unrelated_tasks = "roles/unrelated/tasks/main.yml";
const context_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "interpolation {{ receiver.<context_field> }}"),
    m.span(tasks, "🛰 {% if receiver['<context_field>'] %}"),
    m.span(tasks, "{% set selected = receiver [ \"<context_field>\" ] %}"),
    m.span(tasks, "- receiver['<context_field>'] == 'active'"),
    m.span(tasks, "- receiver.<context_field> is defined"),
    m.span(unrelated_tasks, "{{ unrelated['<context_field>'] }}"),
};
const context_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "interpolation {{ receiver.<context_field> }}"),
    m.span(tasks, "🛰 {% if receiver['<context_field>'] %}"),
    m.span(tasks, "{% set selected = receiver [ \"<context_field>\" ] %}"),
    m.span(tasks, "- receiver['<context_field>'] == 'active'"),
    m.span(tasks, "- receiver.<context_field> is defined"),
    m.span(unrelated_tasks, "{{ unrelated['<context_field>'] }}"),
    m.span(defaults, "  <context_field>: active"),
};

test "stdio bare expressions and template statements share the Workspace field group" {
    try checkGroup(&.{
        m.cursor(tasks, "interpolation {{ receiver.<context_field> }}"),
        m.cursor(tasks, "🛰 {% if receiver['<context_field>'] %}"),
        m.cursor(tasks, "{% set selected = receiver [ \"<context_field>\" ] %}"),
        m.cursor(tasks, "- receiver['<context_field>'] == 'active'"),
        m.cursor(tasks, "- receiver.<context_field> is defined"),
        m.cursor(unrelated_tasks, "{{ unrelated['<context_field>'] }}"),
        m.cursor(defaults, "  <context_field>: active"),
    }, context_reads, context_with_definitions);
}

const root_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "root-read {{ <field_name> }}"),
    m.span(tasks, "dynamic-subscript {{ record[<field_name>] }}"),
    m.span(tasks, "when: record[<field_name>] is defined"),
};
const roots_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "root-read {{ <field_name> }}"),
    m.span(tasks, "dynamic-subscript {{ record[<field_name>] }}"),
    m.span(tasks, "when: record[<field_name>] is defined"),
    m.span(defaults, "\n<field_name>: root-only"),
};

test "stdio dynamic subscripts read root Variables, separately from same-named fields" {
    try checkGroup(&.{
        m.cursor(tasks, "root-read {{ <field_name> }}"),
        m.cursor(tasks, "dynamic-subscript {{ record[<field_name>] }}"),
        m.cursor(tasks, "when: record[<field_name>] is defined"),
        m.cursor(defaults, "\n<field_name>: root-only"),
    }, root_reads, roots_with_definitions);
}

test "stdio numeric and computed-string subscripts are not named field reads" {
    try checkGroup(&.{
        m.cursor(tasks, "numeric {{ record[<0>] }}"),
        m.cursor(tasks, "{{ record[<42>] }}"),
        m.cursor(tasks, "{{ record[<-1>] }}"),
        m.cursor(tasks, "{{ record[<1.0>] }}"),
        m.cursor(tasks, "computed-single {{ record['<field_name>' ~ suffix] }}"),
        m.cursor(tasks, "computed-double {{ record[\"<field_name>\" + suffix] }}"),
    }, &.{}, &.{});
}

const block_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "genuine-block {{ receiver.<block_field> }}"),
    m.span(tasks, "argument-block {% filter acme.tools.apply(other['<block_field>'])"),
};
const blocks_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "genuine-block {{ receiver.<block_field> }}"),
    m.span(tasks, "argument-block {% filter acme.tools.apply(other['<block_field>'])"),
    m.span(defaults, "  <block_field>: stored-block"),
};

test "stdio template filter-block names are not root or field reads" {
    try checkGroup(&.{
        m.cursor(tasks, "plain-block {% filter <block_field> %}"),
        m.cursor(tasks, "qualified-block {% filter <acme>.tools.block_field"),
        m.cursor(tasks, "qualified-block {% filter acme.<tools>.block_field"),
        m.cursor(tasks, "qualified-block {% filter acme.tools.<block_field>"),
        m.cursor(tasks, "argument-block {% filter acme.tools.<apply>(other"),
    }, &.{}, &.{});
    try checkGroup(&.{
        m.cursor(tasks, "genuine-block {{ receiver.<block_field> }}"),
        m.cursor(tasks, "argument-block {% filter acme.tools.apply(other['<block_field>'])"),
        m.cursor(defaults, "  <block_field>: stored-block"),
    }, block_reads, blocks_with_definitions);
}

const keyword_filter_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "filter-member {{ data.<filter> }}"),
    m.span(tasks, "filter-member {{ data.filter }} / {{ data['<filter>'] }}"),
    m.span(tasks, "filter-member {{ data.filter }} / {{ data['filter'] }} / {{ data[\"<filter>\"] }}"),
    m.span(tasks, "filter-condition {% if data.<filter> %}"),
    m.span(tasks, "conditional-member {{ data | lower if enabled else other.<filter> }}"),
};
const keyword_filter_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "filter-member {{ data.<filter> }}"),
    m.span(tasks, "filter-member {{ data.filter }} / {{ data['<filter>'] }}"),
    m.span(tasks, "filter-member {{ data.filter }} / {{ data['filter'] }} / {{ data[\"<filter>\"] }}"),
    m.span(tasks, "filter-condition {% if data.<filter> %}"),
    m.span(tasks, "conditional-member {{ data | lower if enabled else other.<filter> }}"),
    m.span(defaults, "  <filter>: filter-value"),
};
const keyword_is_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "is-member {{ data.<is> }}"),
    m.span(tasks, "is-member {{ data.is }} / {{ data['<is>'] }}"),
    m.span(tasks, "is-member {{ data.is }} / {{ data['is'] }} / {{ data[\"<is>\"] }}"),
    m.span(tasks, "is-statement {% set saved = data.<is> %}"),
};
const keyword_is_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "is-member {{ data.<is> }}"),
    m.span(tasks, "is-member {{ data.is }} / {{ data['<is>'] }}"),
    m.span(tasks, "is-member {{ data.is }} / {{ data['is'] }} / {{ data[\"<is>\"] }}"),
    m.span(tasks, "is-statement {% set saved = data.<is> %}"),
    m.span(defaults, "  <is>: is-value"),
};
const keyword_true_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "true-member {{ data.<true> }}"),
    m.span(tasks, "true-member {{ data.true }} / {{ data['<true>'] }}"),
    m.span(tasks, "true-member {{ data.true }} / {{ data['true'] }} / {{ data[\"<true>\"] }}"),
    m.span(tasks, "when: data.<true>"),
};
const keyword_true_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "true-member {{ data.<true> }}"),
    m.span(tasks, "true-member {{ data.true }} / {{ data['<true>'] }}"),
    m.span(tasks, "true-member {{ data.true }} / {{ data['true'] }} / {{ data[\"<true>\"] }}"),
    m.span(tasks, "when: data.<true>"),
    m.span(defaults, "  \"<true>\": true-value"),
};

test "stdio keyword-like data members share their dot, subscript, and binding-key groups" {
    // These are independently written groups, not a spelling-substitution oracle.
    const groups = [_]struct {
        origins: []const m.Anchor,
        reads: []const m.ExpectedLocation,
        with_definitions: []const m.ExpectedLocation,
    }{
        .{ .origins = &.{
            m.cursor(tasks, "filter-member {{ data.<filter> }}"),
            m.cursor(tasks, "filter-member {{ data.filter }} / {{ data['<filter>'] }}"),
            m.cursor(tasks, "filter-member {{ data.filter }} / {{ data['filter'] }} / {{ data[\"<filter>\"] }}"),
            m.cursor(tasks, "filter-condition {% if data.<filter> %}"),
            m.cursor(tasks, "conditional-member {{ data | lower if enabled else other.<filter> }}"),
            m.cursor(defaults, "  <filter>: filter-value"),
        }, .reads = keyword_filter_reads, .with_definitions = keyword_filter_with_definitions },
        .{ .origins = &.{
            m.cursor(tasks, "is-member {{ data.<is> }}"),
            m.cursor(tasks, "is-member {{ data.is }} / {{ data['<is>'] }}"),
            m.cursor(tasks, "is-member {{ data.is }} / {{ data['is'] }} / {{ data[\"<is>\"] }}"),
            m.cursor(tasks, "is-statement {% set saved = data.<is> %}"),
            m.cursor(defaults, "  <is>: is-value"),
        }, .reads = keyword_is_reads, .with_definitions = keyword_is_with_definitions },
        .{ .origins = &.{
            m.cursor(tasks, "true-member {{ data.<true> }}"),
            m.cursor(tasks, "true-member {{ data.true }} / {{ data['<true>'] }}"),
            m.cursor(tasks, "true-member {{ data.true }} / {{ data['true'] }} / {{ data[\"<true>\"] }}"),
            m.cursor(tasks, "when: data.<true>"),
            m.cursor(defaults, "  \"<true>\": true-value"),
        }, .reads = keyword_true_reads, .with_definitions = keyword_true_with_definitions },
    };
    var failures: usize = 0;
    for (groups) |group| {
        checkGroup(group.origins, group.reads, group.with_definitions) catch {
            failures += 1;
        };
    }
    checkGroup(&.{
        m.cursor(tasks, "filter-operator {{ data | <filter> }}"),
        m.cursor(tasks, "qualified-filter-operator {{ data | <acme>.is.filter"),
        m.cursor(tasks, "qualified-filter-operator {{ data | acme.<is>.filter"),
        m.cursor(tasks, "qualified-filter-operator {{ data | acme.is.<filter>"),
        m.cursor(tasks, "test-operator {{ data is <true> }}"),
        m.cursor(tasks, "qualified-test-operator {{ data is not <acme>.filter.true"),
        m.cursor(tasks, "qualified-test-operator {{ data is not acme.<filter>.true"),
        m.cursor(tasks, "qualified-test-operator {{ data is not acme.filter.<true>"),
        m.cursor(tasks, "keyword-filter-block {% filter <filter> %}"),
        m.cursor(tasks, "trimmed-filter-block {%- filter <acme>.is.filter"),
        m.cursor(tasks, "trimmed-filter-block {%- filter acme.<is>.filter"),
        m.cursor(tasks, "trimmed-filter-block {%- filter acme.is.<filter>"),
        m.cursor(tasks, "keyword-method {{ data.<filter>() }}"),
        m.cursor(tasks, "conditional-member {{ data | <lower> if enabled"),
    }, &.{}, &.{}) catch {
        failures += 1;
    };
    checkGroup(&.{
        m.cursor(tasks, "conditional-member {{ data | lower if <enabled> else"),
    }, &.{
        m.span(tasks, "conditional-member {{ data | lower if <enabled> else"),
    }, &.{
        m.span(tasks, "conditional-member {{ data | lower if <enabled> else"),
    }) catch {
        failures += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), failures);
}

const delimiter_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 quoted-interpolation {{ '}} {{ phantom.delimiter_field }} {{ ghost_root }}' ~ actual.<delimiter_field> }}"),
    m.span(tasks, "quoted-statement {% set saved_value = \"say \\\"%}\\\" {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ actual.<delimiter_field> %}"),
    m.span(tasks, "quoted-yaml {{ \"}} {{ phantom.delimiter_field }} {{ ghost_root }}\" ~ actual.<delimiter_field> }}"),
    m.span(tasks, "statement-yaml {% set saved_value = \"%} {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ actual.<delimiter_field> %}"),
};
const delimiters_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 quoted-interpolation {{ '}} {{ phantom.delimiter_field }} {{ ghost_root }}' ~ actual.<delimiter_field> }}"),
    m.span(tasks, "quoted-statement {% set saved_value = \"say \\\"%}\\\" {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ actual.<delimiter_field> %}"),
    m.span(tasks, "quoted-yaml {{ \"}} {{ phantom.delimiter_field }} {{ ghost_root }}\" ~ actual.<delimiter_field> }}"),
    m.span(tasks, "statement-yaml {% set saved_value = \"%} {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ actual.<delimiter_field> %}"),
    m.span(defaults, "  <delimiter_field>: present"),
};
const fallback_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "unterminated-interpolation {{ actual.<fallback_field>"),
    m.span(tasks, "unterminated-statement {% if actual.<fallback_field>"),
};
const fallback_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "unterminated-interpolation {{ actual.<fallback_field>"),
    m.span(tasks, "unterminated-statement {% if actual.<fallback_field>"),
    m.span(defaults, "  <fallback_field>: still-scanned"),
};
const delimiter_root_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 quoted-interpolation {{ '}} {{ phantom.delimiter_field }} {{ ghost_root }}' ~ <actual>.delimiter_field }}"),
    m.span(tasks, "quoted-statement {% set saved_value = \"say \\\"%}\\\" {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ <actual>.delimiter_field %}"),
    m.span(tasks, "quoted-yaml {{ \"}} {{ phantom.delimiter_field }} {{ ghost_root }}\" ~ <actual>.delimiter_field }}"),
    m.span(tasks, "statement-yaml {% set saved_value = \"%} {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ <actual>.delimiter_field %}"),
    m.span(tasks, "unterminated-interpolation {{ <actual>.fallback_field"),
    m.span(tasks, "unterminated-statement {% if <actual>.fallback_field"),
};
const delimiter_roots_with_definitions: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 quoted-interpolation {{ '}} {{ phantom.delimiter_field }} {{ ghost_root }}' ~ <actual>.delimiter_field }}"),
    m.span(tasks, "quoted-statement {% set saved_value = \"say \\\"%}\\\" {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ <actual>.delimiter_field %}"),
    m.span(tasks, "quoted-yaml {{ \"}} {{ phantom.delimiter_field }} {{ ghost_root }}\" ~ <actual>.delimiter_field }}"),
    m.span(tasks, "statement-yaml {% set saved_value = \"%} {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ <actual>.delimiter_field %}"),
    m.span(tasks, "unterminated-interpolation {{ <actual>.fallback_field"),
    m.span(tasks, "unterminated-statement {% if <actual>.fallback_field"),
    m.span(defaults, "\n<actual>:"),
};

test "stdio quoted closing delimiters preserve later fields and exclude literal field/root text" {
    var failures: usize = 0;
    checkGroup(&.{
        m.cursor(tasks, "🛰 quoted-interpolation {{ '}} {{ phantom.delimiter_field }} {{ ghost_root }}' ~ actual.<delimiter_field> }}"),
        m.cursor(tasks, "quoted-statement {% set saved_value = \"say \\\"%}\\\" {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ actual.<delimiter_field> %}"),
        m.cursor(tasks, "quoted-yaml {{ \"}} {{ phantom.delimiter_field }} {{ ghost_root }}\" ~ actual.<delimiter_field> }}"),
        m.cursor(tasks, "statement-yaml {% set saved_value = \"%} {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ actual.<delimiter_field> %}"),
        m.cursor(defaults, "  <delimiter_field>: present"),
    }, delimiter_reads, delimiters_with_definitions) catch {
        failures += 1;
    };
    checkGroup(&.{
        m.cursor(tasks, "unterminated-interpolation {{ actual.<fallback_field>"),
        m.cursor(tasks, "unterminated-statement {% if actual.<fallback_field>"),
        m.cursor(defaults, "  <fallback_field>: still-scanned"),
    }, fallback_reads, fallback_with_definitions) catch {
        failures += 1;
    };
    checkGroup(&.{
        m.cursor(tasks, "🛰 quoted-interpolation {{ '}} {{ phantom.delimiter_field }} {{ ghost_root }}' ~ <actual>.delimiter_field }}"),
        m.cursor(tasks, "quoted-statement {% set saved_value = \"say \\\"%}\\\" {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ <actual>.delimiter_field %}"),
        m.cursor(tasks, "quoted-yaml {{ \"}} {{ phantom.delimiter_field }} {{ ghost_root }}\" ~ <actual>.delimiter_field }}"),
        m.cursor(tasks, "statement-yaml {% set saved_value = \"%} {% set bogus = phantom.delimiter_field %} {{ ghost_root }}\" ~ <actual>.delimiter_field %}"),
        m.cursor(tasks, "unterminated-interpolation {{ <actual>.fallback_field"),
        m.cursor(tasks, "unterminated-statement {% if <actual>.fallback_field"),
        m.cursor(defaults, "\n<actual>:"),
    }, delimiter_root_reads, delimiter_roots_with_definitions) catch {
        failures += 1;
    };
    checkGroup(&.{
        m.cursor(tasks, "🛰 quoted-interpolation {{ '}} {{ phantom.<delimiter_field>"),
        m.cursor(tasks, "🛰 quoted-interpolation {{ '}} {{ <phantom>.delimiter_field"),
        m.cursor(tasks, "🛰 quoted-interpolation {{ '}} {{ phantom.delimiter_field }} {{ <ghost_root>"),
        m.cursor(tasks, "quoted-statement {% set saved_value = \"say \\\"%}\\\" {% set bogus = phantom.<delimiter_field>"),
        m.cursor(tasks, "quoted-statement {% set saved_value = \"say \\\"%}\\\" {% set bogus = <phantom>.delimiter_field"),
        m.cursor(tasks, "quoted-statement {% set saved_value = \"say \\\"%}\\\" {% set bogus = phantom.delimiter_field %} {{ <ghost_root>"),
        m.cursor(tasks, "quoted-yaml {{ \"}} {{ phantom.<delimiter_field>"),
        m.cursor(tasks, "quoted-yaml {{ \"}} {{ <phantom>.delimiter_field"),
        m.cursor(tasks, "quoted-yaml {{ \"}} {{ phantom.delimiter_field }} {{ <ghost_root>"),
        m.cursor(tasks, "statement-yaml {% set saved_value = \"%} {% set bogus = phantom.<delimiter_field>"),
        m.cursor(tasks, "statement-yaml {% set saved_value = \"%} {% set bogus = <phantom>.delimiter_field"),
        m.cursor(tasks, "statement-yaml {% set saved_value = \"%} {% set bogus = phantom.delimiter_field %} {{ <ghost_root>"),
        m.cursor(tasks, "{# literal-comment \"{{ phantom.<delimiter_field>"),
        m.cursor(tasks, "{# literal-comment \"{{ <phantom>.delimiter_field"),
        m.cursor(tasks, "{# literal-comment \"{{ phantom.delimiter_field }} {{ <ghost_root>"),
    }, &.{}, &.{}) catch {
        failures += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), failures);
}

/// Both reference modes have separate, complete written answers. Every origin
/// sees the same Workspace-wide leaf-NAME group, not receiver object identity.
fn checkGroup(origins: []const m.Anchor, reads: []const m.ExpectedLocation, with_definitions: []const m.ExpectedLocation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/field-expressions-workspace");
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
    var temp_home = std.testing.tmpDir(.{});
    defer temp_home.cleanup();
    const home = try temp_home.dir.realpathAlloc(a, ".");
    var client = try initializedClient(a, binary, fixture, home);
    defer client.deinit();

    const resolver: anchor.Resolver = .{ .allocator = a, .fixture = fixture, .deps = fixture };
    var opened = std.StringHashMap(void).init(a);
    var failures: usize = 0;
    for (origins) |origin| {
        const source = try resolver.cursor(origin);
        if (!opened.contains(origin.path)) {
            try client.notify("textDocument/didOpen", .{ .textDocument = .{
                .uri = source.uri,
                .languageId = if (std.mem.endsWith(u8, origin.path, ".j2")) "jinja2" else "yaml",
                .version = @as(u32, 1),
                .text = try resolver.readText(origin.path),
            } });
            try opened.put(origin.path, {});
        }
        // Never derive one oracle by adding/removing declarations from another.
        const modes = [_]struct { include: bool, expected: []const m.ExpectedLocation }{
            .{ .include = false, .expected = reads },
            .{ .include = true, .expected = with_definitions },
        };
        for (modes) |mode| {
            const result = try client.request("textDocument/references", .{
                .textDocument = .{ .uri = source.uri },
                .position = source.position,
                .context = .{ .includeDeclaration = mode.include },
            });
            const actual = try parseLocations(a, result);
            const expected = try a.alloc(anchor.Location, mode.expected.len);
            for (mode.expected, 0..) |location, i| expected[i] = try resolver.location(location);
            std.mem.sort(anchor.Location, actual, {}, locationLessThan);
            std.mem.sort(anchor.Location, expected, {}, locationLessThan);
            expectLocations(expected, actual) catch |err| {
                std.debug.print("FAIL {s}: {s} (includeDeclaration={}): {s}\n", .{
                    origin.path, origin.snippet, mode.include, @errorName(err),
                });
                printLocations("expected", expected);
                printLocations("actual", actual);
                failures += 1;
            };
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

fn initializedClient(a: Allocator, binary: []const u8, fixture: []const u8, home: []const u8) !lsp.Client {
    var client = try lsp.Client.startWithOptions(a, binary, fixture, fixture, home, .{
        .collections_path = fixture,
    });
    errdefer client.deinit();
    const init_result = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = try std.fmt.allocPrint(a, "file://{s}", .{fixture}),
        .capabilities = .{}, // Default UTF-16.
        .initializationOptions = .{ .ansible = .{
            .workspace = .{ .rootMarker = "fixture-workspace-root" },
            .python = .{ .venvPath = "" },
            .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
        } },
    });
    const caps = lsp.field(init_result, "capabilities") orelse return error.MissingCapabilities;
    const references = lsp.field(caps, "referencesProvider") orelse return error.MissingReferencesProvider;
    try std.testing.expect(references == .bool and references.bool);
    if (lsp.field(caps, "positionEncoding")) |encoding| {
        try std.testing.expect(encoding == .string);
        try std.testing.expectEqualStrings("utf-16", encoding.string);
    }
    try client.notify("initialized", .{});
    try client.waitForIndex();
    return client;
}

/// Definitions/implementations are ordered complete answers; hover must select
/// the independently marked original source span, never a decoded-text span.
fn checkNavigation(origins: []const m.Anchor, targets: []const m.ExpectedLocation, contains: []const []const u8, excludes: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/field-expressions-workspace");
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
    var temp_home = std.testing.tmpDir(.{});
    defer temp_home.cleanup();
    const home = try temp_home.dir.realpathAlloc(a, ".");
    var client = try initializedClient(a, binary, fixture, home);
    defer client.deinit();
    const resolver: anchor.Resolver = .{ .allocator = a, .fixture = fixture, .deps = fixture };
    const expected = try a.alloc(anchor.Location, targets.len);
    for (targets, 0..) |target, i| expected[i] = try resolver.location(target);
    var opened = std.StringHashMap(void).init(a);
    for (origins) |origin| {
        const source = try resolver.cursor(origin);
        if (!opened.contains(origin.path)) {
            try client.notify("textDocument/didOpen", .{ .textDocument = .{
                .uri = source.uri,
                .languageId = if (std.mem.endsWith(u8, origin.path, ".j2")) "jinja2" else "yaml",
                .version = @as(u32, 1),
                .text = try resolver.readText(origin.path),
            } });
            try opened.put(origin.path, {});
        }
        const params = .{ .textDocument = .{ .uri = source.uri }, .position = source.position };
        for ([_][]const u8{ "textDocument/definition", "textDocument/implementation" }) |method| {
            const result = try client.request(method, params);
            const actual = if (result == .object)
                try a.dupe(anchor.Location, &.{try std.json.parseFromValueLeaky(anchor.Location, a, result, .{})})
            else
                try parseLocations(a, result);
            expectLocations(expected, actual) catch |err| {
                std.debug.print("FAIL {s}: {s} ({s})\n", .{ origin.path, origin.snippet, method });
                printLocations("expected", expected);
                printLocations("actual", actual);
                return err;
            };
        }
        const hover = try client.request("textDocument/hover", params);
        const range = try std.json.parseFromValueLeaky(anchor.Range, a, lsp.field(hover, "range") orelse return error.MissingHoverRange, .{});
        const marked = try resolver.location(m.span(origin.path, origin.snippet));
        try std.testing.expectEqualDeep(marked.range, range);
        const contents = lsp.field(hover, "contents") orelse return error.MissingHoverContents;
        const value = lsp.field(contents, "value") orelse return error.MissingHoverMarkup;
        try std.testing.expect(value == .string);
        for (contains) |part| try std.testing.expect(std.mem.indexOf(u8, value.string, part) != null);
        for (excludes) |part| try std.testing.expect(std.mem.indexOf(u8, value.string, part) == null);
    }
}

fn parseLocations(a: Allocator, result: Value) ![]anchor.Location {
    return switch (result) {
        .null => &.{},
        .array => |items| blk: {
            const locations = try a.alloc(anchor.Location, items.items.len);
            for (items.items, 0..) |item, i| {
                locations[i] = try std.json.parseFromValueLeaky(anchor.Location, a, item, .{});
            }
            break :blk locations;
        },
        else => error.InvalidReferenceResult,
    };
}

fn expectLocations(expected: []const anchor.Location, actual: []const anchor.Location) !void {
    // Compare complete lists, preserving duplicates, not set membership/counts.
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| {
        try std.testing.expectEqualStrings(left.uri, right.uri);
        try std.testing.expectEqualDeep(left.range, right.range);
    }
}

fn printLocations(label: []const u8, locations: []const anchor.Location) void {
    std.debug.print("  {s} ({d}):\n", .{ label, locations.len });
    for (locations) |location| std.debug.print("    {s} {d}:{d}-{d}:{d}\n", .{
        location.uri,            location.range.start.line,    location.range.start.character,
        location.range.end.line, location.range.end.character,
    });
}

fn locationLessThan(_: void, left: anchor.Location, right: anchor.Location) bool {
    const uri_order = std.mem.order(u8, left.uri, right.uri);
    if (uri_order != .eq) return uri_order == .lt;
    if (left.range.start.line != right.range.start.line) return left.range.start.line < right.range.start.line;
    if (left.range.start.character != right.range.start.character) return left.range.start.character < right.range.start.character;
    if (left.range.end.line != right.range.end.line) return left.range.end.line < right.range.end.line;
    return left.range.end.character < right.range.end.character;
}

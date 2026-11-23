//! Server settings, using upstream's `ansible.*` names and defaults.
//!
//! Strings live in an arena that is reset on every update, so callers must not
//! hold pointers across an update.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const cel_rules = @import("../cel/root.zig");

pub const Settings = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,

    ansible_path: []const u8 = "ansible",
    use_fqcn: bool = true,
    provide_redirect_modules: bool = true,
    provide_module_option_aliases: bool = true,
    validation_enabled: bool = true,
    schema_enabled: bool = true,
    lint_enabled: bool = false,
    lint_path: []const u8 = "ansible-lint",
    lint_arguments: []const u8 = "",
    auto_fix_on_save: bool = false,
    cel_enabled: bool = true,
    cel_global_rule_files: []const []const u8 = &.{},
    cel_workspace_rule_files: []const []const u8 = &.{},
    cel_allow_workspace_rules: bool = false,
    cel_disabled_rules: []const []const u8 = &.{},
    cel_severity_overrides: []const cel_rules.registry.SeverityOverride = &.{},
    cel_rule_options: []const cel_rules.registry.RuleOptionOverride = &.{},
    python_interpreter_path: []const u8 = "",
    python_activation_script: []const u8 = "",
    /// `ansible.python.venvPath`. The one virtual environment whose
    /// collections are searched, relative to the Workspace root. Default
    /// `.venv`.
    venv_path: []const u8 = ".venv",
    /// `ansible.workspace.missingGitWarning`. One session warning when an
    /// opened folder has no Workspace.
    missing_git_warning: bool = true,
    /// `ansible.workspace.rootMarker`. File or directory name that marks a
    /// Workspace. Default `.git`. A blank value or a path falls back to `.git`.
    root_marker: []const u8 = ".git",

    pub fn init(allocator: Allocator) Settings {
        return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Settings) void {
        self.arena.deinit();
    }

    /// Re-read settings from a `didChangeConfiguration` params object. Missing
    /// fields fall back to defaults.
    pub fn update(self: *Settings, params: Value) !void {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();

        const root = json_util.field(params, "settings") orelse params;
        const ansible = json_util.field(root, "ansible") orelse root;

        const core = json_util.field(ansible, "ansible");
        const completion = json_util.field(ansible, "completion");
        const validation = json_util.field(ansible, "validation");
        const lint = if (validation) |v| json_util.field(v, "lint") else null;
        const schema_cfg = if (validation) |v| json_util.field(v, "schema") else null;
        const cel_cfg = if (validation) |v| json_util.field(v, "cel") else null;
        const python = json_util.field(ansible, "python");
        const workspace = json_util.field(ansible, "workspace");

        self.ansible_path = try dupeOpt(a, if (core) |c| json_util.string(c, "path") else null, "ansible");
        self.use_fqcn = optBool(core, "useFullyQualifiedCollectionNames", true);
        self.provide_redirect_modules = optBool(completion, "provideRedirectModules", true);
        self.provide_module_option_aliases = optBool(completion, "provideModuleOptionAliases", true);
        self.validation_enabled = optBool(validation, "enabled", true);
        self.schema_enabled = optBool(schema_cfg, "enabled", true);
        self.lint_enabled = optBool(lint, "enabled", false);
        self.lint_path = try dupeOpt(a, if (lint) |l| json_util.string(l, "path") else null, "ansible-lint");
        self.lint_arguments = try dupeOpt(a, if (lint) |l| json_util.string(l, "arguments") else null, "");
        self.auto_fix_on_save = optBool(lint, "autoFixOnSave", false);
        self.cel_enabled = optBool(cel_cfg, "enabled", true);
        self.cel_global_rule_files = try dupeStringArray(a, cel_cfg, "globalRuleFiles");
        self.cel_workspace_rule_files = try dupeStringArray(a, cel_cfg, "workspaceRuleFiles");
        self.cel_allow_workspace_rules = optBool(cel_cfg, "allowWorkspaceRules", false);
        try self.parseCelRuleOverrides(a, cel_cfg);
        self.python_interpreter_path = try dupeOpt(a, if (python) |p| json_util.string(p, "interpreterPath") else null, "");
        self.python_activation_script = try dupeOpt(a, if (python) |p| json_util.string(p, "activationScript") else null, "");
        self.venv_path = try dupeOpt(a, if (python) |p| json_util.string(p, "venvPath") else null, ".venv");
        self.missing_git_warning = optBool(workspace, "missingGitWarning", true);
        self.root_marker = try dupeOpt(a, if (workspace) |w| json_util.string(w, "rootMarker") else null, ".git");
    }

    fn parseCelRuleOverrides(self: *Settings, a: Allocator, cel_cfg: ?Value) !void {
        var disabled = std.ArrayList([]const u8).empty;
        var severities = std.ArrayList(cel_rules.registry.SeverityOverride).empty;
        var options = std.ArrayList(cel_rules.registry.RuleOptionOverride).empty;

        if (cel_cfg) |cfg| {
            if (json_util.array(cfg, "disabledRules")) |arr| {
                for (arr.items) |it| {
                    if (it == .string) try disabled.append(a, try a.dupe(u8, it.string));
                }
            }
            if (json_util.field(cfg, "rules")) |rules_val| {
                if (rules_val == .object) {
                    var it = rules_val.object.iterator();
                    while (it.next()) |entry| {
                        const rule_id = try a.dupe(u8, entry.key_ptr.*);
                        const val = entry.value_ptr.*;
                        if (val == .bool) {
                            if (!val.bool) try disabled.append(a, rule_id);
                            continue;
                        }
                        if (val != .object) continue;
                        if (json_util.boolean(val, "enabled")) |en| {
                            if (!en) try disabled.append(a, rule_id);
                        }
                        if (json_util.string(val, "severity")) |sev_str| {
                            if (cel_rules.Severity.parse(sev_str)) |sev| {
                                try severities.append(a, .{ .rule_id = rule_id, .severity = sev });
                            }
                        }
                        if (json_util.field(val, "options")) |opts_val| {
                            if (opts_val == .object) {
                                var opt_entries = std.ArrayList(cel_rules.registry.RuleOptionEntry).empty;
                                var oit = opts_val.object.iterator();
                                while (oit.next()) |oe| {
                                    const k = try a.dupe(u8, oe.key_ptr.*);
                                    switch (oe.value_ptr.*) {
                                        .bool => |bv| try opt_entries.append(a, .{ .key = k, .value = .{ .bool_v = bv } }),
                                        .integer => |iv| try opt_entries.append(a, .{ .key = k, .value = .{ .int_v = iv } }),
                                        .string => |sv| try opt_entries.append(a, .{ .key = k, .value = .{ .string_v = try a.dupe(u8, sv) } }),
                                        .array => |av| {
                                            var sl = std.ArrayList([]const u8).empty;
                                            for (av.items) |elem| {
                                                if (elem == .string) try sl.append(a, try a.dupe(u8, elem.string));
                                            }
                                            try opt_entries.append(a, .{ .key = k, .value = .{ .string_list_v = try sl.toOwnedSlice(a) } });
                                        },
                                        else => {},
                                    }
                                }
                                if (opt_entries.items.len > 0) {
                                    try options.append(a, .{
                                        .rule_id = rule_id,
                                        .entries = try opt_entries.toOwnedSlice(a),
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }
        self.cel_disabled_rules = try disabled.toOwnedSlice(a);
        self.cel_severity_overrides = try severities.toOwnedSlice(a);
        self.cel_rule_options = try options.toOwnedSlice(a);
    }
};

fn dupeStringArray(a: Allocator, v: ?Value, key: []const u8) ![]const []const u8 {
    const x = v orelse return &.{};
    const arr = json_util.array(x, key) orelse return &.{};
    var out = std.ArrayList([]const u8).empty;
    for (arr.items) |it| {
        if (it == .string) try out.append(a, try a.dupe(u8, it.string));
    }
    return out.toOwnedSlice(a);
}

fn optBool(v: ?Value, key: []const u8, default: bool) bool {
    const x = v orelse return default;
    return json_util.boolean(x, key) orelse default;
}

fn dupeOpt(a: Allocator, value: ?[]const u8, default: []const u8) ![]const u8 {
    return a.dupe(u8, value orelse default);
}

const testing = std.testing;

test "missing git warning defaults on and can be disabled" {
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();
    try testing.expect(settings.missing_git_warning);

    const parsed = try std.json.parseFromSlice(
        Value,
        testing.allocator,
        \\{"ansible":{"workspace":{"missingGitWarning":false}}}
    ,
        .{},
    );
    defer parsed.deinit();
    try settings.update(parsed.value);
    try testing.expect(!settings.missing_git_warning);
    try testing.expectEqualStrings(".git", settings.root_marker);

    const marker = try std.json.parseFromSlice(
        Value,
        testing.allocator,
        \\{"ansible":{"workspace":{"rootMarker":"ansible.cfg"}}}
    ,
        .{},
    );
    defer marker.deinit();
    try settings.update(marker.value);
    try testing.expectEqualStrings("ansible.cfg", settings.root_marker);
    try testing.expect(settings.missing_git_warning);
}

test "venv path defaults to .venv and can be changed" {
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();
    try testing.expectEqualStrings(".venv", settings.venv_path);

    const parsed = try std.json.parseFromSlice(
        Value,
        testing.allocator,
        \\{"ansible":{"python":{"venvPath":".venv-ansible-2.16"}}}
    ,
        .{},
    );
    defer parsed.deinit();
    try settings.update(parsed.value);
    try testing.expectEqualStrings(".venv-ansible-2.16", settings.venv_path);
}

test "validation defaults enable cel and schema while disabling external lint" {
    var settings = Settings.init(testing.allocator);
    defer settings.deinit();
    try testing.expect(settings.validation_enabled);
    try testing.expect(settings.cel_enabled);
    try testing.expect(settings.schema_enabled);
    try testing.expect(!settings.lint_enabled);
    try testing.expect(!settings.cel_allow_workspace_rules);

    const parsed = try std.json.parseFromSlice(
        Value,
        testing.allocator,
        \\{"ansible":{"validation":{"lint":{"enabled":true},"schema":{"enabled":false},"cel":{"enabled":true,"allowWorkspaceRules":true,"globalRuleFiles":["/etc/zals/r.cel"],"workspaceRuleFiles":["rules/a.cel"],"disabledRules":["only-builtins"],"rules":{"name[play]":{"severity":"error"},"complexity":{"options":{"max_tasks":10}}}}}}}
    ,
        .{},
    );
    defer parsed.deinit();
    try settings.update(parsed.value);
    try testing.expect(settings.lint_enabled);
    try testing.expect(!settings.schema_enabled);
    try testing.expect(settings.cel_enabled);
    try testing.expect(settings.cel_allow_workspace_rules);
    try testing.expectEqual(@as(usize, 1), settings.cel_global_rule_files.len);
    try testing.expectEqual(@as(usize, 1), settings.cel_workspace_rule_files.len);
    try testing.expectEqual(@as(usize, 1), settings.cel_disabled_rules.len);
    try testing.expectEqual(@as(usize, 1), settings.cel_severity_overrides.len);
    try testing.expectEqual(@as(usize, 1), settings.cel_rule_options.len);
}

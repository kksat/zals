//! Server settings, using upstream's `ansible.*` names and defaults.
//!
//! Strings live in an arena that is reset on every update, so callers must not
//! hold pointers across an update.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");

pub const Settings = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,

    ansible_path: []const u8 = "ansible",
    use_fqcn: bool = true,
    provide_redirect_modules: bool = true,
    provide_module_option_aliases: bool = true,
    validation_enabled: bool = true,
    lint_enabled: bool = true,
    lint_path: []const u8 = "ansible-lint",
    lint_arguments: []const u8 = "",
    auto_fix_on_save: bool = false,
    python_interpreter_path: []const u8 = "",
    python_activation_script: []const u8 = "",

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
        const python = json_util.field(ansible, "python");

        self.ansible_path = try dupeOpt(a, if (core) |c| json_util.string(c, "path") else null, "ansible");
        self.use_fqcn = optBool(core, "useFullyQualifiedCollectionNames", true);
        self.provide_redirect_modules = optBool(completion, "provideRedirectModules", true);
        self.provide_module_option_aliases = optBool(completion, "provideModuleOptionAliases", true);
        self.validation_enabled = optBool(validation, "enabled", true);
        self.lint_enabled = optBool(lint, "enabled", true);
        self.lint_path = try dupeOpt(a, if (lint) |l| json_util.string(l, "path") else null, "ansible-lint");
        self.lint_arguments = try dupeOpt(a, if (lint) |l| json_util.string(l, "arguments") else null, "");
        self.auto_fix_on_save = optBool(lint, "autoFixOnSave", false);
        self.python_interpreter_path = try dupeOpt(a, if (python) |p| json_util.string(p, "interpreterPath") else null, "");
        self.python_activation_script = try dupeOpt(a, if (python) |p| json_util.string(p, "activationScript") else null, "");
    }
};

fn optBool(v: ?Value, key: []const u8, default: bool) bool {
    const x = v orelse return default;
    return json_util.boolean(x, key) orelse default;
}

fn dupeOpt(a: Allocator, value: ?[]const u8, default: []const u8) ![]const u8 {
    return a.dupe(u8, value orelse default);
}

fn expectDefaults(settings: *const Settings, validation_enabled: bool) !void {
    try std.testing.expectEqualStrings("ansible", settings.ansible_path);
    try std.testing.expect(settings.use_fqcn);
    try std.testing.expect(settings.provide_redirect_modules);
    try std.testing.expect(settings.provide_module_option_aliases);
    try std.testing.expectEqual(validation_enabled, settings.validation_enabled);
    try std.testing.expect(settings.lint_enabled);
    try std.testing.expectEqualStrings("ansible-lint", settings.lint_path);
    try std.testing.expectEqualStrings("", settings.lint_arguments);
    try std.testing.expect(!settings.auto_fix_on_save);
    try std.testing.expectEqualStrings("", settings.python_interpreter_path);
    try std.testing.expectEqualStrings("", settings.python_activation_script);
}

const custom_settings_json =
    \\{"ansible":{"ansible":{"path":"/custom/ansible","useFullyQualifiedCollectionNames":false},
    \\ "completion":{"provideRedirectModules":false,"provideModuleOptionAliases":false},
    \\ "validation":{"enabled":false,"lint":{"enabled":false,"path":"/custom/lint",
    \\ "arguments":"--exclude vendor","autoFixOnSave":true}},
    \\ "python":{"interpreterPath":"/custom/python","activationScript":"/custom/activate"}}}
;

fn expectCustomSettings(settings: *const Settings) !void {
    try std.testing.expectEqualStrings("/custom/ansible", settings.ansible_path);
    try std.testing.expect(!settings.use_fqcn);
    try std.testing.expect(!settings.provide_redirect_modules);
    try std.testing.expect(!settings.provide_module_option_aliases);
    try std.testing.expect(!settings.validation_enabled);
    try std.testing.expect(!settings.lint_enabled);
    try std.testing.expectEqualStrings("/custom/lint", settings.lint_path);
    try std.testing.expectEqualStrings("--exclude vendor", settings.lint_arguments);
    try std.testing.expect(settings.auto_fix_on_save);
    try std.testing.expectEqualStrings("/custom/python", settings.python_interpreter_path);
    try std.testing.expectEqualStrings("/custom/activate", settings.python_activation_script);
}

test "settings defaults match the documented upstream names" {
    var settings = Settings.init(std.testing.allocator);
    defer settings.deinit();
    try expectDefaults(&settings, true);
}

test "settings accept notification and initialization option wrappers and own strings" {
    const wrappers = [_]struct { prefix: []const u8, suffix: []const u8 }{
        .{ .prefix = "{\"settings\":", .suffix = "}" },
        .{ .prefix = "", .suffix = "" },
    };
    var settings = Settings.init(std.testing.allocator);
    defer settings.deinit();
    for (wrappers) |wrapper| {
        {
            const bytes = try std.mem.concat(std.testing.allocator, u8, &.{ wrapper.prefix, custom_settings_json, wrapper.suffix });
            defer std.testing.allocator.free(bytes);
            const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, bytes, .{ .allocate = .alloc_always });
            defer parsed.deinit();
            try settings.update(parsed.value);
        }
        // The input JSON and parsed strings have been freed.
        try expectCustomSettings(&settings);
    }
}

test "a partial settings update resets omitted fields to defaults" {
    var settings = Settings.init(std.testing.allocator);
    defer settings.deinit();
    const custom = try std.json.parseFromSlice(Value, std.testing.allocator, custom_settings_json, .{});
    defer custom.deinit();
    try settings.update(custom.value);
    const partial = try std.json.parseFromSlice(Value, std.testing.allocator,
        \\{"settings":{"ansible":{"validation":{"enabled":false}}}}
    , .{});
    defer partial.deinit();
    try settings.update(partial.value);
    try expectDefaults(&settings, false);
}

test "settings ignore unsupported names and fall back for wrong value types" {
    var settings = Settings.init(std.testing.allocator);
    defer settings.deinit();
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator,
        \\{"ansible":{"ansible":{"path":17,"useFullyQualifiedCollectionNames":"false"},
        \\ "completion":{"provideRedirectModules":null,"provideModuleOptionAliases":0},
        \\ "validation":{"enabled":[],"lint":{"enabled":"false","path":false,
        \\ "arguments":{},"autoFixOnSave":"true"}},
        \\ "python":{"interpreterPath":3,"activationScript":null},"unsupported":true}}
    , .{});
    defer parsed.deinit();
    try settings.update(parsed.value);
    try expectDefaults(&settings, true);
}


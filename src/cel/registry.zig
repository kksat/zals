const std = @import("std");
const Allocator = std.mem.Allocator;
const rule_mod = @import("rule.zig");
const schema = @import("schema.zig");
const builtins = @import("builtins.zig");
const limits = @import("limits.zig");
const env = @import("env.zig");
const paths = @import("../paths.zig");

pub const SeverityOverride = struct {
    rule_id: []const u8,
    severity: schema.Severity,
};

pub const RuleOptionValue = union(enum) {
    bool_v: bool,
    int_v: i64,
    string_v: []const u8,
    string_list_v: []const []const u8,
};

pub const RuleOptionEntry = struct {
    key: []const u8,
    value: RuleOptionValue,
};

pub const RuleOptionOverride = struct {
    rule_id: []const u8,
    entries: []const RuleOptionEntry,
};

pub const RegistryConfig = struct {
    include_builtins: bool = true,
    global_rule_files: []const []const u8 = &.{},
    workspace_rule_files: []const []const u8 = &.{},
    allow_workspace_rules: bool = false,
    workspace_roots: []const []const u8 = &.{},
    disabled_rules: []const []const u8 = &.{},
    severity_overrides: []const SeverityOverride = &.{},
    rule_options: []const RuleOptionOverride = &.{},
};

pub const RuleFileError = struct {
    file_path: []const u8,
    origin: rule_mod.RuleOriginKind,
    message: []const u8,
    line: u32,
    column: u32,
    end_line: u32 = 0,
    end_column: u32 = 0,
};

pub const ActiveRule = struct {
    compiled: rule_mod.CompiledRule,
    effective_severity: schema.Severity,
    options: []const RuleOptionEntry,
};

pub const RuleSet = struct {
    backing: Allocator,
    arena: *std.heap.ArenaAllocator,
    generation: u64,
    rules: []ActiveRule,
    errors: []const RuleFileError,
    watched_files: []const []const u8,

    pub fn deinit(self: *RuleSet) void {
        for (self.rules) |*r| r.compiled.deinit();
        self.arena.deinit();
        self.backing.destroy(self.arena);
    }

    pub fn isWatchedRuleFile(self: *const RuleSet, path: []const u8) bool {
        for (self.watched_files) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    pub fn cloneForWorker(self: *const RuleSet, backing: Allocator) !WorkerRuleSet {
        const arena = try backing.create(std.heap.ArenaAllocator);
        errdefer backing.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();

        var worker_rules = try a.alloc(WorkerRuleEntry, self.rules.len);
        var built: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < built) : (i += 1) {
                worker_rules[i].rule.deinit();
            }
        }
        for (self.rules, 0..) |*r, i| {
            worker_rules[i] = .{
                .rule = try r.compiled.cloneForWorker(backing),
                .effective_severity = r.effective_severity,
                .options = r.options,
            };
            built += 1;
        }
        return .{
            .backing = backing,
            .arena = arena,
            .generation = self.generation,
            .rules = worker_rules,
        };
    }
};

pub const WorkerRuleEntry = struct {
    rule: rule_mod.WorkerRule,
    effective_severity: schema.Severity,
    options: []const RuleOptionEntry,

    pub fn optionsToCel(self: WorkerRuleEntry, alloc: Allocator) !env.Value {
        if (self.options.len == 0) return env.emptyMapValue();
        var b = env.MapBuilder.init();
        errdefer b.deinit(alloc);
        for (self.options) |entry| {
            switch (entry.value) {
                .bool_v => |v| try b.putBool(alloc, entry.key, v),
                .int_v => |v| try b.putInt(alloc, entry.key, v),
                .string_v => |v| try b.putString(alloc, entry.key, v),
                .string_list_v => |v| try b.putStringList(alloc, entry.key, v),
            }
        }
        return b.finish(alloc) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.RepeatedKey => env.emptyMapValue(),
        };
    }
};

pub const WorkerRuleSet = struct {
    backing: Allocator,
    arena: *std.heap.ArenaAllocator,
    generation: u64,
    rules: []WorkerRuleEntry,

    pub fn deinit(self: *WorkerRuleSet) void {
        for (self.rules) |*r| r.rule.deinit();
        self.arena.deinit();
        self.backing.destroy(self.arena);
    }
};

pub fn buildRuleSet(backing: Allocator, generation: u64, config: RegistryConfig) !RuleSet {
    const arena = try backing.create(std.heap.ArenaAllocator);
    errdefer backing.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();

    var rules_list = std.ArrayList(ActiveRule).empty;
    errdefer {
        for (rules_list.items) |*r| r.compiled.deinit();
    }
    var errors_list = std.ArrayList(RuleFileError).empty;
    var watched_list = std.ArrayList([]const u8).empty;
    var seen_ids = std.StringHashMapUnmanaged(void).empty;

    if (config.include_builtins) {
        for (builtins.all) |b| {
            var res = try rule_mod.load(backing, b.source, .{
                .kind = .builtin,
                .file_path = b.name,
            });
            switch (res) {
                .ok => |*compiled| {
                    errdefer compiled.deinit();
                    try seen_ids.put(a, compiled.meta.id, {});
                    if (isDisabled(config.disabled_rules, compiled.meta.id)) {
                        compiled.deinit();
                        continue;
                    }
                    const sev = findSeverity(config.severity_overrides, compiled.meta.id) orelse compiled.meta.severity;
                    const opts = try dupeOptions(a, findOptions(config.rule_options, compiled.meta.id));
                    try rules_list.append(a, .{
                        .compiled = compiled.*,
                        .effective_severity = sev,
                        .options = opts,
                    });
                },
                .err => |*e| {
                    defer e.deinit();
                    try errors_list.append(a, .{
                        .file_path = try a.dupe(u8, b.name),
                        .origin = .builtin,
                        .message = try a.dupe(u8, e.info.message),
                        .line = e.info.pos.line,
                        .column = e.info.pos.column,
                        .end_line = e.info.end_pos.line,
                        .end_column = e.info.end_pos.column,
                    });
                },
            }
        }
    }

    for (config.global_rule_files) |raw_path| {
        if (raw_path.len == 0) continue;
        if (!std.fs.path.isAbsolute(raw_path)) {
            try errors_list.append(a, .{
                .file_path = try a.dupe(u8, raw_path),
                .origin = .global_file,
                .message = try a.dupe(u8, "global rule file path must be absolute"),
                .line = 1,
                .column = 1,
            });
            continue;
        }
        const owned_path = try a.dupe(u8, raw_path);
        try watched_list.append(a, owned_path);
        try loadCustomFile(backing, a, owned_path, .global_file, config, &seen_ids, &rules_list, &errors_list);
    }

    if (config.allow_workspace_rules) {
        for (config.workspace_roots) |root| {
            for (config.workspace_rule_files) |rel_path| {
                if (rel_path.len == 0) continue;
                if (std.fs.path.isAbsolute(rel_path) or hasParentTraversal(rel_path)) {
                    try errors_list.append(a, .{
                        .file_path = try a.dupe(u8, rel_path),
                        .origin = .workspace_file,
                        .message = try a.dupe(u8, "workspace rule file path must be relative within the workspace"),
                        .line = 1,
                        .column = 1,
                    });
                    continue;
                }
                const full = try std.fs.path.join(a, &.{ root, rel_path });
                try watched_list.append(a, full);
                try loadCustomFile(backing, a, full, .workspace_file, config, &seen_ids, &rules_list, &errors_list);
            }
        }
    }

    return .{
        .backing = backing,
        .arena = arena,
        .generation = generation,
        .rules = try rules_list.toOwnedSlice(a),
        .errors = try errors_list.toOwnedSlice(a),
        .watched_files = try watched_list.toOwnedSlice(a),
    };
}

fn loadCustomFile(
    backing: Allocator,
    a: Allocator,
    file_path: []const u8,
    origin: rule_mod.RuleOriginKind,
    config: RegistryConfig,
    seen_ids: *std.StringHashMapUnmanaged(void),
    rules_list: *std.ArrayList(ActiveRule),
    errors_list: *std.ArrayList(RuleFileError),
) !void {
    if (!std.mem.endsWith(u8, file_path, ".cel")) {
        try errors_list.append(a, .{
            .file_path = file_path,
            .origin = origin,
            .message = try a.dupe(u8, "custom rule files must have a .cel extension"),
            .line = 1,
            .column = 1,
        });
        return;
    }

    const content = paths.readFile(a, file_path, limits.max_rule_source_bytes + 1) orelse {
        try errors_list.append(a, .{
            .file_path = file_path,
            .origin = origin,
            .message = try a.dupe(u8, "unable to read rule file"),
            .line = 1,
            .column = 1,
        });
        return;
    };

    var res = try rule_mod.load(backing, content, .{
        .kind = origin,
        .file_path = file_path,
    });
    switch (res) {
        .ok => |*compiled| {
            errdefer compiled.deinit();
            if (seen_ids.contains(compiled.meta.id)) {
                const msg = try std.fmt.allocPrint(a, "duplicate rule id '{s}' conflicts with an existing rule", .{compiled.meta.id});
                compiled.deinit();
                try errors_list.append(a, .{
                    .file_path = file_path,
                    .origin = origin,
                    .message = msg,
                    .line = 1,
                    .column = 1,
                });
                return;
            }
            try seen_ids.put(a, compiled.meta.id, {});
            if (isDisabled(config.disabled_rules, compiled.meta.id)) {
                compiled.deinit();
                return;
            }
            const sev = findSeverity(config.severity_overrides, compiled.meta.id) orelse compiled.meta.severity;
            const opts = try dupeOptions(a, findOptions(config.rule_options, compiled.meta.id));
            try rules_list.append(a, .{
                .compiled = compiled.*,
                .effective_severity = sev,
                .options = opts,
            });
        },
        .err => |*e| {
            defer e.deinit();
            try errors_list.append(a, .{
                .file_path = file_path,
                .origin = origin,
                .message = try a.dupe(u8, e.info.message),
                .line = e.info.pos.line,
                .column = e.info.pos.column,
                .end_line = e.info.end_pos.line,
                .end_column = e.info.end_pos.column,
            });
        },
    }
}

fn hasParentTraversal(rel: []const u8) bool {
    var it = std.mem.splitAny(u8, rel, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

fn isDisabled(disabled: []const []const u8, rule_id: []const u8) bool {
    const family = if (std.mem.indexOfScalar(u8, rule_id, '[')) |i| rule_id[0..i] else rule_id;
    for (disabled) |d| {
        if (std.mem.eql(u8, d, rule_id) or std.mem.eql(u8, d, family)) return true;
    }
    return false;
}

fn findSeverity(overrides: []const SeverityOverride, rule_id: []const u8) ?schema.Severity {
    const family = if (std.mem.indexOfScalar(u8, rule_id, '[')) |i| rule_id[0..i] else rule_id;
    for (overrides) |ov| {
        if (std.mem.eql(u8, ov.rule_id, rule_id)) return ov.severity;
    }
    for (overrides) |ov| {
        if (std.mem.eql(u8, ov.rule_id, family)) return ov.severity;
    }
    return null;
}

fn findOptions(overrides: []const RuleOptionOverride, rule_id: []const u8) []const RuleOptionEntry {
    const family = if (std.mem.indexOfScalar(u8, rule_id, '[')) |i| rule_id[0..i] else rule_id;
    for (overrides) |ov| {
        if (std.mem.eql(u8, ov.rule_id, rule_id)) return ov.entries;
    }
    for (overrides) |ov| {
        if (std.mem.eql(u8, ov.rule_id, family)) return ov.entries;
    }
    return &.{};
}

fn dupeOptions(a: Allocator, entries: []const RuleOptionEntry) ![]const RuleOptionEntry {
    if (entries.len == 0) return &.{};
    const out = try a.alloc(RuleOptionEntry, entries.len);
    for (entries, 0..) |entry, i| {
        out[i] = .{
            .key = try a.dupe(u8, entry.key),
            .value = switch (entry.value) {
                .bool_v => |v| .{ .bool_v = v },
                .int_v => |v| .{ .int_v = v },
                .string_v => |v| .{ .string_v = try a.dupe(u8, v) },
                .string_list_v => |list| blk: {
                    const duped = try a.alloc([]const u8, list.len);
                    for (list, 0..) |s, j| duped[j] = try a.dupe(u8, s);
                    break :blk .{ .string_list_v = duped };
                },
            },
        };
    }
    return out;
}

test "builtin ruleset loads cleanly and workspace rules require permission" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "custom.cel",
        .data =
        \\zals.Rule{
        \\  id: "custom/ws-only",
        \\  target: "task",
        \\  severity: "warning",
        \\  condition: node.short_action == "debug",
        \\  message: "no debug"
        \\}
        ,
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var rs_denied = try buildRuleSet(std.testing.allocator, 1, .{
        .workspace_roots = &.{root},
        .workspace_rule_files = &.{"custom.cel"},
        .allow_workspace_rules = false,
    });
    defer rs_denied.deinit();
    try std.testing.expectEqual(@as(usize, 0), rs_denied.errors.len);
    try std.testing.expectEqual(builtins.all.len, rs_denied.rules.len);

    var rs_allowed = try buildRuleSet(std.testing.allocator, 2, .{
        .workspace_roots = &.{root},
        .workspace_rule_files = &.{"custom.cel"},
        .allow_workspace_rules = true,
    });
    defer rs_allowed.deinit();
    try std.testing.expectEqual(@as(usize, 0), rs_allowed.errors.len);
    try std.testing.expectEqual(builtins.all.len + 1, rs_allowed.rules.len);
}

test "duplicate custom rule id is rejected and invalid rule is isolated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dup.cel",
        .data =
        \\zals.Rule{
        \\  id: "name[play]",
        \\  target: "play",
        \\  severity: "error",
        \\  condition: true,
        \\  message: "override attempt"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "broken.cel",
        .data = "zals.Rule{ id: \"custom/broken\", target: \"task\", severity: \"error\", condition: ???, message: \"x\" }",
    });
    const dup_path = try tmp.dir.realPathFileAlloc(std.testing.io, "dup.cel", std.testing.allocator);
    defer std.testing.allocator.free(dup_path);
    const broken_path = try tmp.dir.realPathFileAlloc(std.testing.io, "broken.cel", std.testing.allocator);
    defer std.testing.allocator.free(broken_path);

    var rs = try buildRuleSet(std.testing.allocator, 1, .{
        .global_rule_files = &.{ dup_path, broken_path },
    });
    defer rs.deinit();
    try std.testing.expectEqual(builtins.all.len, rs.rules.len);
    try std.testing.expectEqual(@as(usize, 2), rs.errors.len);
}

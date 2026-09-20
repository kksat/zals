//! Module documentation loaded from `ansible-doc --json`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const exec = @import("../exec/root.zig");
const json_util = @import("../lsp/json_util.zig");
const AnsibleConfig = @import("ansible_config.zig").AnsibleConfig;

pub const Option = struct {
    name: []const u8,
    description: []const u8,
    type: []const u8,
    required: bool = false,
    aliases: []const []const u8 = &.{},
    choices: []const []const u8 = &.{},
    suboptions: []const Option = &.{},
    default: ?[]const u8 = null,
    elements: []const u8 = "",
};

pub const Module = struct {
    name: []const u8,
    /// Short description (one line).
    description: []const u8,
    /// Full description paragraphs.
    long_description: []const []const u8 = &.{},
    requirements: []const []const u8 = &.{},
    notes: []const []const u8 = &.{},
    deprecated: bool = false,
    filename: []const u8,
    options: std.StringHashMap(Option),
};

pub const CatalogEntry = struct {
    name: []const u8,
    description: []const u8,
};

pub const DocsLibrary = struct {
    allocator: Allocator,
    runner: exec.Runner,
    ansible_doc: []const u8,
    /// Short-name / FQCN → catalog description. Keys and values owned by `arena`.
    catalog: std.StringHashMap(CatalogEntry),
    modules: std.StringHashMap(Module),
    /// All module FQCNs discovered on disk (builtin + collections + redirects).
    /// Used for completion; keys are owned by `arena`.
    module_fqcns: std.StringHashMap(void),
    arena: std.heap.ArenaAllocator,
    ready: bool = false,
    /// Guards `catalog` and `modules`. Held only while mutating/reading the
    /// maps, never across an `ansible-doc` subprocess.
    mutex: std.Thread.Mutex = .{},
    /// Ansible version string used as part of the on-disk cache fingerprint.
    ansible_version: []const u8 = "",

    pub fn init(allocator: Allocator, runner: exec.Runner, ansible_doc: []const u8) DocsLibrary {
        return .{
            .allocator = allocator,
            .runner = runner,
            .ansible_doc = ansible_doc,
            .catalog = std.StringHashMap(CatalogEntry).init(allocator),
            .modules = std.StringHashMap(Module).init(allocator),
            .module_fqcns = std.StringHashMap(void).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *DocsLibrary) void {
        self.catalog.deinit();
        var it = self.modules.iterator();
        while (it.next()) |e| e.value_ptr.options.deinit();
        self.modules.deinit();
        self.module_fqcns.deinit();
        self.arena.deinit();
    }

    /// Scan installed collections and redirect routes for module FQCNs.
    pub fn scanModuleIndex(self: *DocsLibrary, config: *AnsibleConfig) void {
        var index = @import("module_index.zig").Index.init(self.allocator, self.runner);
        defer index.deinit();
        index.scan(config);
        const a = self.arena.allocator();
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = index.fqcns.iterator();
        while (it.next()) |e| {
            const key = a.dupe(u8, e.key_ptr.*) catch continue;
            self.module_fqcns.put(key, {}) catch continue;
        }
    }

    pub fn loadCatalog(self: *DocsLibrary) !void {
        const argv = [_][]const u8{ self.ansible_doc, "-l", "--json", "-t", "module" };
        const result = self.runner.run(self.allocator, &argv) catch return;
        defer result.deinit(self.allocator);
        if (result.stdout.len == 0) return;

        const parsed = std.json.parseFromSlice(Value, self.allocator, result.stdout, .{}) catch return;
        defer parsed.deinit();
        const a = self.arena.allocator();
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (parsed.value) {
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |e| {
                    const name = try a.dupe(u8, e.key_ptr.*);
                    const desc = descriptionOf(e.value_ptr.*) orelse "";
                    try self.catalog.put(name, .{
                        .name = name,
                        .description = try a.dupe(u8, desc),
                    });
                }
            },
            else => {},
        }
        self.ready = true;
    }

    pub fn findModule(self: *DocsLibrary, name: []const u8) ?Module {
        self.mutex.lock();
        if (self.modules.get(name)) |m| {
            self.mutex.unlock();
            return m;
        }
        self.mutex.unlock();
        self.fetchOne(name) catch {};
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.modules.get(name);
    }

    /// Resolve `name` as an FQCN, `ansible.builtin.*`, or a declared collection.
    pub fn findModuleInContext(self: *DocsLibrary, arena: Allocator, name: []const u8, collections: []const []const u8) ?Module {
        if (self.findModule(name)) |m| return m;
        if (std.mem.indexOfScalar(u8, name, '.') != null) return null;

        const builtin = std.fmt.allocPrint(arena, "ansible.builtin.{s}", .{name}) catch return null;
        if (self.findModule(builtin)) |m| return m;

        for (collections) |c| {
            const fqcn = std.fmt.allocPrint(arena, "{s}.{s}", .{ c, name }) catch continue;
            if (self.findModule(fqcn)) |m| return m;
        }

        var it = self.catalog.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (std.mem.endsWith(u8, key, name) and key.len > name.len and key[key.len - name.len - 1] == '.') {
                if (self.findModule(key)) |m| return m;
            }
        }
        return null;
    }

    pub fn ensureModule(self: *DocsLibrary, name: []const u8) void {
        self.mutex.lock();
        const present = self.modules.contains(name);
        self.mutex.unlock();
        if (present) return;
        self.fetchOne(name) catch {};
    }

    pub fn catalogCount(self: *DocsLibrary) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.catalog.count();
    }

    /// Fast, non-fetching check for a known module FQCN.
    pub fn hasModuleName(self: *DocsLibrary, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.module_fqcns.contains(name) or self.catalog.contains(name);
    }

    fn fetchOne(self: *DocsLibrary, name: []const u8) !void {
        const argv = [_][]const u8{ self.ansible_doc, "--json", "-t", "module", name };
        const result = try self.runner.run(self.allocator, &argv);
        defer result.deinit(self.allocator);
        if (result.stdout.len == 0) return;
        const parsed = std.json.parseFromSlice(Value, self.allocator, result.stdout, .{}) catch return;
        defer parsed.deinit();
        try self.ingestDocs(parsed.value);
    }

    /// Fetch full docs for several modules in one `ansible-doc` invocation.
    pub fn fetchMany(self: *DocsLibrary, names: []const []const u8) !void {
        if (names.len == 0) return;
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{ self.ansible_doc, "--json", "-t", "module" });
        try argv.appendSlice(self.allocator, names);
        const result = try self.runner.run(self.allocator, argv.items);
        defer result.deinit(self.allocator);
        if (result.stdout.len == 0) return;
        const parsed = std.json.parseFromSlice(Value, self.allocator, result.stdout, .{}) catch return;
        defer parsed.deinit();
        try self.ingestDocs(parsed.value);
    }

    fn ingestDocs(self: *DocsLibrary, value: Value) !void {
        const a = self.arena.allocator();
        const obj = switch (value) {
            .object => |o| o,
            else => return,
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = obj.iterator();
        while (it.next()) |e| {
            const doc = json_util.field(e.value_ptr.*, "doc") orelse continue;
            const filename = json_util.string(doc, "filename") orelse "";
            var options = std.StringHashMap(Option).init(self.allocator);
            if (json_util.object(doc, "options")) |opts| {
                var oi = opts.iterator();
                while (oi.next()) |opt| {
                    const opt_name = try a.dupe(u8, opt.key_ptr.*);
                    try options.put(opt_name, .{
                        .name = opt_name,
                        .description = try a.dupe(u8, descriptionOf(opt.value_ptr.*) orelse ""),
                        .type = try a.dupe(u8, json_util.string(opt.value_ptr.*, "type") orelse ""),
                        .required = json_util.boolean(opt.value_ptr.*, "required") orelse false,
                        .suboptions = try parseSuboptions(a, opt.value_ptr.*),
                        .default = try defaultString(a, opt.value_ptr.*),
                        .elements = try a.dupe(u8, json_util.string(opt.value_ptr.*, "elements") orelse ""),
                    });
                }
            }
            const stored_name = try a.dupe(u8, e.key_ptr.*);
            try self.modules.put(stored_name, .{
                .name = stored_name,
                .description = try a.dupe(u8, shortDescriptionOf(doc) orelse ""),
                .long_description = try stringList(a, json_util.field(doc, "description") orelse Value.null),
                .requirements = try stringList(a, json_util.field(doc, "requirements") orelse Value.null),
                .notes = try stringList(a, json_util.field(doc, "notes") orelse Value.null),
                .deprecated = json_util.field(doc, "deprecated") != null,
                .filename = try a.dupe(u8, filename),
                .options = options,
            });
        }
    }
};

fn parseSuboptions(a: Allocator, opt: Value) ![]const Option {
    const subs = json_util.object(opt, "suboptions") orelse return &.{};
    var list = std.ArrayList(Option).empty;
    var it = subs.iterator();
    while (it.next()) |e| {
        try list.append(a, .{
            .name = try a.dupe(u8, e.key_ptr.*),
            .description = try a.dupe(u8, descriptionOf(e.value_ptr.*) orelse ""),
            .type = try a.dupe(u8, json_util.string(e.value_ptr.*, "type") orelse ""),
            .required = json_util.boolean(e.value_ptr.*, "required") orelse false,
            .suboptions = try parseSuboptions(a, e.value_ptr.*),
            .default = try defaultString(a, e.value_ptr.*),
            .elements = try a.dupe(u8, json_util.string(e.value_ptr.*, "elements") orelse ""),
        });
    }
    return try list.toOwnedSlice(a);
}

/// Coerce a string-or-list JSON value into a list of strings.
fn stringList(a: Allocator, v: Value) ![]const []const u8 {
    switch (v) {
        .array => |arr| {
            var list = std.ArrayList([]const u8).empty;
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| try list.append(a, try a.dupe(u8, s)),
                    else => {},
                }
            }
            return try list.toOwnedSlice(a);
        },
        .string => |s| {
            const list = try a.alloc([]const u8, 1);
            list[0] = try a.dupe(u8, s);
            return list;
        },
        else => return &.{},
    }
}

/// Render an option's default value as a string, or null when absent.
fn defaultString(a: Allocator, opt: Value) !?[]const u8 {
    const d = json_util.field(opt, "default") orelse return null;
    return switch (d) {
        .null => null,
        .string => |s| try a.dupe(u8, s),
        .bool => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        else => try std.json.Stringify.valueAlloc(a, d, .{}),
    };
}

/// Prefer `short_description` for modules; fall back to `description`.
fn shortDescriptionOf(v: Value) ?[]const u8 {
    if (json_util.string(v, "short_description")) |s| return s;
    return descriptionOf(v);
}

fn descriptionOf(v: Value) ?[]const u8 {
    if (json_util.string(v, "description")) |s| return s;
    if (json_util.field(v, "description")) |d| {
        switch (d) {
            .array => |arr| {
                if (arr.items.len > 0) {
                    return switch (arr.items[0]) {
                        .string => |s| s,
                        else => null,
                    };
                }
            },
            .string => |s| return s,
            else => {},
        }
    }
    if (json_util.string(v, "short_description")) |s| return s;
    return null;
}

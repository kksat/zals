//! Module documentation loaded from `ansible-doc --json`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const exec = @import("../exec/root.zig");
const json_util = @import("../lsp/json_util.zig");
const AnsibleConfig = @import("ansible_config.zig").AnsibleConfig;

/// Options returned by a library lookup are immutable borrowed views; all
/// strings and nested slices remain valid until that library is deinitialized.
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

/// A library lookup returns an immutable borrowed view. All backing storage
/// remains valid until library deinit, even when later ingestion replaces this
/// name. Library teardown requires readers to finish and workers to be joined.
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
    options: []const Option = &.{},

    pub fn getOption(self: Module, name: []const u8) ?Option {
        for (self.options) |opt| {
            if (std.mem.eql(u8, opt.name, name)) return opt;
        }
        return null;
    }
};

pub const CatalogEntry = struct {
    name: []const u8,
    description: []const u8,
};

/// Startup disk-cache format, owned with the docs codec rather than the file
/// adapter. Keep the existing version-3 representation compatible.
pub const cache_format_version = 3;

/// Owns synchronized docs storage. Strings and nested slices are append-only in
/// the arena so borrowed views remain valid until teardown.
/// Callers use operations below, not the storage fields or mutex.
pub const DocsLibrary = struct {
    allocator: Allocator,
    runner: exec.Runner,
    ansible_doc: []const u8,
    /// Immutable per-file subprocess snapshot; owned by the server context.
    execution: exec.Options = .{},
    /// Short-name / FQCN → catalog description. Keys and values owned by `arena`.
    catalog: std.StringHashMap(CatalogEntry),
    modules: std.StringHashMap(Module),
    /// All module FQCNs discovered on disk (builtin + collections + redirects).
    /// Used for completion; keys are owned by `arena`.
    module_fqcns: std.StringHashMap(void),
    arena: std.heap.ArenaAllocator,
    ready: bool = false,
    /// Guards all maps, arena allocation, readiness, and version. Never held
    /// across a subprocess or disk I/O; cache encoding stays under the lock.
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
        self.modules.deinit();
        self.module_fqcns.deinit();
        self.arena.deinit();
    }

    /// Scan installed collections and redirect routes for module FQCNs.
    pub fn scanModuleIndex(self: *DocsLibrary, config: *AnsibleConfig) void {
        self.scanModulePaths(config.collectionsPaths());
    }

    pub fn scanModulePaths(self: *DocsLibrary, collection_paths: []const []const u8) void {
        var index = @import("module_index.zig").Index.init(self.allocator, self.runner);
        defer index.deinit();
        index.execution = self.execution;
        index.scan(collection_paths);
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
        const result = self.runner.runWithOptions(self.allocator, &argv, self.execution) catch return;
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

    /// Fetch on a miss; return an immutable view borrowing for library lifetime.
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

        // Bootstrap may still be adding catalog entries. Snapshot candidate
        // names under the lock, then release it before fetching any docs.
        var candidates = std.array_list.Managed([]const u8).init(arena);
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var it = self.catalog.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                if (std.mem.endsWith(u8, key, name) and key.len > name.len and key[key.len - name.len - 1] == '.') {
                    candidates.append(key) catch return null;
                }
            }
        }
        for (candidates.items) |key| {
            if (self.findModule(key)) |m| return m;
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

    /// Append filesystem-discovered FQCNs, including redirects, not catalog
    /// names. The output list owns its storage; strings borrow until deinit.
    pub fn writeModuleFqcns(self: *DocsLibrary, out: *std.array_list.Managed([]const u8)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.module_fqcns.iterator();
        while (it.next()) |e| try out.append(e.key_ptr.*);
    }

    /// Snapshot catalog names without fetched docs. Caller frees the slice;
    /// its immutable strings borrow until library deinit. Discovery-only names
    /// are intentionally excluded. Concurrent fetches may make it redundant.
    pub fn missingCatalogNames(self: *DocsLibrary, allocator: Allocator) ![][]const u8 {
        var names = std.ArrayList([]const u8).empty;
        errdefer names.deinit(allocator);
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.catalog.iterator();
        while (it.next()) |e| {
            if (!self.modules.contains(e.key_ptr.*))
                try names.append(allocator, e.key_ptr.*);
        }
        return names.toOwnedSlice(allocator);
    }

    /// Loader-only: retain an owned version for startup cache diagnostics.
    pub fn recordAnsibleVersion(self: *DocsLibrary, version: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ansible_version = try self.arena.allocator().dupe(u8, version);
    }

    /// Startup-cache capability: return caller-owned encoded bytes from one
    /// coherent library revision. No borrowed storage escapes and no disk I/O
    /// happens here; the cache adapter writes only after this returns.
    pub fn encodeCache(self: *DocsLibrary, allocator: Allocator) ![]u8 {
        // Build the JSON tree in a scratch arena so nested maps are freed at once.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var root = std.json.ObjectMap.init(a);
        try root.put("version", .{ .integer = cache_format_version });
        self.mutex.lock();
        defer self.mutex.unlock();
        try root.put("ansible_version", .{ .string = self.ansible_version });

        var cat = std.json.ObjectMap.init(a);
        var it = self.catalog.iterator();
        while (it.next()) |e| try cat.put(e.key_ptr.*, .{ .string = e.value_ptr.description });
        try root.put("catalog", .{ .object = cat });

        var mods = std.json.ObjectMap.init(a);
        var mit = self.modules.iterator();
        while (mit.next()) |e| {
            const m = e.value_ptr.*;
            var mo = std.json.ObjectMap.init(a);
            try mo.put("description", .{ .string = m.description });
            try mo.put("long_description", try stringArray(a, m.long_description));
            try mo.put("requirements", try stringArray(a, m.requirements));
            try mo.put("notes", try stringArray(a, m.notes));
            try mo.put("deprecated", .{ .bool = m.deprecated });
            try mo.put("filename", .{ .string = m.filename });
            var opts = std.json.ObjectMap.init(a);
            for (m.options) |opt| {
                try opts.put(opt.name, try cacheOptionToJson(a, opt));
            }
            try mo.put("options", .{ .object = opts });
            try mods.put(e.key_ptr.*, .{ .object = mo });
        }
        try root.put("modules", .{ .object = mods });

        return std.json.Stringify.valueAlloc(allocator, Value{ .object = root }, .{});
    }

    /// Startup-cache capability: parse/validate before ingestion. Returns false
    /// for invalid JSON or an incompatible format without modifying the library.
    /// Retains copied docs just like subprocess ingestion; never shares them
    /// with per-file contextual libraries.
    pub fn restoreCache(self: *DocsLibrary, allocator: Allocator, bytes: []const u8) !bool {
        const parsed = std.json.parseFromSlice(Value, allocator, bytes, .{}) catch return false;
        defer parsed.deinit();
        const v = json_util.integer(parsed.value, "version") orelse return false;
        if (v != cache_format_version) return false;

        const a = self.arena.allocator();
        self.mutex.lock();
        defer self.mutex.unlock();

        if (json_util.string(parsed.value, "ansible_version")) |ver| {
            self.ansible_version = try a.dupe(u8, ver);
        }

        if (json_util.object(parsed.value, "catalog")) |cat| {
            var it = cat.iterator();
            while (it.next()) |e| {
                const name = try a.dupe(u8, e.key_ptr.*);
                const desc = switch (e.value_ptr.*) {
                    .string => |s| s,
                    else => "",
                };
                try self.catalog.put(name, .{ .name = name, .description = try a.dupe(u8, desc) });
            }
        }

        if (json_util.object(parsed.value, "modules")) |mods| {
            var it = mods.iterator();
            while (it.next()) |e| {
                const name = try a.dupe(u8, e.key_ptr.*);
                var options = std.ArrayList(Option).empty;
                if (json_util.object(e.value_ptr.*, "options")) |opts| {
                    var oi = opts.iterator();
                    while (oi.next()) |oe| {
                        var opt = try cacheOptionFromJson(a, oe.value_ptr.*);
                        opt.name = try a.dupe(u8, oe.key_ptr.*);
                        try options.append(a, opt);
                    }
                }
                try self.modules.put(name, .{
                    .name = name,
                    .description = try a.dupe(u8, json_util.string(e.value_ptr.*, "description") orelse ""),
                    .long_description = try cacheStringList(a, json_util.field(e.value_ptr.*, "long_description") orelse Value.null),
                    .requirements = try cacheStringList(a, json_util.field(e.value_ptr.*, "requirements") orelse Value.null),
                    .notes = try cacheStringList(a, json_util.field(e.value_ptr.*, "notes") orelse Value.null),
                    .deprecated = json_util.boolean(e.value_ptr.*, "deprecated") orelse false,
                    .filename = try a.dupe(u8, json_util.string(e.value_ptr.*, "filename") orelse ""),
                    .options = try options.toOwnedSlice(a),
                });
            }
        }

        self.ready = true;
        return true;
    }

    fn fetchOne(self: *DocsLibrary, name: []const u8) !void {
        const argv = [_][]const u8{ self.ansible_doc, "--json", "-t", "module", name };
        const result = try self.runner.runWithOptions(self.allocator, &argv, self.execution);
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
        const result = try self.runner.runWithOptions(self.allocator, argv.items, self.execution);
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
            var options = std.ArrayList(Option).empty;
            if (json_util.object(doc, "options")) |opts| {
                var oi = opts.iterator();
                while (oi.next()) |opt| {
                    try options.append(a, .{
                        .name = try a.dupe(u8, opt.key_ptr.*),
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
                .options = try options.toOwnedSlice(a),
            });
        }
    }
};

fn cacheOptionToJson(a: Allocator, o: Option) !Value {
    var oo = std.json.ObjectMap.init(a);
    try oo.put("description", .{ .string = o.description });
    try oo.put("type", .{ .string = o.type });
    try oo.put("required", .{ .bool = o.required });
    try oo.put("default", if (o.default) |d| .{ .string = d } else .null);
    try oo.put("elements", .{ .string = o.elements });
    if (o.suboptions.len > 0) {
        var subs = std.json.ObjectMap.init(a);
        for (o.suboptions) |s| try subs.put(s.name, try cacheOptionToJson(a, s));
        try oo.put("suboptions", .{ .object = subs });
    }
    return .{ .object = oo };
}

fn cacheOptionFromJson(a: Allocator, v: Value) !Option {
    var sub: []const Option = &.{};
    if (json_util.object(v, "suboptions")) |subs| {
        var list = std.ArrayList(Option).empty;
        var it = subs.iterator();
        while (it.next()) |e| {
            var o = try cacheOptionFromJson(a, e.value_ptr.*);
            o.name = try a.dupe(u8, e.key_ptr.*);
            try list.append(a, o);
        }
        sub = try list.toOwnedSlice(a);
    }
    return .{
        .name = "",
        .description = try a.dupe(u8, json_util.string(v, "description") orelse ""),
        .type = try a.dupe(u8, json_util.string(v, "type") orelse ""),
        .required = json_util.boolean(v, "required") orelse false,
        .suboptions = sub,
        .default = if (json_util.string(v, "default")) |d| try a.dupe(u8, d) else null,
        .elements = try a.dupe(u8, json_util.string(v, "elements") orelse ""),
    };
}

fn stringArray(a: Allocator, items: []const []const u8) !Value {
    var arr = std.json.Array.init(a);
    for (items) |s| try arr.append(.{ .string = s });
    return .{ .array = arr };
}

fn cacheStringList(a: Allocator, v: Value) ![]const []const u8 {
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
        else => return &.{},
    }
}

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

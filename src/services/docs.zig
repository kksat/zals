//! Module documentation loaded from `ansible-doc --json`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const exec = @import("../exec/root.zig");
const docs_json = @import("docs_json.zig");
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
    attempted: std.StringHashMap(void),
    arena: std.heap.ArenaAllocator,
    extra_arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty,
    ready: bool = false,
    /// Guards all maps, arena allocation, readiness, and version. Never held
    /// across a subprocess or disk I/O; cache encoding stays under the lock.
    mutex: @import("../sync.zig").Mutex = .{},
    /// Ansible version string used as part of the on-disk cache fingerprint.
    ansible_version: []const u8 = "",
    cache_complete: bool = false,

    pub fn init(allocator: Allocator, runner: exec.Runner, ansible_doc: []const u8) DocsLibrary {
        return .{
            .allocator = allocator,
            .runner = runner,
            .ansible_doc = ansible_doc,
            .catalog = std.StringHashMap(CatalogEntry).init(allocator),
            .modules = std.StringHashMap(Module).init(allocator),
            .module_fqcns = std.StringHashMap(void).init(allocator),
            .attempted = std.StringHashMap(void).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *DocsLibrary) void {
        self.catalog.deinit();
        self.modules.deinit();
        self.module_fqcns.deinit();
        self.attempted.deinit();
        for (self.extra_arenas.items) |*a| a.deinit();
        self.extra_arenas.deinit(self.allocator);
        self.arena.deinit();
    }

    fn adoptArenaAssumeCapacity(self: *DocsLibrary, stage: *std.heap.ArenaAllocator) void {
        if (stage.queryCapacity() == 0) return;
        self.extra_arenas.appendAssumeCapacity(stage.*);
        stage.* = std.heap.ArenaAllocator.init(self.allocator);
    }

    /// Seed `ansible.builtin.*` modules from `base` (which loads the on-disk
    /// docs cache), since built-in modules do not vary with collection paths.
    pub fn copyBuiltinsFrom(self: *DocsLibrary, base: *DocsLibrary) void {
        base.mutex.lock();
        defer base.mutex.unlock();
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = base.modules.iterator();
        while (it.next()) |e| {
            if (!std.mem.startsWith(u8, e.key_ptr.*, "ansible.builtin.")) continue;
            if (self.modules.contains(e.key_ptr.*)) continue;
            self.modules.put(e.key_ptr.*, e.value_ptr.*) catch {};
        }
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

    /// Load full docs for every installed module in one `ansible-doc
    /// --metadata-dump` call (the same shape `fetchMany` ingests, for all
    /// collections at once). Returns false when the command or its output is
    /// unusable — for example an ansible-core without `--metadata-dump` —
    /// so the caller can fall back to batched `fetchMany` calls.
    pub fn loadMetadataDump(self: *DocsLibrary) bool {
        const argv = [_][]const u8{ self.ansible_doc, "--metadata-dump" };
        const result = self.runner.runWithOptions(self.allocator, &argv, self.execution) catch return false;
        defer result.deinit(self.allocator);
        if (!result.success() or result.stdout.len == 0) return false;
        if (!docs_json.validate(self.allocator, result.stdout)) return false;

        var stage = std.heap.ArenaAllocator.init(self.allocator);
        defer stage.deinit();
        var modules = std.ArrayList(Module).empty;
        defer modules.deinit(self.allocator);
        {
            var parser = docs_json.Parser.init(stage.allocator(), self.allocator, result.stdout);
            defer parser.deinit();
            const found = parser.metadataDump(&modules) catch return false;
            if (!found) return false;
        }
        const add_count = std.math.cast(u32, modules.items.len) orelse return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.modules.ensureUnusedCapacity(add_count) catch return false;
        self.extra_arenas.ensureUnusedCapacity(self.allocator, 1) catch return false;
        self.adoptArenaAssumeCapacity(&stage);
        for (modules.items) |m| self.modules.putAssumeCapacity(m.name, m);
        return true;
    }

    pub fn loadCatalog(self: *DocsLibrary) !void {
        const argv = [_][]const u8{ self.ansible_doc, "-l", "--json", "-t", "module" };
        const result = self.runner.runWithOptions(self.allocator, &argv, self.execution) catch return;
        defer result.deinit(self.allocator);
        if (result.stdout.len == 0) return;
        if (!docs_json.validate(self.allocator, result.stdout)) return;

        var stage = std.heap.ArenaAllocator.init(self.allocator);
        defer stage.deinit();
        var entries = std.ArrayList(CatalogEntry).empty;
        defer entries.deinit(self.allocator);
        {
            var parser = docs_json.Parser.init(stage.allocator(), self.allocator, result.stdout);
            defer parser.deinit();
            parser.catalogEntries(&entries) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
        }
        const add_count = std.math.cast(u32, entries.items.len) orelse return error.OutOfMemory;
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.catalog.ensureUnusedCapacity(add_count);
        try self.extra_arenas.ensureUnusedCapacity(self.allocator, 1);
        self.adoptArenaAssumeCapacity(&stage);
        for (entries.items) |entry| self.catalog.putAssumeCapacity(entry.name, entry);
        self.ready = true;
    }

    /// Fetch on a miss; return an immutable view borrowing for library lifetime.
    pub fn findModule(self: *DocsLibrary, name: []const u8) ?Module {
        self.mutex.lock();
        if (self.modules.get(name)) |m| {
            self.mutex.unlock();
            return m;
        }
        if (self.attempted.contains(name)) {
            self.mutex.unlock();
            return null;
        }
        if (self.ready and !self.catalog.contains(name) and !self.module_fqcns.contains(name)) {
            self.mutex.unlock();
            return null;
        }
        if (self.arena.allocator().dupe(u8, name)) |owned| {
            self.attempted.put(owned, {}) catch {};
        } else |_| {}
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

    /// Batch-fetch any uncached candidate module names in one `ansible-doc`
    /// subprocess so whole-document passes (such as semantic tokens) never
    /// shell out once per task.
    pub fn prefetchCandidates(self: *DocsLibrary, a: Allocator, raw_names: []const []const u8) void {
        var batch = std.ArrayList([]const u8).empty;
        defer batch.deinit(a);
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (raw_names) |raw| {
                const candidates = [_]?[]const u8{
                    raw,
                    if (std.mem.indexOfScalar(u8, raw, '.') == null)
                        std.fmt.allocPrint(a, "ansible.builtin.{s}", .{raw}) catch null
                    else
                        null,
                };
                for (candidates) |maybe_name| {
                    const name = maybe_name orelse continue;
                    if (self.modules.contains(name) or self.attempted.contains(name)) continue;
                    if (self.ready and !self.catalog.contains(name) and !self.module_fqcns.contains(name)) continue;
                    if (self.arena.allocator().dupe(u8, name)) |owned| {
                        self.attempted.put(owned, {}) catch continue;
                        batch.append(a, owned) catch {};
                    } else |_| {}
                }
            }
        }
        if (batch.items.len > 0) {
            self.fetchMany(batch.items) catch {};
        }
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
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.writeCacheJson(&aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    fn writeCacheJson(self: *DocsLibrary, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var jw: std.json.Stringify = .{ .writer = writer };
        try jw.beginObject();
        try jw.objectField("version");
        try jw.write(cache_format_version);
        try jw.objectField("ansible_version");
        try jw.write(self.ansible_version);
        try jw.objectField("complete");
        try jw.write(self.cache_complete);

        try jw.objectField("catalog");
        try jw.beginObject();
        var it = self.catalog.iterator();
        while (it.next()) |e| {
            try jw.objectField(e.key_ptr.*);
            try jw.write(e.value_ptr.description);
        }
        try jw.endObject();

        try jw.objectField("modules");
        try jw.beginObject();
        var mit = self.modules.iterator();
        while (mit.next()) |e| {
            const m = e.value_ptr.*;
            try jw.objectField(e.key_ptr.*);
            try jw.beginObject();
            try jw.objectField("description");
            try jw.write(m.description);
            try jw.objectField("long_description");
            try jw.write(m.long_description);
            try jw.objectField("requirements");
            try jw.write(m.requirements);
            try jw.objectField("notes");
            try jw.write(m.notes);
            try jw.objectField("deprecated");
            try jw.write(m.deprecated);
            try jw.objectField("filename");
            try jw.write(m.filename);
            try jw.objectField("options");
            try jw.beginObject();
            for (m.options) |opt| {
                try jw.objectField(opt.name);
                try writeCacheOption(&jw, opt);
            }
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endObject();
        try jw.endObject();
    }

    /// Startup-cache capability: parse/validate before ingestion. Returns false
    /// for invalid JSON or an incompatible format without modifying the library.
    /// Retains copied docs just like subprocess ingestion; never shares them
    /// with per-file contextual libraries.
    pub fn restoreCache(self: *DocsLibrary, allocator: Allocator, bytes: []const u8) !bool {
        if (!docs_json.validate(allocator, bytes)) return false;
        const version = docs_json.topLevelVersion(allocator, bytes) orelse return false;
        if (version != cache_format_version) return false;

        var stage = std.heap.ArenaAllocator.init(self.allocator);
        defer stage.deinit();
        var cache = docs_json.CacheDocument{};
        defer cache.deinit(allocator);
        {
            var parser = docs_json.Parser.init(stage.allocator(), allocator, bytes);
            defer parser.deinit();
            parser.cacheDocument(&cache) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
        }

        const cat_add = std.math.cast(u32, cache.catalog.items.len) orelse return error.OutOfMemory;
        const mod_add = std.math.cast(u32, cache.modules.items.len) orelse return error.OutOfMemory;

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.catalog.ensureUnusedCapacity(cat_add);
        try self.modules.ensureUnusedCapacity(mod_add);
        try self.extra_arenas.ensureUnusedCapacity(self.allocator, 1);
        self.adoptArenaAssumeCapacity(&stage);

        if (cache.ansible_version) |ver| self.ansible_version = ver;
        self.cache_complete = cache.complete;
        for (cache.catalog.items) |entry| self.catalog.putAssumeCapacity(entry.name, entry);
        for (cache.modules.items) |m| self.modules.putAssumeCapacity(m.name, m);

        self.ready = true;
        return true;
    }

    pub fn markBootstrapComplete(self: *DocsLibrary) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cache_complete = true;
    }

    pub fn cacheComplete(self: *DocsLibrary) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cache_complete;
    }

    fn fetchOne(self: *DocsLibrary, name: []const u8) !void {
        const argv = [_][]const u8{ self.ansible_doc, "--json", "-t", "module", name };
        const result = try self.runner.runWithOptions(self.allocator, &argv, self.execution);
        defer result.deinit(self.allocator);
        if (result.stdout.len == 0) return;
        try self.ingestModuleJson(result.stdout);
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
        try self.ingestModuleJson(result.stdout);
    }

    /// Stream one `ansible-doc --json` document into the library. The
    /// document is validated and parsed into a staging arena outside the lock.
    fn ingestModuleJson(self: *DocsLibrary, stdout: []const u8) !void {
        if (!docs_json.validate(self.allocator, stdout)) return;
        var stage = std.heap.ArenaAllocator.init(self.allocator);
        defer stage.deinit();
        var modules = std.ArrayList(Module).empty;
        defer modules.deinit(self.allocator);
        {
            var parser = docs_json.Parser.init(stage.allocator(), self.allocator, stdout);
            defer parser.deinit();
            parser.moduleMap(&modules) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
        }
        const add_count = std.math.cast(u32, modules.items.len) orelse return error.OutOfMemory;
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.modules.ensureUnusedCapacity(add_count);
        try self.extra_arenas.ensureUnusedCapacity(self.allocator, 1);
        self.adoptArenaAssumeCapacity(&stage);
        for (modules.items) |m| self.modules.putAssumeCapacity(m.name, m);
    }
};

fn writeCacheOption(jw: *std.json.Stringify, o: Option) std.Io.Writer.Error!void {
    try jw.beginObject();
    try jw.objectField("description");
    try jw.write(o.description);
    try jw.objectField("type");
    try jw.write(o.type);
    try jw.objectField("required");
    try jw.write(o.required);
    try jw.objectField("default");
    try jw.write(o.default);
    try jw.objectField("elements");
    try jw.write(o.elements);
    if (o.suboptions.len > 0) {
        try jw.objectField("suboptions");
        try jw.beginObject();
        for (o.suboptions) |s| {
            try jw.objectField(s.name);
            try writeCacheOption(jw, s);
        }
        try jw.endObject();
    }
    try jw.endObject();
}

test "loadMetadataDump ingests every module from one call" {
    const Fake = struct {
        argv0: []const u8 = "ansible-doc",
        stdout: []const u8,
        exit: u8 = 0,

        fn run(ptr: *anyopaque, a: Allocator, argv: []const []const u8) anyerror!exec.Result {
            return runWithOptions(ptr, a, argv, .{});
        }
        fn runWithOptions(ptr: *anyopaque, a: Allocator, _: []const []const u8, _: exec.Options) anyerror!exec.Result {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return .{
                .stdout = try a.dupe(u8, self.stdout),
                .stderr = try a.dupe(u8, ""),
                .term = .{ .exited = self.exit },
            };
        }
        const vtable = exec.Runner.VTable{ .run = run, .run_with_options = runWithOptions };
    };
    const dump =
        \\{"all": {"module": {
        \\  "ns.one": {"doc": {"short_description": "First", "filename": "/x/one.py",
        \\      "options": {"path": {"description": "A path", "type": "str", "required": true}}}},
        \\  "ns.two": {"doc": {"short_description": "Second", "filename": "/x/two.py"}}
        \\}}}
    ;
    var fake = Fake{ .stdout = dump };
    var lib = DocsLibrary.init(std.testing.allocator, .{ .ptr = &fake, .vtable = &Fake.vtable }, "ansible-doc");
    defer lib.deinit();
    try std.testing.expect(lib.loadMetadataDump());

    const one = lib.modules.get("ns.one").?;
    try std.testing.expectEqualStrings("First", one.description);
    try std.testing.expectEqualStrings("/x/one.py", one.filename);
    const opt = one.getOption("path") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("A path", opt.description);
    try std.testing.expect(opt.required);
    try std.testing.expect(lib.modules.get("ns.two") != null);

    var failed = Fake{ .stdout = "boom", .exit = 2 };
    var lib2 = DocsLibrary.init(std.testing.allocator, .{ .ptr = &failed, .vtable = &Fake.vtable }, "ansible-doc");
    defer lib2.deinit();
    try std.testing.expect(!lib2.loadMetadataDump());
    var no_modules = Fake{ .stdout = "{\"all\": {}}" };
    var lib3 = DocsLibrary.init(std.testing.allocator, .{ .ptr = &no_modules, .vtable = &Fake.vtable }, "ansible-doc");
    defer lib3.deinit();
    try std.testing.expect(!lib3.loadMetadataDump());
}

test "restoreCache rejects duplicate keys and stays atomic on OOM" {
    const runner = exec.Posix.posixRunner();
    var lib = DocsLibrary.init(std.testing.allocator, runner, "ansible-doc");
    defer lib.deinit();

    const dup = "{\"version\": 3, \"version\": 4, \"complete\": true, \"catalog\": {\"ns.a\": \"d\"}}";
    try std.testing.expect(!(try lib.restoreCache(std.testing.allocator, dup)));
    try std.testing.expect(!lib.ready);
    try std.testing.expect(!lib.cacheComplete());
    try std.testing.expectEqual(@as(usize, 0), lib.catalogCount());

    const valid =
        \\{"version": 3, "ansible_version": "ansible [core 2.18]", "complete": true,
        \\ "catalog": {"ns.one": "desc"},
        \\ "modules": {"ns.one": {"description": "one", "filename": "/x/one.py",
        \\   "options": {"path": {"description": "p", "type": "str", "required": true}}}}}
    ;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var oom_lib = DocsLibrary.init(failing.allocator(), runner, "ansible-doc");
        defer oom_lib.deinit();
        if (oom_lib.restoreCache(std.testing.allocator, valid)) |ok| {
            if (ok) {
                try std.testing.expect(oom_lib.ready);
                try std.testing.expect(oom_lib.cacheComplete());
                try std.testing.expectEqual(@as(usize, 1), oom_lib.catalogCount());
                try std.testing.expect(oom_lib.modules.get("ns.one") != null);
                break;
            }
            try std.testing.expect(!oom_lib.ready);
            try std.testing.expect(!oom_lib.cacheComplete());
            try std.testing.expectEqual(@as(usize, 0), oom_lib.catalogCount());
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(!oom_lib.ready);
            try std.testing.expect(!oom_lib.cacheComplete());
            try std.testing.expectEqual(@as(usize, 0), oom_lib.catalogCount());
            try std.testing.expectEqual(@as(usize, 0), oom_lib.modules.count());
            try std.testing.expectEqualStrings("", oom_lib.ansible_version);
        }
    }
}

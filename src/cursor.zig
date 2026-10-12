//! Cursor classification.
//!
//! Given a document and a byte offset, returns what is under the cursor:
//! a play, block, role, or task keyword; a module; a module option; a role
//! reference; or a variable occurrence. Hover, completion, and semantic
//! tokens format that kind. They do not repeat the keyword cascade.
//!
//! Names and ranges borrow from the forest (and from the docs lookup's
//! storage). They stay valid until `Doc.deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("yaml/root.zig");
const docs = @import("services/docs.zig");
const reference = @import("roles/reference.zig");
const variables = @import("variables/index.zig");
const paths = @import("paths.zig");

pub const Keyword = struct {
    name: []const u8,
    /// True when `name` is in the keyword set for this context.
    known: bool,
    start: usize,
    end: usize,
};

pub const Task = struct {
    name: []const u8,
    known: bool,
    start: usize,
    end: usize,
    /// A sibling key already names a module (`hasModuleName`, not a fetch).
    has_module: bool,
    /// `isPlayParam` was uncertain, so completion also offers play keywords.
    offer_play_keywords: bool,
};

pub const ModuleAt = struct {
    name: []const u8,
    module: docs.Module,
    start: usize,
    end: usize,
    has_module: bool,
    offer_play_keywords: bool,
};

pub const OptionAt = struct {
    name: []const u8,
    module: docs.Module,
    /// Schema match at this depth. Semantic tokens use it for `method`.
    option: ?docs.Option,
    /// Completion lists `module.options`, skipping `provided`.
    list_options: bool,
    provided: []const []const u8,
    start: usize,
    end: usize,
};

pub const RoleAt = struct {
    name: []const u8,
    start: usize,
    end: usize,
};

pub const VariableAt = struct {
    name: []const u8,
    kind: variables.OccurrenceKind,
    start: usize,
    end: usize,
};

pub const Cursor = union(enum) {
    play_keyword: Keyword,
    block_keyword: Keyword,
    role_keyword: Keyword,
    task_keyword: Task,
    module: ModuleAt,
    module_option: OptionAt,
    role_reference: RoleAt,
    variable: VariableAt,
};

/// Docs resolution injected into classification. Production wraps
/// `DocsLibrary`; tests pass an in-memory list.
pub const Docs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        find_in_context: *const fn (ptr: *anyopaque, arena: Allocator, name: []const u8, collections: []const []const u8) ?docs.Module,
        has_name: *const fn (ptr: *anyopaque, name: []const u8) bool,
        write_fqcns: *const fn (ptr: *anyopaque, out: *std.array_list.Managed([]const u8)) anyerror!void,
    };

    pub fn findInContext(self: Docs, arena: Allocator, name: []const u8, collections: []const []const u8) ?docs.Module {
        return self.vtable.find_in_context(self.ptr, arena, name, collections);
    }

    pub fn hasName(self: Docs, name: []const u8) bool {
        return self.vtable.has_name(self.ptr, name);
    }

    pub fn writeFqcns(self: Docs, out: *std.array_list.Managed([]const u8)) !void {
        return self.vtable.write_fqcns(self.ptr, out);
    }
};

pub fn fromLibrary(lib: *docs.DocsLibrary) Docs {
    return .{ .ptr = lib, .vtable = &library_vtable };
}

pub fn emptyDocs() Docs {
    return .{ .ptr = @constCast(&empty_byte), .vtable = &empty_vtable };
}

pub const Doc = struct {
    forest: yaml.Forest,

    pub fn open(allocator: Allocator, text: []const u8) !Doc {
        return .{ .forest = try yaml.parse(allocator, text) };
    }

    pub fn deinit(self: *Doc) void {
        self.forest.deinit();
    }

    /// Classify the node under `offset`.
    pub fn at(self: *Doc, uri: []const u8, offset: usize, lookup: Docs) !?Cursor {
        const arena = self.forest.allocator();
        var found: []*yaml.Node = &.{};
        for (self.forest.roots) |root| {
            if (yaml.getPathAt(arena, root, offset, true) catch null) |p| {
                found = p;
                break;
            }
        }
        return classify(&self.forest, uri, found, offset, lookup);
    }

    /// Classify `node` from its parent chain. Semantic tokens use this so
    /// each key is visited once.
    pub fn atNode(self: *Doc, uri: []const u8, node: *yaml.Node, lookup: Docs) !?Cursor {
        const path = try ancestors(self.forest.allocator(), node);
        return classify(&self.forest, uri, path, node.start, lookup);
    }
};

pub fn classify(
    forest: *yaml.Forest,
    uri: []const u8,
    path: []*yaml.Node,
    offset: usize,
    lookup: Docs,
) !?Cursor {
    if (structural(forest.allocator(), path, uri, lookup)) |cur| return cur;
    if (reference.detect(path, forest.text)) |ref| {
        return .{ .role_reference = .{ .name = ref.name, .start = ref.start, .end = ref.end } };
    }
    const fs_path = paths.uriToPath(forest.allocator(), uri) catch return null;
    if (try variables.Index.occurrenceInForest(forest.allocator(), forest, fs_path, offset)) |occ| {
        return .{ .variable = .{
            .name = occ.name,
            .kind = occ.kind,
            .start = occ.start,
            .end = occ.end,
        } };
    }
    return null;
}

const Key = struct { name: []const u8, start: usize, end: usize };

fn keyOf(path: []*yaml.Node) Key {
    if (path.len == 0) return .{ .name = "", .start = 0, .end = 0 };
    const n = path[path.len - 1];
    return .{
        .name = n.stringValue() orelse "",
        .start = n.start,
        .end = n.end,
    };
}

fn structural(arena: Allocator, path: []*yaml.Node, uri: []const u8, lookup: Docs) ?Cursor {
    if (path.len == 0) return null;
    const key = keyOf(path);

    if (yaml.predicates.isPlayParam(arena, path, uri) orelse false) {
        return .{ .play_keyword = keyword(key, yaml.keywords.isPlayKeyword(key.name)) };
    }
    if (yaml.predicates.isBlockParam(arena, path)) {
        return .{ .block_keyword = keyword(key, yaml.keywords.isBlockKeyword(key.name)) };
    }
    if (yaml.predicates.isRoleParam(arena, path)) {
        return .{ .role_keyword = keyword(key, yaml.keywords.isRoleKeyword(key.name)) };
    }
    if (yaml.predicates.isTaskParam(arena, path)) {
        const has_module = taskHasModule(arena, path, lookup);
        const offer = yaml.predicates.isPlayParam(arena, path, uri) == null;
        if (yaml.keywords.isTaskKeyword(key.name)) {
            return .{ .task_keyword = .{
                .name = key.name,
                .known = true,
                .start = key.start,
                .end = key.end,
                .has_module = has_module,
                .offer_play_keywords = offer,
            } };
        }
        const collections = yaml.collections.getDeclaredCollections(arena, path) catch &.{};
        if (lookup.findInContext(arena, key.name, collections)) |mod| {
            return .{ .module = .{
                .name = key.name,
                .module = mod,
                .start = key.start,
                .end = key.end,
                .has_module = has_module,
                .offer_play_keywords = offer,
            } };
        }
        return .{ .task_keyword = .{
            .name = key.name,
            .known = false,
            .start = key.start,
            .end = key.end,
            .has_module = has_module,
            .offer_play_keywords = offer,
        } };
    }
    return optionAt(arena, path, key, lookup);
}

fn keyword(key: Key, known: bool) Keyword {
    return .{ .name = key.name, .known = known, .start = key.start, .end = key.end };
}

fn taskHasModule(arena: Allocator, path: []*yaml.Node, lookup: Docs) bool {
    const names = yaml.options.providedModuleNames(arena, path) catch return false;
    for (names) |n| {
        if (lookup.hasName(n)) return true;
        const builtin = std.fmt.allocPrint(arena, "ansible.builtin.{s}", .{n}) catch continue;
        if (lookup.hasName(builtin)) return true;
    }
    return false;
}

fn optionAt(arena: Allocator, path: []*yaml.Node, key: Key, lookup: Docs) ?Cursor {
    const traced = (yaml.options.getTaskParamPathWithTrace(arena, path) catch null) orelse return null;
    if (traced.trace.len == 0) return null;
    const module = moduleForTrace(arena, traced, lookup) orelse return null;
    const list_options = traced.trace[traced.trace.len - 1].kind == .dict;
    const option = schemaOption(module, traced.trace, key.name);
    if (!list_options and option == null) return null;
    return .{ .module_option = .{
        .name = key.name,
        .module = module,
        .option = option,
        .list_options = list_options,
        .provided = yaml.options.providedKeys(arena, path) catch &.{},
        .start = key.start,
        .end = key.end,
    } };
}

fn moduleForTrace(arena: Allocator, traced: yaml.options.TaskParamTrace, lookup: Docs) ?docs.Module {
    const collections = yaml.collections.getDeclaredCollections(arena, traced.path) catch &.{};
    const module_key = keyOf(traced.path).name;
    if (module_key.len == 0) return null;
    if (std.mem.eql(u8, module_key, "args")) {
        const names = yaml.options.providedModuleNames(arena, traced.path) catch return null;
        for (names) |n| {
            if (lookup.findInContext(arena, n, collections)) |m| return m;
        }
        return null;
    }
    return lookup.findInContext(arena, module_key, collections);
}

/// Match `name` against module options, descending `trace` from the module
/// key down to the nearest parent. `trace` is stored nearest-first.
fn schemaOption(module: docs.Module, trace: []const yaml.options.TraceStep, name: []const u8) ?docs.Option {
    if (trace.len == 0) return null;
    const containers = trace[0 .. trace.len - 1];
    var subs: ?[]const docs.Option = null;
    var idx = containers.len;
    while (idx > 0) {
        idx -= 1;
        const step = containers[idx];
        const parent = if (subs) |s| findOpt(s, step.name) else module.options.get(step.name);
        const p = parent orelse return null;
        if (!containerHolds(p, step.kind)) return null;
        subs = p.suboptions;
    }
    if (subs) |s| return findOpt(s, name);
    return module.options.get(name);
}

fn containerHolds(opt: docs.Option, kind: yaml.options.TraceKind) bool {
    const want = switch (kind) {
        .dict => "dict",
        .list => "list",
    };
    return std.mem.eql(u8, opt.type, want);
}

fn findOpt(subs: []const docs.Option, name: []const u8) ?docs.Option {
    for (subs) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

fn ancestors(arena: Allocator, node: *yaml.Node) ![]*yaml.Node {
    var buf = std.array_list.Managed(*yaml.Node).init(arena);
    var n: ?*yaml.Node = node;
    while (n) |cur| {
        try buf.append(cur);
        n = cur.parent;
    }
    std.mem.reverse(*yaml.Node, buf.items);
    return buf.toOwnedSlice();
}

fn libFind(ptr: *anyopaque, arena: Allocator, name: []const u8, collections: []const []const u8) ?docs.Module {
    const lib: *docs.DocsLibrary = @ptrCast(@alignCast(ptr));
    return lib.findModuleInContext(arena, name, collections);
}

fn libHas(ptr: *anyopaque, name: []const u8) bool {
    const lib: *docs.DocsLibrary = @ptrCast(@alignCast(ptr));
    return lib.hasModuleName(name);
}

fn libFqcns(ptr: *anyopaque, out: *std.array_list.Managed([]const u8)) !void {
    const lib: *docs.DocsLibrary = @ptrCast(@alignCast(ptr));
    try lib.writeModuleFqcns(out);
}

const library_vtable = Docs.VTable{
    .find_in_context = libFind,
    .has_name = libHas,
    .write_fqcns = libFqcns,
};

fn emptyFind(_: *anyopaque, _: Allocator, _: []const u8, _: []const []const u8) ?docs.Module {
    return null;
}
fn emptyHas(_: *anyopaque, _: []const u8) bool {
    return false;
}
fn emptyFqcns(_: *anyopaque, _: *std.array_list.Managed([]const u8)) !void {}

const empty_byte: u8 = 0;
const empty_vtable = Docs.VTable{
    .find_in_context = emptyFind,
    .has_name = emptyHas,
    .write_fqcns = emptyFqcns,
};

const testing = std.testing;

const Fake = struct {
    modules: []const docs.Module,
    names: []const []const u8,
    fqcns: []const []const u8,

    fn lookup(self: *Fake) Docs {
        return .{ .ptr = self, .vtable = &fake_vtable };
    }
};

fn fakeFind(ptr: *anyopaque, _: Allocator, name: []const u8, _: []const []const u8) ?docs.Module {
    const fake: *Fake = @ptrCast(@alignCast(ptr));
    for (fake.modules) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}
fn fakeHas(ptr: *anyopaque, name: []const u8) bool {
    const fake: *Fake = @ptrCast(@alignCast(ptr));
    for (fake.names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}
fn fakeFqcns(ptr: *anyopaque, out: *std.array_list.Managed([]const u8)) !void {
    const fake: *Fake = @ptrCast(@alignCast(ptr));
    try out.appendSlice(fake.fqcns);
}

const fake_vtable = Docs.VTable{
    .find_in_context = fakeFind,
    .has_name = fakeHas,
    .write_fqcns = fakeFqcns,
};

fn pingModule(a: Allocator) !docs.Module {
    var options = std.StringHashMap(docs.Option).init(a);
    try options.put("data", .{
        .name = "data",
        .description = "payload",
        .type = "str",
    });
    return .{
        .name = "ping",
        .description = "probe the host",
        .filename = "/ping.py",
        .options = options,
    };
}

test "hosts is a play keyword" {
    const src =
        \\- hosts: all
        \\
    ;
    var opened = try Doc.open(testing.allocator, src);
    defer opened.deinit();
    const off = std.mem.indexOf(u8, src, "hosts").?;
    const cur = (try opened.at("file:///play.yml", off, emptyDocs())).?;
    switch (cur) {
        .play_keyword => |k| {
            try testing.expectEqualStrings("hosts", k.name);
            try testing.expect(k.known);
        },
        else => try testing.expect(false),
    }
}

test "ping is a module and data is a module option" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{
        .modules = &.{try pingModule(a)},
        .names = &.{ "ping", "ansible.builtin.ping" },
        .fqcns = &.{"ansible.builtin.ping"},
    };
    const src =
        \\- ping:
        \\    data: 1
        \\
    ;
    var opened = try Doc.open(testing.allocator, src);
    defer opened.deinit();
    const ping_off = std.mem.indexOf(u8, src, "ping").?;
    const ping = (try opened.at("file:///play.yml", ping_off, fake.lookup())).?;
    switch (ping) {
        .module => |m| {
            try testing.expectEqualStrings("ping", m.name);
            try testing.expect(m.has_module);
        },
        else => try testing.expect(false),
    }

    const data_off = std.mem.indexOf(u8, src, "data").?;
    const data = (try opened.at("file:///play.yml", data_off, fake.lookup())).?;
    switch (data) {
        .module_option => |o| {
            try testing.expectEqualStrings("data", o.name);
            try testing.expect(o.option != null);
            try testing.expect(o.list_options);
        },
        else => try testing.expect(false),
    }
}

test "role name is a role reference" {
    const src =
        \\- hosts: all
        \\  roles:
        \\    - demo
        \\
    ;
    var opened = try Doc.open(testing.allocator, src);
    defer opened.deinit();
    const off = std.mem.indexOf(u8, src, "demo").?;
    const cur = (try opened.at("file:///play.yml", off, emptyDocs())).?;
    switch (cur) {
        .role_reference => |r| try testing.expectEqualStrings("demo", r.name),
        else => try testing.expect(false),
    }
}

test "jinja ident is a variable occurrence" {
    const src =
        \\- debug:
        \\    msg: "{{ app_name }}"
        \\
    ;
    var opened = try Doc.open(testing.allocator, src);
    defer opened.deinit();
    const off = std.mem.indexOf(u8, src, "app_name").?;
    const cur = (try opened.at("file:///play.yml", off, emptyDocs())).?;
    switch (cur) {
        .variable => |v| {
            try testing.expectEqualStrings("app_name", v.name);
            try testing.expectEqual(variables.OccurrenceKind.reference, v.kind);
            try testing.expectEqual(off, v.start);
        },
        else => try testing.expect(false),
    }
}

test "nested dict key is that suboption" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const subs = [_]docs.Option{.{
        .name = "child",
        .description = "inner",
        .type = "str",
    }};
    var options = std.StringHashMap(docs.Option).init(a);
    try options.put("complex", .{
        .name = "complex",
        .description = "group",
        .type = "dict",
        .suboptions = &subs,
    });
    var fake = Fake{
        .modules = &.{.{
            .name = "ping",
            .description = "probe",
            .filename = "/ping.py",
            .options = options,
        }},
        .names = &.{"ping"},
        .fqcns = &.{},
    };
    const src =
        \\- ping:
        \\    complex:
        \\      child: 1
        \\
    ;
    var opened = try Doc.open(testing.allocator, src);
    defer opened.deinit();
    const off = std.mem.indexOf(u8, src, "child").?;
    const cur = (try opened.at("file:///play.yml", off, fake.lookup())).?;
    switch (cur) {
        .module_option => |o| {
            const opt = o.option orelse return error.MissingOption;
            try testing.expectEqualStrings("child", opt.name);
        },
        else => try testing.expect(false),
    }
}

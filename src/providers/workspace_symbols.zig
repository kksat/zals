//! `workspace/symbol` (ADR-0032, ADR-0038): Workspace symbols matching
//! the query, each with its nearest parent by file location as
//! `containerName`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const types = @import("../lsp/types.zig");
const encode = @import("../lsp/encode.zig");
const resolve = @import("../roles/resolve.zig");
const symbols = @import("../workspace/symbols.zig");
const context_mod = @import("../queries/context.zig");
const Context = context_mod.Context;
const FileSet = context_mod.FileSet;
const Known = context_mod.WorkspaceCollection;

const max_results = 1000;

pub const Info = struct {
    name: []const u8,
    kind: types.SymbolKind,
    uri: []const u8,
    start: usize = 0,
    end: usize = 0,
    /// File-level symbols point at the start of the file.
    whole_file: bool = false,
    container: []const u8 = "",
};

pub fn workspaceSymbol(context: *Context, params: Value) !Value {
    const a = context.allocator;
    const query = json_util.string(params, "query") orelse "";
    var arr = std.json.Array.init(a);
    for (context.roots()) |root| {
        const v = try context.files(.{ .workspace = root });
        for (try collect(context, v, query)) |info| {
            if (arr.items.len >= max_results) break;
            try arr.append(try toValue(context, info));
        }
    }
    return .{ .array = arr };
}

/// Workspace symbols matching a name or collection-qualified member query.
pub fn collect(context: *Context, v: *FileSet, query: []const u8) ![]const Info {
    const a = context.allocator;
    const root = v.root.?;
    var out = std.array_list.Managed(Info).init(a);
    const colls = try context.workspaceCollections(v);

    for (colls) |c| {
        if (!symbols.matches(c.name, query)) continue;
        try out.append(.{ .name = c.name, .kind = .package, .uri = c.metadata_uri, .whole_file = true });
    }

    // Collection module/plugin source files are symbols, not YAML facts.
    for (v.files) |f| {
        const c = collectionAt(colls, f.path) orelse continue;
        const name = (try sourceMemberName(a, f.path[c.dir.len + 1 ..])) orelse continue;
        if (!try memberMatches(a, name, c.name, query)) continue;
        try out.append(.{ .name = name, .kind = .module, .uri = f.uri, .whole_file = true, .container = c.name });
    }

    // Roles prefer their main task source, accepting both YAML extensions.
    const RoleTarget = struct { uri: []const u8, priority: u8 };
    var role_targets = std.StringArrayHashMap(RoleTarget).init(a);
    for (v.files) |f| {
        const dir = resolve.enclosingRole(f.path) orelse continue;
        const role_path = f.path[dir.len..];
        const priority: u8 = if (std.mem.eql(u8, role_path, "/tasks/main.yml")) 2 else if (std.mem.eql(u8, role_path, "/tasks/main.yaml")) 1 else 0;
        const gop = try role_targets.getOrPut(dir);
        if (!gop.found_existing or priority > gop.value_ptr.priority) gop.value_ptr.* = .{ .uri = f.uri, .priority = priority };
    }
    var rit = role_targets.iterator();
    while (rit.next()) |e| {
        const name = std.fs.path.basename(e.key_ptr.*);
        const container = collectionOf(colls, e.key_ptr.*) orelse "";
        if (!try memberMatches(a, name, container, query)) continue;
        try out.append(.{
            .name = name,
            .kind = .module,
            .uri = e.value_ptr.uri,
            .whole_file = true,
            .container = container,
        });
    }

    for (v.files) |f| {
        const role_dir = resolve.enclosingRole(f.path);
        switch (f.facts.shape) {
            .playbook => {
                const name = relative(root, f.path);
                if (symbols.matches(name, query)) try out.append(.{
                    .name = name,
                    .kind = .file,
                    .uri = f.uri,
                    .whole_file = true,
                    .container = collectionOf(colls, f.path) orelse "",
                });
            },
            .task_file => {
                const name = std.fs.path.basename(f.path);
                const container = if (role_dir) |rd| std.fs.path.basename(rd) else relative(root, std.fs.path.dirname(f.path) orelse root);
                if (symbols.matches(name, query)) try out.append(.{
                    .name = name,
                    .kind = .file,
                    .uri = f.uri,
                    .whole_file = true,
                    .container = if (std.mem.eql(u8, container, root)) "" else container,
                });
            },
            .other => {},
        }
        for (f.facts.symbols) |s| {
            if (!symbols.matches(s.name, query)) continue;
            const container = switch (s.kind) {
                .play => relative(root, f.path),
                .task, .handler => if (s.play.len > 0) s.play else if (role_dir) |rd|
                    try std.fmt.allocPrint(a, "{s}/{s}", .{ std.fs.path.basename(rd), f.path[rd.len + 1 ..] })
                else
                    relative(root, f.path),
            };
            try out.append(.{
                .name = s.name,
                .kind = switch (s.kind) {
                    .play => .namespace,
                    .task => .function,
                    .handler => .event,
                },
                .uri = f.uri,
                .start = s.start,
                .end = s.end,
                .container = container,
            });
        }
    }
    return out.toOwnedSlice();
}

/// One symbol per module/plugin source, not per Python function or export.
fn sourceMemberName(a: Allocator, relative_path: []const u8) !?[]const u8 {
    const prefix = "plugins/";
    if (!std.mem.startsWith(u8, relative_path, prefix)) return null;
    const extension_len: usize = if (std.mem.endsWith(u8, relative_path, ".py")) 3 else if (std.mem.endsWith(u8, relative_path, ".ps1")) 4 else return null;
    const source = relative_path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, source, '/') orelse return null;
    const plugin_type = source[0..slash];
    if (extension_len == 4 and !std.mem.eql(u8, plugin_type, "modules")) return null;
    const public_types = [_][]const u8{
        "modules",  "action",  "become",    "cache",  "callback", "cliconf", "connection",
        "filter",   "httpapi", "inventory", "lookup", "netconf",  "shell",   "strategy",
        "terminal", "test",    "vars",
    };
    for (public_types) |kind| {
        if (!std.mem.eql(u8, plugin_type, kind)) continue;
        const name = source[slash + 1 .. source.len - extension_len];
        var parts = std.mem.splitScalar(u8, name, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or part[0] == '_' or part[0] == '.') return null;
        }
        const dotted = try a.dupe(u8, name);
        for (dotted) |*char| if (char.* == '/') {
            char.* = '.';
        };
        return dotted;
    }
    return null;
}

/// Keep member names short; search also accepts the collection-qualified name.
fn memberMatches(a: Allocator, name: []const u8, container: []const u8, query: []const u8) !bool {
    if (symbols.matches(name, query)) return true;
    if (container.len == 0) return false;
    return symbols.matches(try std.fmt.allocPrint(a, "{s}.{s}", .{ container, name }), query);
}

/// FQCN of the Workspace collection that contains `path`, if any.
fn collectionOf(colls: []const Known, path: []const u8) ?[]const u8 {
    return if (collectionAt(colls, path)) |c| c.name else null;
}

fn collectionAt(colls: []const Known, path: []const u8) ?Known {
    var best: ?Known = null;
    for (colls) |c| {
        if (path.len <= c.dir.len or !std.mem.startsWith(u8, path, c.dir) or path[c.dir.len] != '/') continue;
        if (best == null or c.dir.len > best.?.dir.len) best = c;
    }
    return best;
}

fn relative(root: []const u8, path: []const u8) []const u8 {
    if (path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and path[root.len] == '/') return path[root.len + 1 ..];
    return path;
}

fn toValue(context: *Context, info: Info) !Value {
    const a = context.allocator;
    const loc: types.Location = if (info.whole_file)
        .{ .uri = info.uri, .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } } }
    else
        try context.location(info.uri, info.start, info.end);
    var obj = json_util.obj(a);
    try obj.put("name", json_util.str(info.name));
    try obj.put("kind", json_util.num(@intFromEnum(info.kind)));
    try obj.put("location", try encode.location(a, loc));
    if (info.container.len > 0) try obj.put("containerName", json_util.str(info.container));
    return .{ .object = obj };
}

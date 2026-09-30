//! Task-file and vars-file references (ADR-0032).
//!
//! A file reference is the path value of `include_tasks`/`import_tasks`
//! (scalar, `file=...`, or `file:`), a `vars_files` entry, or an
//! `include_vars` path (scalar or `file:`). Jinja-valued paths are skipped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/root.zig");
const Node = yaml.Node;
const resolve = @import("../roles/resolve.zig");

pub const Kind = enum { task_file, vars_file };

pub const FileRef = struct {
    kind: Kind,
    /// The path as written.
    raw: []const u8,
    /// Absolute path it resolves to (see `resolveTarget`).
    target: []const u8,
    start: usize,
    end: usize,
};

/// Every file reference in `forest`, resolved from `path` within `root`.
pub fn collect(a: Allocator, forest: *const yaml.Forest, path: []const u8, root: ?[]const u8) ![]FileRef {
    var out = std.array_list.Managed(FileRef).init(a);
    var ctx = Ctx{ .a = a, .text = forest.text, .path = path, .root = root, .out = &out };
    for (forest.roots) |r| try ctx.walk(r);
    return out.toOwnedSlice();
}

/// Resolve `raw` as written in the file at `path`: against that file's
/// directory, then the enclosing role's `tasks/` (task files) or `vars/`
/// (vars files), then the Workspace root. The first that exists wins; when
/// none exists, the first candidate is returned.
pub fn resolveTarget(a: Allocator, kind: Kind, raw: []const u8, path: []const u8, root: ?[]const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(raw)) return a.dupe(u8, raw);
    const dir = std.fs.path.dirname(path) orelse ".";
    const first = try std.fs.path.resolve(a, &.{ dir, raw });
    if (isFile(first)) return first;
    if (resolve.enclosingRole(path)) |role_dir| {
        const sub = if (kind == .task_file) "tasks" else "vars";
        const in_role = try std.fs.path.resolve(a, &.{ role_dir, sub, raw });
        if (isFile(in_role)) return in_role;
    }
    if (root) |r| {
        const at_root = try std.fs.path.resolve(a, &.{ r, raw });
        if (isFile(at_root)) return at_root;
    }
    return first;
}

const Ctx = struct {
    a: Allocator,
    text: []const u8,
    path: []const u8,
    root: ?[]const u8,
    out: *std.array_list.Managed(FileRef),

    fn walk(self: *Ctx, node: *const Node) !void {
        switch (node.kind) {
            .map => for (node.items) |pair| {
                const key = if (pair.key) |k| k.stringValue() orelse "" else "";
                const val = pair.val orelse continue;
                if (isModuleKey(key, "include_tasks") or isModuleKey(key, "import_tasks")) {
                    try self.pathArg(.task_file, val);
                } else if (isModuleKey(key, "include_vars")) {
                    try self.pathArg(.vars_file, val);
                } else if (std.mem.eql(u8, key, "vars_files")) {
                    if (val.isSeq()) {
                        for (val.items) |item| if (item.isScalar()) try self.add(.vars_file, item, null);
                    } else if (val.isScalar()) {
                        try self.add(.vars_file, val, null);
                    }
                }
                try self.walk(val);
            },
            .seq => for (node.items) |item| try self.walk(item),
            else => {},
        }
    }

    /// A module argument naming a file: `x.yml`, `file=x.yml`, or `{file: x.yml}`.
    fn pathArg(self: *Ctx, kind: Kind, val: *const Node) !void {
        if (val.isMap()) {
            const p = yaml.dom.findPair(val, "file") orelse return;
            const v = p.val orelse return;
            if (v.isScalar()) try self.add(kind, v, null);
            return;
        }
        if (!val.isScalar()) return;
        const s = val.stringValue() orelse return;
        if (std.mem.indexOf(u8, s, "file=")) |i| {
            const rest = s[i + "file=".len ..];
            const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            try self.add(kind, val, std.mem.trim(u8, rest[0..end], "\"'"));
            return;
        }
        if (std.mem.indexOfScalar(u8, s, '=') != null) return;
        try self.add(kind, val, null);
    }

    fn add(self: *Ctx, kind: Kind, node: *const Node, override: ?[]const u8) !void {
        const value = override orelse (node.stringValue() orelse return);
        if (value.len == 0 or isJinja(value)) return;
        if (node.end > self.text.len or node.start > node.end) return;
        const raw_text = self.text[node.start..node.end];
        const off = std.mem.indexOf(u8, raw_text, value) orelse return;
        try self.out.append(.{
            .kind = kind,
            .raw = try self.a.dupe(u8, value),
            .target = try resolveTarget(self.a, kind, value, self.path, self.root),
            .start = node.start + off,
            .end = node.start + off + value.len,
        });
    }
};

fn isModuleKey(key: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, key, name)) return true;
    return key.len > name.len + 1 and key[key.len - name.len - 1] == '.' and std.mem.endsWith(u8, key, name);
}

fn isJinja(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "{{") != null or std.mem.indexOf(u8, s, "{%") != null;
}

fn isFile(path: []const u8) bool {
    const f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

const testing = std.testing;

test "collects task and vars file references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\- hosts: all
        \\  vars_files:
        \\    - vars/prod.yml
        \\    - "{{ env }}.yml"
        \\  tasks:
        \\    - import_tasks: tasks/common.yml
        \\    - ansible.builtin.include_tasks:
        \\        file: tasks/other.yml
        \\    - include_tasks: file=tasks/kv.yml
        \\    - include_vars: vars/extra.yml
        \\
    ;
    var forest = try yaml.parse(a, text);
    defer forest.deinit();
    const refs = try collect(a, &forest, "/nowhere-zals/site.yml", null);
    try testing.expectEqual(@as(usize, 5), refs.len);
    try testing.expectEqual(Kind.vars_file, refs[0].kind);
    try testing.expectEqualStrings("/nowhere-zals/vars/prod.yml", refs[0].target);
    try testing.expectEqualStrings("vars/prod.yml", text[refs[0].start..refs[0].end]);
    try testing.expectEqual(Kind.task_file, refs[1].kind);
    try testing.expectEqualStrings("/nowhere-zals/tasks/common.yml", refs[1].target);
    try testing.expectEqualStrings("tasks/other.yml", refs[2].raw);
    try testing.expectEqualStrings("tasks/kv.yml", refs[3].raw);
    try testing.expectEqualStrings("tasks/kv.yml", text[refs[3].start..refs[3].end]);
    try testing.expectEqual(Kind.vars_file, refs[4].kind);
}

test "a role task file resolves into the role's tasks directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("roles/web/tasks");
    try tmp.dir.writeFile(.{ .sub_path = "roles/web/tasks/install.yml", .data = "" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const handlers = try std.fs.path.join(a, &.{ root, "roles", "web", "handlers", "main.yml" });
    const target = try resolveTarget(a, .task_file, "install.yml", handlers, root);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "roles", "web", "tasks", "install.yml" }), target);
}

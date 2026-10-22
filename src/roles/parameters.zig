//! Passed-role parameter detection and selected-entrypoint option contracts.
const std = @import("std");
const plays = @import("../yaml/plays.zig");
const Allocator = std.mem.Allocator;
const yaml = @import("../yaml/root.zig");
const variables = @import("../variables/root.zig");
const paths = @import("../paths.zig");

/// A Role parameter under the cursor: the key, the role it is passed to,
/// and the argument-spec entry point.
pub const Parameter = struct {
    name: []const u8,
    start: usize,
    end: usize,
    role: []const u8,
    entry_point: []const u8,
};

/// Detect a Role parameter key at `path`: a key of a play's `roles:` entry
/// (or of its `vars:`), or a key under `vars:` of an
/// `include_role`/`import_role` task.
pub fn parameterAt(path: []*yaml.Node) ?Parameter {
    if (path.len < 3) return null;
    const key = path[path.len - 1];
    const pair = path[path.len - 2];
    if (!key.isScalar() or !pair.isPair() or pair.key != key) return null;
    const name = key.stringValue() orelse return null;
    const map = path[path.len - 3];
    if (!map.isMap()) return null;

    // `- role: web` entry map.
    if (roleEntry(path, path.len - 3)) |entry| {
        if (std.mem.eql(u8, name, "role") or std.mem.eql(u8, name, "name")) return null;
        if (yaml.keywords.isRoleKeyword(name)) return null;
        return .{ .name = name, .start = key.start, .end = key.end, .role = entry, .entry_point = "main" };
    }

    // A `vars:` map: of a role entry, or of an include_role/import_role task.
    if (path.len < 5) return null;
    const vars_pair = path[path.len - 4];
    if (!vars_pair.isPair()) return null;
    const vk = vars_pair.key orelse return null;
    if (!std.mem.eql(u8, vk.stringValue() orelse "", "vars")) return null;
    const owner = path[path.len - 5];
    if (!owner.isMap()) return null;
    if (roleEntry(path, path.len - 5)) |entry| {
        return .{ .name = name, .start = key.start, .end = key.end, .role = entry, .entry_point = "main" };
    }
    for (owner.items) |p| {
        const k = (p.key orelse continue).stringValue() orelse continue;
        if (!plays.isAction(k, "include_role") and !plays.isAction(k, "import_role")) continue;
        const args = p.val orelse return null;
        const role = roleArg(args, "name") orelse return null;
        const tasks_from = roleArg(args, "tasks_from");
        return .{
            .name = name,
            .start = key.start,
            .end = key.end,
            .role = role,
            .entry_point = if (tasks_from) |t| stripExt(std.fs.path.basename(t)) else "main",
        };
    }
    return null;
}

/// The role name of a `roles:` entry map at `path[i]`, or null.
fn roleEntry(path: []*yaml.Node, i: usize) ?[]const u8 {
    if (i < 2) return null;
    const seq = path[i - 1];
    const roles_pair = path[i - 2];
    if (!seq.isSeq() or !roles_pair.isPair()) return null;
    const rk = roles_pair.key orelse return null;
    if (!std.mem.eql(u8, rk.stringValue() orelse "", "roles")) return null;
    const map = path[i];
    for ([_][]const u8{ "role", "name" }) |field| {
        if (yaml.dom.findPair(map, field)) |p| {
            if (p.val) |v| if (v.stringValue()) |s| return s;
        }
    }
    return null;
}

/// `field` of `include_role` args: map form or `k=v` form.
fn roleArg(args: *yaml.Node, field: []const u8) ?[]const u8 {
    if (args.isMap()) {
        const p = yaml.dom.findPair(args, field) orelse return null;
        const v = p.val orelse return null;
        return v.stringValue();
    }
    const raw = args.stringValue() orelse return null;
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |token| {
        if (token.len > field.len and std.mem.startsWith(u8, token, field) and token[field.len] == '=') {
            return std.mem.trim(u8, token[field.len + 1 ..], "\"'");
        }
    }
    return null;
}

pub const OptionSpec = struct { file: []const u8, yaml: []const u8, start: usize, end: usize };

/// The unrendered YAML of `argument_specs.<entry>.options.<name>` in the
/// role's `meta/argument_specs.*`, else `meta/main.*`.
pub fn optionSpec(a: Allocator, role_dir: []const u8, entry: []const u8, name: []const u8) !?OptionSpec {
    return optionSpecFrom(a, null, role_dir, entry, name);
}

fn optionSpecFrom(a: Allocator, source: ?variables.FileSource, role_dir: []const u8, entry: []const u8, name: []const u8) !?OptionSpec {
    return optionSpecPathFrom(a, source, role_dir, entry, &.{name});
}

/// A root option followed by nested `options:` keys at the selected entry point.
/// Source reads honor the server's open-buffer overlay when supplied.
pub fn optionSpecPathFrom(a: Allocator, source: ?variables.FileSource, role_dir: []const u8, entry: []const u8, names: []const []const u8) !?OptionSpec {
    if (names.len == 0) return null;
    for ([_][]const u8{ "argument_specs.yml", "argument_specs.yaml", "main.yml", "main.yaml" }) |file| {
        const text = if (source) |src| blk: {
            const path = try std.fs.path.join(a, &.{ role_dir, "meta", file });
            break :blk (try src.read(a, try paths.pathToUri(a, path))) orelse continue;
        } else readFile(a, &.{ role_dir, "meta", file }) orelse continue;
        var forest = yaml.parse(a, text) catch continue;
        defer forest.deinit();
        for (forest.roots) |root| {
            const pair = optionPairPath(root, entry, names) orelse continue;
            const key = pair.key orelse continue;
            const range = variables.definitions.scalarRange(key, forest.text, names[names.len - 1]);
            return .{
                .file = file,
                .yaml = try dedent(a, text, pair.start, pair.end),
                .start = range.start,
                .end = range.end,
            };
        }
    }
    return null;
}

fn optionPairPath(root: *yaml.Node, entry: []const u8, names: []const []const u8) ?*yaml.Node {
    if (!root.isMap()) return null;
    const specs = (yaml.dom.findPair(root, "argument_specs") orelse return null).val orelse return null;
    if (!specs.isMap()) return null;
    const ep = (yaml.dom.findPair(specs, entry) orelse return null).val orelse return null;
    if (!ep.isMap()) return null;
    const options = (yaml.dom.findPair(ep, "options") orelse return null).val orelse return null;
    if (!options.isMap()) return null;
    var pair = yaml.dom.findPair(options, names[0]) orelse return null;
    for (names[1..]) |name| {
        const value = pair.val orelse return null;
        if (!value.isMap()) return null;
        const nested = (yaml.dom.findPair(value, "options") orelse return null).val orelse return null;
        if (!nested.isMap()) return null;
        pair = yaml.dom.findPair(nested, name) orelse return null;
    }
    return pair;
}

/// `text[start..end]` with the start line's indentation removed from every
/// line, so the option reads as a standalone YAML block.
fn dedent(a: Allocator, text: []const u8, start: usize, end: usize) ![]const u8 {
    const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..start], '\n')) |i| i + 1 else 0;
    const indent = start - line_start;
    var out = std.array_list.Managed(u8).init(a);
    var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, text[line_start..@min(end, text.len)], " \t\r\n"), '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        var cut: usize = 0;
        while (cut < indent and cut < line.len and (line[cut] == ' ' or line[cut] == '\t')) : (cut += 1) {}
        try out.appendSlice(line[cut..]);
    }
    return out.toOwnedSlice();
}

fn stripExt(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| return name[0..dot];
    return name;
}

fn readFile(a: Allocator, parts: []const []const u8) ?[]const u8 {
    const p = std.fs.path.join(a, parts) catch return null;
    const f = std.fs.cwd().openFile(p, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(a, 256 * 1024) catch null;
}

const testing = std.testing;

fn parameterIn(src: []const u8, needle: []const u8) !?Parameter {
    var forest = try yaml.parse(testing.allocator, src);
    defer forest.deinit();
    const off = std.mem.indexOf(u8, src, needle) orelse return null;
    const p = (try yaml.getPathAt(forest.allocator(), forest.roots[0], off, true)) orelse return null;
    const found = parameterAt(p) orelse return null;
    // Copy out of the forest before it is freed.
    return .{
        .name = try testing.allocator.dupe(u8, found.name),
        .start = found.start,
        .end = found.end,
        .role = try testing.allocator.dupe(u8, found.role),
        .entry_point = try testing.allocator.dupe(u8, found.entry_point),
    };
}

fn freeParam(p: Parameter) void {
    testing.allocator.free(p.name);
    testing.allocator.free(p.role);
    testing.allocator.free(p.entry_point);
}

test "role parameter in a roles entry" {
    const p = (try parameterIn("- hosts: all\n  roles:\n    - role: web\n      app_port: 8080\n", "app_port")).?;
    defer freeParam(p);
    try testing.expectEqualStrings("app_port", p.name);
    try testing.expectEqualStrings("web", p.role);
    try testing.expectEqualStrings("main", p.entry_point);
}

test "role keyword in a roles entry is not a parameter" {
    try testing.expect((try parameterIn("- hosts: all\n  roles:\n    - role: web\n      when: x\n", "when")) == null);
    // `port` is the connection keyword, not a role parameter.
    try testing.expect((try parameterIn("- hosts: all\n  roles:\n    - role: web\n      port: 1\n", "port")) == null);
}

test "role parameter under include_role vars with tasks_from" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - ansible.builtin.include_role:
        \\        name: web
        \\        tasks_from: setup.yml
        \\      vars:
        \\        port: 8080
        \\
    ;
    const p = (try parameterIn(src, "port")).?;
    defer freeParam(p);
    try testing.expectEqualStrings("web", p.role);
    try testing.expectEqualStrings("setup", p.entry_point);
}

test "plain task vars are not role parameters" {
    const src = "- hosts: all\n  tasks:\n    - debug: msg=hi\n      vars:\n        port: 1\n";
    try testing.expect((try parameterIn(src, "port")) == null);
}

test "option spec is unrendered and dedented" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("web/meta");
    const specs =
        \\argument_specs:
        \\  main:
        \\    options:
        \\      port:
        \\        type: int
        \\        description: Listening port
        \\      host:
        \\        type: str
        \\
    ;
    try tmp.dir.writeFile(.{ .sub_path = "web/meta/argument_specs.yml", .data = specs });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realpathAlloc(a, "web");
    const spec = (try optionSpec(a, dir, "main", "port")).?;
    try testing.expectEqualStrings("port:\n  type: int\n  description: Listening port", spec.yaml);
    try testing.expect((try optionSpec(a, dir, "main", "missing")) == null);
}

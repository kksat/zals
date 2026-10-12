//! Hover on a variable: its active definition, the shadowed reachable ones,
//! and the other definitions in the Workspace (ADR-0032).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");
const variables = @import("../variables/root.zig");
const paths = @import("../paths.zig");
const wv = @import("workspace_view.zig");
const descriptions = @import("../queries/binding_descriptions.zig");
const Facts = @import("../workspace/facts.zig").Facts;

const max_listed = 20;
const max_value_lines = 12;

const navigation = @import("../queries/variable_navigation.zig");

pub fn hover(self: *Server, a: Allocator, params: Value) !?types.Hover {
    const loc = util.cursorAt(self, params) orelse return null;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return null;
    defer subject.deinit();
    return query.rootHover(&subject);
}

/// Compatibility entry point for a named root hover.
pub fn hoverName(self: *Server, a: Allocator, uri: []const u8, name: []const u8, range: types.Range) !?types.Hover {
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = uri, .offset = 0 }) orelse return null;
    defer subject.deinit();
    return try query.hoverName(&subject, name, range, .root);
}

pub const Entry = struct {
    uri: []const u8,
    line: usize,
    site: ?variables.Site,
    value: ?[]const u8,
    reachable: bool,
};

const Candidate = struct {
    uri: []const u8,
    start: usize,
    site: ?variables.Site,
    reachable: bool,
    facts: ?*const Facts = null,
};

/// Presentation selects candidates before any source reads or descriptions.
/// Keep all metadata entries so render's totals and truncation remain exact.
pub fn workspaceEntries(a: Allocator, cache: *descriptions.Cache, defs: []const wv.view.Occurrence, files: []const wv.File) ![]const Entry {
    const candidates = try a.alloc(Candidate, defs.len);
    for (defs, 0..) |def, i| {
        const file = wv.view.find(files, def.path) orelse unreachable;
        candidates[i] = .{ .uri = def.uri, .start = def.start, .site = def.site, .reachable = def.reachable, .facts = &file.facts };
    }
    return listedEntries(a, cache, candidates);
}

/// Fallback offsets must have been discovered through cache.source().
pub fn fallbackEntries(a: Allocator, cache: *descriptions.Cache, defs: []const variables.Occurrence) ![]const Entry {
    const candidates = try a.alloc(Candidate, defs.len);
    for (defs, 0..) |def, i| candidates[i] = .{ .uri = def.uri, .start = def.start, .site = def.site, .reachable = true };
    return listedEntries(a, cache, candidates);
}

fn listedEntries(a: Allocator, cache: *descriptions.Cache, candidates: []const Candidate) ![]const Entry {
    var reachable: usize = 0;
    for (candidates) |candidate| if (candidate.reachable) {
        reachable += 1;
    };
    const entries = try a.alloc(Entry, candidates.len);
    for (candidates, 0..) |candidate, i| {
        entries[i] = .{ .uri = candidate.uri, .line = 1, .site = candidate.site, .value = null, .reachable = candidate.reachable };
        // Active + twenty shadowed, and twenty elsewhere. Hidden entries are
        // count-only placeholders and are never passed to line().
        const listed = if (i < reachable) i == 0 or i - 1 < max_listed else i - reachable < max_listed;
        if (!listed) continue;
        const binding = if (candidate.facts) |facts|
            descriptions.Binding.indexed(candidate.uri, candidate.start, facts.*)
        else
            descriptions.Binding{ .uri = candidate.uri, .start = candidate.start };
        const description = try cache.describe(binding);
        entries[i].line = description.line;
        if (description.value) |raw| entries[i].value = dedentValue(a, raw, 0, raw.len) catch null;
    }
    return entries;
}

/// Markdown for the definitions of `name`, reachable ones first.
pub fn render(a: Allocator, name: []const u8, entries: []const Entry, root: ?[]const u8) ![]const u8 {
    return renderNamed(a, "Variable", name, entries, root);
}

pub fn renderField(a: Allocator, name: []const u8, entries: []const Entry, root: ?[]const u8) ![]const u8 {
    return renderNamed(a, "Variable field", name, entries, root);
}

fn renderNamed(a: Allocator, label: []const u8, name: []const u8, entries: []const Entry, root: ?[]const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    try out.writer().print("**{s}** `{s}`\n", .{ label, name });
    var reachable: usize = 0;
    for (entries) |e| if (e.reachable) {
        reachable += 1;
    };
    if (reachable > 0) {
        try out.appendSlice("\n**Active:** ");
        try line(a, &out, entries[0], root);
    }
    if (reachable > 1) {
        try out.appendSlice("\n**Shadowed:**\n");
        for (entries[1..reachable], 0..) |e, i| {
            if (i >= max_listed) break;
            try out.appendSlice("- ");
            try line(a, &out, e, root);
        }
    }
    if (entries.len > reachable) {
        try out.appendSlice("\n**Elsewhere in the Workspace:**\n");
        for (entries[reachable..], 0..) |e, i| {
            if (i >= max_listed) {
                try out.writer().print("- … and {d} more\n", .{entries.len - reachable - max_listed});
                break;
            }
            try out.appendSlice("- ");
            try line(a, &out, e, root);
        }
    }
    return out.toOwnedSlice();
}

fn line(a: Allocator, out: *std.array_list.Managed(u8), e: Entry, root: ?[]const u8) !void {
    const where = try display(a, e.uri, root);
    const site = if (e.site) |s| @tagName(s) else "definition";
    const value = e.value orelse "";
    if (value.len == 0) {
        try out.writer().print("`{s}:{d}` ({s})\n", .{ where, e.line, site });
    } else if (std.mem.indexOfScalar(u8, value, '\n') == null) {
        try out.writer().print("`{s}` — `{s}:{d}` ({s})\n", .{ value, where, e.line, site });
    } else {
        try out.writer().print("`{s}:{d}` ({s})\n\n```yaml\n{s}\n```\n", .{ where, e.line, site, value });
    }
}

fn display(a: Allocator, uri: []const u8, root: ?[]const u8) ![]const u8 {
    const p = try paths.uriToPath(a, uri);
    if (root) |r| {
        if (p.len > r.len + 1 and std.mem.startsWith(u8, p, r) and p[r.len] == '/') return p[r.len + 1 ..];
    }
    return p;
}

/// The unrendered value bound at the definition key starting at `start`, or
/// null when the site has no value (`register`, `loop_var`, ...).
pub fn valueAt(a: Allocator, text: []const u8, start: usize) ?[]const u8 {
    var forest = yaml.parse(a, text) catch return null;
    defer forest.deinit();
    for (forest.roots) |root| {
        const pair = pairWithKeyAt(root, start) orelse continue;
        const val = pair.val orelse return null;
        if (val.end > text.len or val.start >= val.end) return null;
        return dedentValue(a, text, val.start, val.end) catch null;
    }
    return null;
}

fn pairWithKeyAt(node: *yaml.Node, start: usize) ?*yaml.Node {
    switch (node.kind) {
        .map => for (node.items) |pair| {
            // Definition ranges exclude key quotes. Accept their inner start
            // as well as the raw YAML scalar start.
            if (pair.key) |k| if (k.start <= start and start < k.end) return pair;
            if (pair.val) |v| if (pairWithKeyAt(v, start)) |p| return p;
        },
        .seq => for (node.items) |item| {
            if (pairWithKeyAt(item, start)) |p| return p;
        },
        else => {},
    }
    return null;
}

fn dedentValue(a: Allocator, text: []const u8, start: usize, end: usize) ![]const u8 {
    const raw = std.mem.trimRight(u8, text[start..end], " \t\r\n");
    if (std.mem.indexOfScalar(u8, raw, '\n') == null) return a.dupe(u8, raw);
    // Block value: dedent continuation lines by their common indentation.
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var min_indent: usize = std.math.maxInt(usize);
    _ = lines.next();
    while (lines.next()) |l| {
        if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
        var i: usize = 0;
        while (i < l.len and l[i] == ' ') : (i += 1) {}
        min_indent = @min(min_indent, i);
    }
    if (min_indent == std.math.maxInt(usize)) min_indent = 0;
    var out = std.array_list.Managed(u8).init(a);
    var it = std.mem.splitScalar(u8, raw, '\n');
    var n: usize = 0;
    while (it.next()) |l| : (n += 1) {
        if (n >= max_value_lines) {
            try out.appendSlice("\n# …");
            break;
        }
        if (n > 0) try out.append('\n');
        try out.appendSlice(if (n == 0) l else l[@min(min_indent, l.len)..]);
    }
    return out.toOwnedSlice();
}

const testing = std.testing;

test "value of a scalar and a block definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "port: 5432\nusers:\n  - alice\n  - bob\n";
    try testing.expectEqualStrings("5432", valueAt(a, text, 0).?);
    const users = std.mem.indexOf(u8, text, "users").?;
    try testing.expectEqualStrings("- alice\n- bob", valueAt(a, text, users).?);
}

test "render lists active, shadowed, and elsewhere" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = [_]Entry{
        .{ .uri = "file:///w/playbooks/vars/prod.yml", .line = 1, .site = .vars_files, .value = "5433", .reachable = true },
        .{ .uri = "file:///w/roles/db/defaults/main.yml", .line = 1, .site = .role_defaults, .value = "5432", .reachable = true },
        .{ .uri = "file:///w/roles/web/defaults/main.yml", .line = 1, .site = .role_defaults, .value = "80", .reachable = false },
    };
    const md = try render(a, "db_port", &entries, "/w");
    try testing.expect(std.mem.indexOf(u8, md, "**Active:** `5433` — `playbooks/vars/prod.yml:1` (vars_files)") != null);
    try testing.expect(std.mem.indexOf(u8, md, "**Shadowed:**\n- `5432` — `roles/db/defaults/main.yml:1`") != null);
    try testing.expect(std.mem.indexOf(u8, md, "**Elsewhere in the Workspace:**\n- `80` — `roles/web/defaults/main.yml:1`") != null);
}

//! Discovers module FQCNs by scanning installed collections and redirect
//! routes, mirroring upstream's `docsFinder`.
//!
//! Upstream offers completions for every module it can find on disk, including
//! redirect routes declared in `meta/runtime.yml`. `ansible-doc -l` only lists
//! modules that resolve, so we scan the filesystem directly.

const std = @import("std");
const fsio = @import("../fsio.zig");
const Allocator = std.mem.Allocator;
const exec = @import("../exec/root.zig");
const yaml = @import("../yaml/root.zig");
const parsePythonArray = @import("ansible_config.zig").parsePythonArray;

pub const Index = struct {
    allocator: Allocator,
    runner: exec.Runner,
    execution: exec.Options = .{},
    /// FQCN → void. Keys are owned by `arena`.
    fqcns: std.StringHashMap(void),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator, runner: exec.Runner) Index {
        return .{
            .allocator = allocator,
            .runner = runner,
            .fqcns = std.StringHashMap(void).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Index) void {
        self.fqcns.deinit();
        self.arena.deinit();
    }

    pub fn scan(self: *Index, collections_paths: []const []const u8) void {
        const a = self.arena.allocator();
        // Collection discovery is filesystem-only, even without ansible on PATH.
        for (collections_paths) |p| self.scanCollections(a, @import("project_config.zig").collectionPathRoot(p));

        const ver = self.runner.runWithOptions(self.allocator, &.{ "ansible", "--version" }, self.execution) catch return;
        defer ver.deinit(self.allocator);
        const module_search = versionField(ver.stdout, "configured module search path");
        const ansible_location = versionField(ver.stdout, "ansible python module location");

        if (ansible_location) |loc| {
            const modules_dir = std.fs.path.join(a, &.{ loc, "modules" }) catch return;
            self.scanBuiltin(a, modules_dir);
            const runtime = std.fs.path.join(a, &.{ loc, "config", "ansible_builtin_runtime.yml" }) catch return;
            self.scanRuntime(a, runtime, "ansible.builtin");
        }
        if (module_search) |ms| {
            const paths = parsePythonArray(a, ms) catch &.{};
            for (paths) |p| self.scanBuiltin(a, p);
        }
    }

    fn add(self: *Index, a: Allocator, fqcn: []const u8) void {
        const key = a.dupe(u8, fqcn) catch return;
        self.fqcns.put(key, {}) catch {};
    }

    fn scanBuiltin(self: *Index, a: Allocator, dir: []const u8) void {
        var d = fsio.openDir(dir, .{ .iterate = true }) catch return;
        defer d.close(fsio.get());
        var walker = d.walk(self.allocator) catch return;
        defer walker.deinit();
        while (walker.next(fsio.get()) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".py")) continue;
            if (std.mem.startsWith(u8, entry.basename, "_")) continue;
            const name = entry.basename[0 .. entry.basename.len - 3];
            const fqcn = std.fmt.allocPrint(a, "ansible.builtin.{s}", .{name}) catch continue;
            self.add(a, fqcn);
        }
    }

    fn scanCollections(self: *Index, a: Allocator, base: []const u8) void {
        const root = std.fs.path.join(a, &.{ base, "ansible_collections" }) catch return;
        var d = fsio.openDir(root, .{ .iterate = true }) catch return;
        defer d.close(fsio.get());
        var ns_it = d.iterate();
        while (ns_it.next(fsio.get()) catch null) |ns_entry| {
            if (ns_entry.kind != .directory) continue;
            var ns_dir = d.openDir(fsio.get(), ns_entry.name, .{ .iterate = true }) catch continue;
            defer ns_dir.close(fsio.get());
            var coll_it = ns_dir.iterate();
            while (coll_it.next(fsio.get()) catch null) |coll_entry| {
                if (coll_entry.kind != .directory) continue;
                const modules_dir = std.fs.path.join(a, &.{
                    base, "ansible_collections", ns_entry.name, coll_entry.name, "plugins", "modules",
                }) catch continue;
                self.scanCollectionModules(a, modules_dir, ns_entry.name, coll_entry.name);
                const runtime = std.fs.path.join(a, &.{
                    base, "ansible_collections", ns_entry.name, coll_entry.name, "meta", "runtime.yml",
                }) catch continue;
                const collection = std.fmt.allocPrint(a, "{s}.{s}", .{ ns_entry.name, coll_entry.name }) catch continue;
                self.scanRuntime(a, runtime, collection);
            }
        }
    }

    fn scanCollectionModules(self: *Index, a: Allocator, dir: []const u8, ns: []const u8, coll: []const u8) void {
        var d = fsio.openDir(dir, .{ .iterate = true }) catch return;
        defer d.close(fsio.get());
        var walker = d.walk(self.allocator) catch return;
        defer walker.deinit();
        while (walker.next(fsio.get()) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".py")) continue;
            if (std.mem.startsWith(u8, entry.basename, "_")) continue;
            const name = entry.basename[0 .. entry.basename.len - 3];
            // Subdirectories extend the collection name, e.g. `foo.bar.sub`.
            var collection = coll;
            if (std.fs.path.dirname(entry.path)) |sub| {
                const joined = std.mem.replaceOwned(u8, a, sub, "/", ".") catch continue;
                collection = std.fmt.allocPrint(a, "{s}.{s}", .{ coll, joined }) catch continue;
            }
            const fqcn = std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ ns, collection, name }) catch continue;
            self.add(a, fqcn);
        }
    }

    fn scanRuntime(self: *Index, a: Allocator, path: []const u8, collection: []const u8) void {
        const bytes = fsio.readFileAlloc(self.allocator, path, 64 * 1024 * 1024) catch return;
        defer self.allocator.free(bytes);
        var routes = std.ArrayList([]const u8).empty;
        defer routes.deinit(self.allocator);
        runtimeModuleRoutesWithScratch(a, self.allocator, bytes, &routes) catch return;
        for (routes.items) |name| {
            const fqcn = std.fmt.allocPrint(a, "{s}.{s}", .{ collection, name }) catch continue;
            self.add(a, fqcn);
        }
    }
};

const RouteLine = struct {
    indent: usize,
    body: []const u8,
};

const MappingLine = struct {
    key: []const u8,
    value: []const u8,
    block_scalar: bool,
    needs_fallback: bool,
};

fn isDocMarker(body: []const u8, marker: []const u8) bool {
    if (!std.mem.startsWith(u8, body, marker)) return false;
    if (body.len == marker.len) return true;
    return body[marker.len] == ' ' or body[marker.len] == '\t';
}

fn isDocMarkerWithInlineContent(body: []const u8, marker: []const u8) bool {
    if (!isDocMarker(body, marker)) return false;
    const rest = stripInlineComment(std.mem.trimStart(u8, body[marker.len..], " \t"));
    return rest.len > 0;
}

fn stripInlineComment(s: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\' and i + 1 < s.len) {
                i += 1;
                continue;
            }
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '#' and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t')) {
            return std.mem.trimEnd(u8, s[0..i], " \t");
        }
    }
    return std.mem.trimEnd(u8, s, " \t");
}

fn isBlockScalarHeader(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] != '|' and value[0] != '>') return false;
    for (value[1..]) |c| {
        if (c != '+' and c != '-' and (c < '1' or c > '9')) return false;
    }
    return true;
}

fn hasComplexValueSyntax(value: []const u8) bool {
    if (value.len == 0) return false;
    return switch (value[0]) {
        '{', '[', '&', '*', '!' => true,
        else => false,
    };
}

fn nextRouteLine(text: []const u8, pos: *usize) ?RouteLine {
    while (pos.* < text.len) {
        const line_start = pos.*;
        while (pos.* < text.len and text[pos.*] != '\n') : (pos.* += 1) {}
        var line_end = pos.*;
        if (line_end > line_start and text[line_end - 1] == '\r') line_end -= 1;
        if (pos.* < text.len) pos.* += 1;

        const raw = text[line_start..line_end];
        var indent: usize = 0;
        while (indent < raw.len and raw[indent] == ' ') : (indent += 1) {}
        const trimmed = std.mem.trimEnd(u8, raw[indent..], " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        return .{ .indent = indent, .body = trimmed };
    }
    return null;
}

fn splitMappingLine(body: []const u8) ?MappingLine {
    if (body.len == 0) return null;
    switch (body[0]) {
        '?', '{', '[', '&', '*', '!' => return .{
            .key = "",
            .value = "",
            .block_scalar = false,
            .needs_fallback = true,
        },
        '-' => {
            if (body.len == 1 or body[1] == ' ' or body[1] == '\t') return null;
        },
        else => {},
    }

    var key: []const u8 = undefined;
    var colon_idx: usize = undefined;
    var needs_fallback = false;

    if (body[0] == '"') {
        var i: usize = 1;
        while (i < body.len) : (i += 1) {
            if (body[i] == '\\') {
                needs_fallback = true;
                if (i + 1 < body.len) i += 1;
                continue;
            }
            if (body[i] == '"') break;
        }
        if (i >= body.len) return .{ .key = "", .value = "", .block_scalar = false, .needs_fallback = true };
        key = body[1..i];
        var j = i + 1;
        while (j < body.len and (body[j] == ' ' or body[j] == '\t')) : (j += 1) {}
        if (j >= body.len or body[j] != ':') return null;
        if (j + 1 < body.len and body[j + 1] != ' ' and body[j + 1] != '\t') return null;
        colon_idx = j;
    } else if (body[0] == '\'') {
        var i: usize = 1;
        while (i < body.len) : (i += 1) {
            if (body[i] == '\'') {
                if (i + 1 < body.len and body[i + 1] == '\'') {
                    needs_fallback = true;
                    i += 1;
                    continue;
                }
                break;
            }
        }
        if (i >= body.len) return .{ .key = "", .value = "", .block_scalar = false, .needs_fallback = true };
        key = body[1..i];
        var j = i + 1;
        while (j < body.len and (body[j] == ' ' or body[j] == '\t')) : (j += 1) {}
        if (j >= body.len or body[j] != ':') return null;
        if (j + 1 < body.len and body[j + 1] != ' ' and body[j + 1] != '\t') return null;
        colon_idx = j;
    } else {
        var found: ?usize = null;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            const c = body[i];
            if (c == '#' and (i == 0 or body[i - 1] == ' ' or body[i - 1] == '\t')) return null;
            if (c == ':' and (i + 1 == body.len or body[i + 1] == ' ' or body[i + 1] == '\t')) {
                found = i;
                break;
            }
        }
        colon_idx = found orelse return null;
        key = std.mem.trimEnd(u8, body[0..colon_idx], " \t");
    }

    const raw_rest = if (colon_idx + 1 < body.len)
        std.mem.trimStart(u8, body[colon_idx + 1 ..], " \t")
    else
        "";
    const value = stripInlineComment(raw_rest);
    const block_scalar = isBlockScalarHeader(value);
    if (needs_fallback) {
        return .{ .key = key, .value = value, .block_scalar = block_scalar, .needs_fallback = true };
    }
    return .{
        .key = key,
        .value = value,
        .block_scalar = block_scalar,
        .needs_fallback = false,
    };
}

pub fn runtimeModuleRoutes(a: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    return runtimeModuleRoutesWithScratch(a, a, text, out);
}

fn runtimeModuleRoutesWithScratch(
    a: Allocator,
    scratch: Allocator,
    text: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const start_len = out.items.len;
    scanRuntimeFast(a, scratch, text, out) catch |err| switch (err) {
        error.FallbackToYaml => {
            out.shrinkRetainingCapacity(start_len);
            try runtimeModuleRoutesYaml(a, scratch, text, out);
        },
        else => return err,
    };
}

fn scanRuntimeFast(
    a: Allocator,
    scratch: Allocator,
    raw_text: []const u8,
    out: *std.ArrayList([]const u8),
) (Allocator.Error || error{FallbackToYaml})!void {
    const text = if (std.mem.startsWith(u8, raw_text, "\xef\xbb\xbf"))
        raw_text[3..]
    else
        raw_text;

    var pos: usize = 0;

    var line: RouteLine = while (nextRouteLine(text, &pos)) |l| {
        if (l.indent == 0 and l.body[0] == '%') continue;
        if (l.indent == 0 and isDocMarker(l.body, "---")) {
            if (isDocMarkerWithInlineContent(l.body, "---")) return error.FallbackToYaml;
            continue;
        }
        if (l.indent == 0 and isDocMarker(l.body, "...")) return;
        break l;
    } else return;

    const root_indent = line.indent;
    var pr_indent: usize = undefined;
    var block_scalar_indent: ?usize = null;

    while (true) {
        if (block_scalar_indent) |bs| {
            if (line.indent > bs) {
                line = nextRouteLine(text, &pos) orelse return;
                continue;
            }
            block_scalar_indent = null;
        }
        if (line.indent == 0 and (isDocMarker(line.body, "...") or isDocMarker(line.body, "---"))) return;
        if (line.indent < root_indent) return error.FallbackToYaml;
        if (line.indent == root_indent) {
            const m = splitMappingLine(line.body) orelse {
                line = nextRouteLine(text, &pos) orelse return;
                continue;
            };
            if (m.needs_fallback) return error.FallbackToYaml;
            if (std.mem.eql(u8, m.key, "plugin_routing")) {
                if (m.value.len > 0) {
                    if (hasComplexValueSyntax(m.value)) return error.FallbackToYaml;
                    return;
                }
                pr_indent = line.indent;
                break;
            }
            if (m.block_scalar) block_scalar_indent = line.indent;
        }
        line = nextRouteLine(text, &pos) orelse return;
    }

    var category_indent: ?usize = null;
    var modules_indent: usize = undefined;
    while (true) {
        const l = nextRouteLine(text, &pos) orelse return;
        if (block_scalar_indent) |bs| {
            if (l.indent > bs) continue;
            block_scalar_indent = null;
        }
        if (l.indent == 0 and (isDocMarker(l.body, "...") or isDocMarker(l.body, "---"))) return;
        if (l.indent <= pr_indent) return;
        if (category_indent == null) category_indent = l.indent;
        if (l.indent < category_indent.?) return error.FallbackToYaml;
        if (l.indent > category_indent.?) continue;

        const m = splitMappingLine(l.body) orelse return error.FallbackToYaml;
        if (m.needs_fallback) return error.FallbackToYaml;
        if (std.mem.eql(u8, m.key, "modules")) {
            if (m.value.len > 0) {
                if (hasComplexValueSyntax(m.value)) return error.FallbackToYaml;
                return;
            }
            modules_indent = l.indent;
            break;
        }
        if (m.block_scalar) block_scalar_indent = l.indent;
    }

    var entry_indent: ?usize = null;
    var fact_indent: ?usize = null;
    var name: []const u8 = "";
    var has_redirect = false;
    var has_tombstone = false;

    while (true) {
        const l = nextRouteLine(text, &pos) orelse break;
        if (block_scalar_indent) |bs| {
            if (l.indent > bs) continue;
            block_scalar_indent = null;
        }
        if (l.indent == 0 and (isDocMarker(l.body, "...") or isDocMarker(l.body, "---"))) break;
        if (l.indent <= modules_indent) break;

        if (entry_indent == null) entry_indent = l.indent;
        if (l.indent < entry_indent.?) return error.FallbackToYaml;

        if (l.indent == entry_indent.?) {
            if (name.len > 0 and has_redirect and !has_tombstone)
                try out.append(scratch, try a.dupe(u8, name));
            const m = splitMappingLine(l.body) orelse return error.FallbackToYaml;
            if (m.needs_fallback) return error.FallbackToYaml;
            if (m.value.len > 0) {
                if (hasComplexValueSyntax(m.value)) return error.FallbackToYaml;
                name = "";
                fact_indent = null;
                has_redirect = false;
                has_tombstone = false;
                if (m.block_scalar) block_scalar_indent = l.indent;
                continue;
            }
            name = m.key;
            fact_indent = null;
            has_redirect = false;
            has_tombstone = false;
            continue;
        }

        if (fact_indent == null) fact_indent = l.indent;
        if (l.indent < fact_indent.?) return error.FallbackToYaml;

        if (l.indent == fact_indent.?) {
            const m = splitMappingLine(l.body) orelse return error.FallbackToYaml;
            if (m.needs_fallback) return error.FallbackToYaml;
            if (m.block_scalar) block_scalar_indent = l.indent;
            if (std.mem.eql(u8, m.key, "redirect")) has_redirect = true;
            if (std.mem.eql(u8, m.key, "tombstone")) has_tombstone = true;
        }
    }

    if (name.len > 0 and has_redirect and !has_tombstone)
        try out.append(scratch, try a.dupe(u8, name));
}

fn runtimeModuleRoutesYaml(
    a: Allocator,
    scratch: Allocator,
    text: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var forest = yaml.parse(scratch, text) catch return;
    defer forest.deinit();
    if (forest.roots.len == 0) return;
    const pr = mapGet(forest.roots[0], "plugin_routing") orelse return;
    const modules = mapGet(pr, "modules") orelse return;
    if (!modules.isMap()) return;
    for (modules.items) |pair| {
        const key = pair.key orelse continue;
        const name = key.stringValue() orelse continue;
        const route = pair.val orelse continue;
        if (mapGet(route, "redirect") == null) continue;
        if (mapGet(route, "tombstone") != null) continue;
        try out.append(scratch, try a.dupe(u8, name));
    }
}

fn mapGet(node: *yaml.Node, key: []const u8) ?*yaml.Node {
    if (!node.isMap()) return null;
    for (node.items) |pair| {
        const k = pair.key orelse continue;
        const s = k.stringValue() orelse continue;
        if (std.mem.eql(u8, s, key)) return pair.val;
    }
    return null;
}

/// Extract `key = value` from `ansible --version` output.
fn versionField(stdout: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const rest = trimmed[key.len..];
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
        return std.mem.trim(u8, rest[eq + 1 ..], " \t");
    }
    return null;
}

test "runtime module routes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\# leading comment
        \\plugin_routing:
        \\  connection:   # non-module categories are skipped
        \\    local:
        \\      redirect: ansible.builtin.whatever
        \\  modules:
        \\    # a comment between entries
        \\    old_name:
        \\      redirect: ns.coll.new_name
        \\    "quoted_name":
        \\      redirect: ns.coll.other
        \\      # tombstone below disqualifies
        \\    gone:
        \\      redirect: ns.coll.gone
        \\      tombstone:
        \\        removal_version: 2.12
        \\    no_redirect:
        \\      deprecation:
        \\        removal_version: 3.0
        \\
    ;
    var routes = std.ArrayList([]const u8).empty;
    try runtimeModuleRoutes(a, text, &routes);
    try std.testing.expectEqual(@as(usize, 2), routes.items.len);
    try std.testing.expectEqualStrings("old_name", routes.items[0]);
    try std.testing.expectEqualStrings("quoted_name", routes.items[1]);
}

test "runtime module routes ignore unrelated roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\requires_ansible: ">=2.10"
        \\plugin_routing:
        \\  modules:
        \\    nested:
        \\      redirect: x.y.z
        \\
    ;
    var routes = std.ArrayList([]const u8).empty;
    try runtimeModuleRoutes(a, text, &routes);
    try std.testing.expectEqual(@as(usize, 1), routes.items.len);
    try std.testing.expectEqualStrings("nested", routes.items[0]);

    var empty = std.ArrayList([]const u8).empty;
    try runtimeModuleRoutes(a, "plugin_routing:\n  connection: {}\n", &empty);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
    try runtimeModuleRoutes(a, "no routing here\n", &empty);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}

test "runtime module routes match YAML tree walk across edge cases" {
    const cases = [_][]const u8{
        \\plugin_routing:
        \\  connection:
        \\    modules:
        \\      redirect: ns.coll.conn
        \\  modules:
        \\    old:
        \\      redirect: ns.coll.new
        \\
        ,
        \\plugin_routing:
        \\  modules:
        \\    old:
        \\      redirect: ns.coll.new
        \\      deprecation:
        \\        warning_text: |
        \\          tombstone: not an actual route fact
        \\
        ,
        \\plugin_routing:
        \\  modules:
        \\    no_redirect:
        \\      deprecation:
        \\        redirect: ns.coll.new
        \\
        ,
        \\plugin_routing:
        \\  modules:
        \\    old: {redirect: ns.coll.new}
        \\
        ,
        \\"plugin_\u0072outing":
        \\  modules:
        \\    "a\"b":
        \\      redirect: ns.coll.new
        \\    'c''d':
        \\      redirect: ns.coll.other
        \\
        ,
        \\plugin_routing:
        \\  modules:
        \\    empty_redir:
        \\      redirect:
        \\    empty_tomb:
        \\      redirect: ns.coll.new
        \\      tombstone:
        \\
        ,
        "\xef\xbb\xbf---\n  plugin_routing:\n    modules:\n      old:\n        redirect: ns.coll.new\n",
        \\plugin_routing:
        \\  modules:
        \\    old:
        \\      redirect: ns.coll.new
        \\   bogus:
        \\      tombstone: yes
        \\
        ,
        \\---
        \\requires_ansible: ">=2.10"
        \\---
        \\plugin_routing:
        \\  modules:
        \\    second_doc:
        \\      redirect: ns.coll.new
        \\
    };

    for (cases) |text| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var fast = std.ArrayList([]const u8).empty;
        defer fast.deinit(std.testing.allocator);
        try runtimeModuleRoutesWithScratch(a, std.testing.allocator, text, &fast);

        var expected = std.ArrayList([]const u8).empty;
        defer expected.deinit(std.testing.allocator);
        try runtimeModuleRoutesYaml(a, std.testing.allocator, text, &expected);

        try std.testing.expectEqual(expected.items.len, fast.items.len);
        for (expected.items, fast.items) |exp, got| {
            try std.testing.expectEqualStrings(exp, got);
        }
    }
}

test "version field" {
    const out = "ansible [core 2.17.1]\n  configured module search path = ['/x']\n  ansible python module location = /y\n";
    try std.testing.expectEqualStrings("['/x']", versionField(out, "configured module search path").?);
    try std.testing.expectEqualStrings("/y", versionField(out, "ansible python module location").?);
}

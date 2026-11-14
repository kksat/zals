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
        runtimeModuleRoutes(a, bytes, &routes) catch return;
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

fn routeKey(body: []const u8) ?[]const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '#') return null;
        if (c == ':') {
            if (i + 1 != body.len and body[i + 1] != ' ' and body[i + 1] != '\t') continue;
            const key = std.mem.trimEnd(u8, body[0..i], " \t");
            if (key.len >= 2 and ((key[0] == '"' and key[key.len - 1] == '"') or
                (key[0] == '\'' and key[key.len - 1] == '\'')))
            {
                return key[1 .. key.len - 1];
            }
            return key;
        }
    }
    return null;
}

pub fn runtimeModuleRoutes(a: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var pos: usize = 0;

    const first = nextRouteLine(text, &pos) orelse return;
    const root_indent = first.indent;
    var pr_indent: usize = undefined;
    var line = first;
    while (true) {
        if (line.indent < root_indent) return;
        if (line.indent == root_indent and
            std.mem.eql(u8, routeKey(line.body) orelse "", "plugin_routing"))
        {
            pr_indent = line.indent;
            break;
        }
        line = nextRouteLine(text, &pos) orelse return;
    }

    var modules_indent: usize = undefined;
    while (true) {
        const l = nextRouteLine(text, &pos) orelse return;
        if (l.indent <= pr_indent) return;
        if (std.mem.eql(u8, routeKey(l.body) orelse "", "modules")) {
            modules_indent = l.indent;
            break;
        }
    }

    var entry_indent: ?usize = null;
    var name: []const u8 = "";
    var has_redirect = false;
    var has_tombstone = false;
    while (true) {
        const l = nextRouteLine(text, &pos) orelse break;
        if (l.indent <= modules_indent) break;
        if (entry_indent == null) entry_indent = l.indent;
        if (l.indent == entry_indent.?) {
            if (name.len > 0 and has_redirect and !has_tombstone)
                try out.append(a, try a.dupe(u8, name));
            name = routeKey(l.body) orelse "";
            has_redirect = false;
            has_tombstone = false;
            continue;
        }
        if (l.indent > entry_indent.?) {
            const fact_key = routeKey(l.body) orelse continue;
            if (std.mem.eql(u8, fact_key, "redirect")) has_redirect = true;
            if (std.mem.eql(u8, fact_key, "tombstone")) has_tombstone = true;
        }
    }
    if (name.len > 0 and has_redirect and !has_tombstone)
        try out.append(a, try a.dupe(u8, name));
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

test "version field" {
    const out = "ansible [core 2.17.1]\n  configured module search path = ['/x']\n  ansible python module location = /y\n";
    try std.testing.expectEqualStrings("['/x']", versionField(out, "configured module search path").?);
    try std.testing.expectEqualStrings("/y", versionField(out, "ansible python module location").?);
}

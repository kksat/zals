//! Session Workspaces (ADR-0014): folder/configuration events become index and
//! warning effects. Main-thread only (ADR-0011); no index or writer dependency.

const std = @import("std");
const Allocator = std.mem.Allocator;
const roots_mod = @import("roots.zig");
const discover = @import("discover.zig");
const paths = @import("../paths.zig");
const Settings = @import("settings.zig").Settings;

pub const Config = struct {
    marker: []const u8 = roots_mod.default_marker,
    warn_missing: bool = true,
    venv: []const u8 = ".venv",

    pub fn from(settings: *const Settings) Config {
        return .{ .marker = settings.root_marker, .warn_missing = settings.missing_git_warning, .venv = settings.venv_path };
    }
};

pub const Event = union(enum) {
    initialize: struct { folders: []const []const u8, config: Config },
    ready,
    folders_changed: struct { added: []const []const u8, removed: []const []const u8 },
    config_changed: Config,
};

pub const Effects = struct {
    /// Bring the index to exactly these roots; rescan also scans retained roots.
    sync: ?struct { roots: []const []const u8, marker: []const u8, rescan: bool } = null,
    /// Show and log once. The session already counts this warning as sent.
    warning: ?[]const u8 = null,
};

/// Borrowed until the next apply/deinit. Ownership must be memoised only within
/// a request: a newly created nested marker takes effect on the next request.
pub const Snapshot = struct {
    roots: []const []const u8 = &.{},
    marker: []const u8 = roots_mod.default_marker,
    venv: []const u8 = ".venv",

    /// Nearest marker root, if it is a session Workspace. Files in excluded
    /// directories still have an owner (for project configuration).
    pub fn owner(self: Snapshot, a: Allocator, path: []const u8) ?[]const u8 {
        const owned = roots_mod.owning(a, path, self.roots, self.marker) catch return null;
        defer if (owned) |one| a.free(one);
        return if (owned) |one| one[0] else null;
    }

    /// Owner AND a Workspace source file, excluding nested markers, virtual
    /// environments and excluded directories. `path` must use resolvedPath's
    /// form, just like roots; this also accepts not-yet-existing source files.
    pub fn member(self: Snapshot, path: []const u8) ?[]const u8 {
        if (!discover.isWorkspaceFile(path)) return null;
        for (self.roots) |root| {
            if (discover.belongsToWorkspace(root, path, self.marker)) return root;
        }
        return null;
    }
};

pub const resolvedPath = roots_mod.resolvedPath;

pub const Session = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    opened: []const []const u8 = &.{},
    roots: []const []const u8 = &.{},
    marker: []const u8 = roots_mod.default_marker,
    venv: []const u8 = ".venv",
    venv_override: ?[]const u8 = null,
    warn_missing: bool = true,
    warned: bool = false,
    ready: bool = false,

    /// The CLI selection is copied, including an empty (disabled) override.
    pub fn init(gpa: Allocator, venv_override: ?[]const u8) !Session {
        var self = Session{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
        errdefer self.deinit();
        if (venv_override) |venv| self.venv_override = try self.arena.allocator().dupe(u8, venv);
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.arena.deinit();
    }

    pub fn snapshot(self: *const Session) Snapshot {
        return .{ .roots = self.roots, .marker = self.marker, .venv = self.venv_override orelse self.venv };
    }

    /// The only mutator. Inputs are copied; effects belong to `a`, and must be
    /// applied sync-before-warning. Before ready there are no effects. Allocation
    /// failure leaves the previous state intact; filesystem misses are missing
    /// Workspaces, not errors. A marker change yields one rescan effect.
    pub fn apply(self: *Session, a: Allocator, event: Event) !Effects {
        if (event == .ready and self.ready) return .{};
        var next = Session{ .gpa = self.gpa, .arena = std.heap.ArenaAllocator.init(self.gpa) };
        errdefer next.deinit();
        const owned = next.arena.allocator();
        next.ready = self.ready;
        next.warned = self.warned;
        next.warn_missing = self.warn_missing;
        var config = Config{ .marker = self.marker, .venv = self.venv, .warn_missing = self.warn_missing };
        var folders = std.array_list.Managed([]const u8).init(owned);
        const initial = if (event == .initialize) event.initialize.folders else self.opened;
        for (initial) |uri| try appendUnique(&folders, uri);
        switch (event) {
            .initialize => |init_event| config = init_event.config,
            .ready => next.ready = true,
            .config_changed => |changed| config = changed,
            .folders_changed => |changed| {
                for (changed.removed) |uri| {
                    for (folders.items, 0..) |existing, i| {
                        if (std.mem.eql(u8, existing, uri)) {
                            _ = folders.orderedRemove(i);
                            break;
                        }
                    }
                }
                for (changed.added) |uri| try appendUnique(&folders, uri);
            },
        }
        next.marker = try owned.dupe(u8, roots_mod.effectiveMarker(config.marker));
        next.venv = try owned.dupe(u8, config.venv);
        next.warn_missing = config.warn_missing;
        if (self.venv_override) |venv| next.venv_override = try owned.dupe(u8, venv);
        const marker_changed = !std.mem.eql(u8, self.marker, next.marker);
        if (marker_changed) next.warned = false;
        for (folders.items) |*uri| uri.* = try owned.dupe(u8, uri.*);
        next.opened = try folders.toOwnedSlice();

        var opened_paths = std.array_list.Managed([]const u8).init(owned);
        var missing = false;
        for (next.opened) |uri| {
            // Only absolute file URIs can identify an opened folder. Invalid
            // folders count as missing without discarding the valid folders.
            if (!std.mem.startsWith(u8, uri, "file://")) {
                missing = true;
                continue;
            }
            const path = try paths.uriToPath(owned, uri);
            if (!std.fs.path.isAbsolute(path)) {
                missing = true;
                continue;
            }
            try opened_paths.append(path);
        }
        const resolved = try roots_mod.resolve(owned, opened_paths.items, next.marker);
        next.roots = resolved.roots.items;
        missing = missing or resolved.missing;

        var effects = Effects{};
        if (next.ready) {
            effects.sync = .{ .roots = try copyStrings(a, next.roots), .marker = try a.dupe(u8, next.marker), .rescan = marker_changed };
            if (next.warn_missing and missing and !next.warned) {
                effects.warning = try roots_mod.missingMessage(a, next.marker);
                next.warned = true;
            }
        }
        self.deinit();
        self.* = next;
        return effects;
    }
};

fn appendUnique(list: *std.array_list.Managed([]const u8), item: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, item)) return;
    try list.append(item);
}

fn copyStrings(a: Allocator, strings: []const []const u8) ![]const []const u8 {
    const copy = try a.alloc([]const u8, strings.len);
    for (strings, copy) |s, *dest| dest.* = try a.dupe(u8, s);
    return copy;
}

const testing = std.testing;
const test_marker = ".zals-session-marker";

fn folderUri(a: Allocator, dir: std.fs.Dir, rel: []const u8) ![]const u8 {
    const path = try dir.realpathAlloc(a, rel);
    defer a.free(path);
    return paths.pathToUri(a, path);
}

fn expectNoEffects(effects: Effects) !void {
    try testing.expect(effects.sync == null);
    try testing.expect(effects.warning == null);
}

test "initialization resolves roots but defers all effects until ready; warning is once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("workspace/" ++ test_marker);
    try tmp.dir.makeDir("missing");
    try tmp.dir.makeDir("also-missing");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session = try Session.init(testing.allocator, null);
    defer session.deinit();
    const config = Config{ .marker = test_marker };
    const ws = try folderUri(a, tmp.dir, "workspace");
    const missing = try folderUri(a, tmp.dir, "missing");
    try expectNoEffects(try session.apply(a, .{ .initialize = .{ .folders = &.{ ws, missing }, .config = config } }));
    try testing.expectEqual(@as(usize, 1), session.snapshot().roots.len);
    try expectNoEffects(try session.apply(a, .{ .config_changed = config }));
    const ready = try session.apply(a, .ready);
    try testing.expectEqual(@as(usize, 1), ready.sync.?.roots.len);
    try testing.expect(!ready.sync.?.rescan);
    try testing.expect(ready.warning != null);
    try expectNoEffects(try session.apply(a, .ready));
    const added = try session.apply(a, .{ .folders_changed = .{
        .added = &.{try folderUri(a, tmp.dir, "also-missing")},
        .removed = &.{},
    } });
    try testing.expect(added.sync != null);
    try testing.expect(added.warning == null);
    try testing.expectEqualStrings(test_marker, ready.sync.?.marker); // Effects survive another apply.
}

test "marker change returns one rescan and rearms warning, unchanged config does neither" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("workspace/" ++ test_marker);
    try tmp.dir.makePath("workspace/child/next-marker");
    try tmp.dir.makeDir("missing");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session = try Session.init(testing.allocator, null);
    defer session.deinit();
    _ = try session.apply(a, .{ .initialize = .{ .folders = &.{
        try folderUri(a, tmp.dir, "workspace/child"),
        try folderUri(a, tmp.dir, "missing"),
    }, .config = .{ .marker = test_marker } } });
    const ready = try session.apply(a, .ready);
    try testing.expect(ready.warning != null);
    const changed = try session.apply(a, .{ .config_changed = .{ .marker = "next-marker" } });
    try testing.expect(changed.sync.?.rescan);
    try testing.expectEqual(@as(usize, 1), changed.sync.?.roots.len);
    try testing.expectEqualStrings(try tmp.dir.realpathAlloc(a, "workspace/child"), changed.sync.?.roots[0]);
    try testing.expect(changed.warning != null);
    try testing.expect(std.mem.indexOf(u8, changed.warning.?, "next-marker") != null);
    const repeated = try session.apply(a, .{ .config_changed = .{ .marker = "next-marker" } });
    try testing.expect(!repeated.sync.?.rescan);
    try testing.expect(repeated.warning == null);
}

test "warning can be enabled later and folder/config changes before ready have no effects" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session = try Session.init(testing.allocator, null);
    defer session.deinit();
    const disabled = Config{ .marker = test_marker, .warn_missing = false };
    try expectNoEffects(try session.apply(a, .{ .initialize = .{ .folders = &.{}, .config = disabled } }));
    try expectNoEffects(try session.apply(a, .{ .folders_changed = .{ .added = &.{try folderUri(a, tmp.dir, ".")}, .removed = &.{} } }));
    try expectNoEffects(try session.apply(a, .{ .config_changed = .{ .marker = "another-absent-marker", .warn_missing = false } }));
    try testing.expect((try session.apply(a, .ready)).warning == null);
    const enabled = try session.apply(a, .{ .config_changed = .{ .marker = "another-absent-marker" } });
    try testing.expect(enabled.warning != null);
    try testing.expect(!enabled.sync.?.rescan);
    try testing.expect((try session.apply(a, .{ .config_changed = .{ .marker = "another-absent-marker" } })).warning == null);
}

test "two opened folders share one root until both are removed; duplicate URIs form a set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir(test_marker);
    try tmp.dir.makeDir("playbooks");
    try tmp.dir.makeDir("roles");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session = try Session.init(testing.allocator, null);
    defer session.deinit();
    const playbooks = try folderUri(a, tmp.dir, "playbooks");
    const roles_uri = try folderUri(a, tmp.dir, "roles");
    _ = try session.apply(a, .{ .initialize = .{ .folders = &.{ playbooks, roles_uri, playbooks }, .config = .{ .marker = test_marker } } });
    const ready = try session.apply(a, .ready);
    try testing.expectEqual(@as(usize, 1), ready.sync.?.roots.len);
    try testing.expect(ready.warning == null);
    const one_left = try session.apply(a, .{ .folders_changed = .{ .added = &.{ roles_uri, roles_uri }, .removed = &.{playbooks} } });
    try testing.expectEqual(@as(usize, 1), one_left.sync.?.roots.len);
    const empty = try session.apply(a, .{ .folders_changed = .{ .added = &.{}, .removed = &.{roles_uri} } });
    try testing.expectEqual(@as(usize, 0), empty.sync.?.roots.len);
    try testing.expect(empty.warning == null);
}

test "distinct marker files/directories are roots; invalid folder URI is missing, not fatal" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("first/" ++ test_marker);
    try tmp.dir.makeDir("second");
    try tmp.dir.writeFile(.{ .sub_path = "second/" ++ test_marker, .data = "marker file" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session = try Session.init(testing.allocator, null);
    defer session.deinit();
    _ = try session.apply(a, .{ .initialize = .{ .folders = &.{
        "untitled:invalid", try folderUri(a, tmp.dir, "first"), "file://relative", try folderUri(a, tmp.dir, "second"),
    }, .config = .{ .marker = test_marker } } });
    const ready = try session.apply(a, .ready);
    try testing.expectEqual(@as(usize, 2), ready.sync.?.roots.len);
    try testing.expectEqualStrings(try tmp.dir.realpathAlloc(a, "first"), ready.sync.?.roots[0]);
    try testing.expectEqualStrings(try tmp.dir.realpathAlloc(a, "second"), ready.sync.?.roots[1]);
    try testing.expect(ready.warning != null);
}

test "configuration strings are owned, effective markers are sanitized, and venv override wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]?[]const u8{ null, "cli-env", "" }) |override| {
        var session = try Session.init(testing.allocator, override);
        defer session.deinit();
        var marker = "custom-marker".*;
        var venv = "setting-env".*;
        _ = try session.apply(a, .{ .initialize = .{ .folders = &.{}, .config = .{ .marker = &marker, .venv = &venv } } });
        @memset(&marker, 'x');
        @memset(&venv, 'x');
        try testing.expectEqualStrings("custom-marker", session.snapshot().marker);
        try testing.expectEqualStrings(override orelse "setting-env", session.snapshot().venv);
        _ = try session.apply(a, .{ .config_changed = .{ .marker = "bad/path", .venv = "" } });
        try testing.expectEqualStrings(".git", session.snapshot().marker);
        try testing.expectEqualStrings(override orelse "", session.snapshot().venv);
        _ = try session.apply(a, .ready);
        const same_effective_marker = try session.apply(a, .{ .config_changed = .{ .marker = "..", .venv = "other-env" } });
        try testing.expect(!same_effective_marker.sync.?.rescan);
        try testing.expectEqualStrings(override orelse "other-env", session.snapshot().venv);
    }
}

test "owner differs from member for nested markers, virtual environments and excluded directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir(test_marker);
    try tmp.dir.makePath("nested/tasks");
    try tmp.dir.makePath(".venv/tasks");
    try tmp.dir.makePath("custom-env/tasks");
    try tmp.dir.writeFile(.{ .sub_path = "custom-env/pyvenv.cfg", .data = "" });
    try tmp.dir.makePath("node_modules/tasks");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var session = try Session.init(testing.allocator, null);
    defer session.deinit();
    _ = try session.apply(a, .{ .initialize = .{ .folders = &.{try folderUri(a, tmp.dir, ".")}, .config = .{ .marker = test_marker } } });
    const snapshot = session.snapshot();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const nested = try std.fs.path.join(a, &.{ root, "nested/tasks/main.yml" });
    try testing.expectEqualStrings(root, snapshot.owner(a, nested).?);
    try testing.expectEqualStrings(root, snapshot.member(nested).?);
    // No session-lifetime owner memo: a marker created after the snapshot is
    // observed by the next query, without any folder/configuration event.
    try tmp.dir.makePath("nested/" ++ test_marker);
    try testing.expect(snapshot.owner(a, nested) == null);
    try testing.expect(snapshot.member(nested) == null);
    for ([_][]const u8{ ".venv/tasks/main.yml", "custom-env/tasks/main.yml", "node_modules/tasks/main.yml", "notes.txt" }) |rel| {
        const path = try std.fs.path.join(a, &.{ root, rel });
        try testing.expectEqualStrings(root, snapshot.owner(a, path).?);
        try testing.expect(snapshot.member(path) == null);
    }
    _ = try session.apply(a, .{ .folders_changed = .{ .added = &.{try folderUri(a, tmp.dir, "nested")}, .removed = &.{} } });
    try testing.expectEqualStrings(try tmp.dir.realpathAlloc(a, "nested"), session.snapshot().member(nested).?);
}

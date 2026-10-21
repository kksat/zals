//! Variable-file classification follows vars loads in unsaved buffers
//! (ADR-0045). Whether a map-rooted file outside vars/, group_vars/, and
//! host_vars/ binds variables depends on loads in other files, so it is
//! decided at query time from the Workspace's current documents. Controlled
//! buffers only; fixture files on disk never change.
const std = @import("std");
const lsp = @import("e2e/client.zig");
const anchor = @import("e2e/anchor.zig");
const m = @import("e2e/model.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const play = "playbooks/metadata-names.yml";
const settings = "playbooks/settings/release-metadata.yml";
const compose = "docker-compose.yml";
const galaxy = "ansible_collections/example/rollout/galaxy.yml";
const field_play = "playbooks/field-inputs.yml";
const receiver = "ansible_collections/fixture/inputs/roles/receiver/";

const Session = struct {
    a: Allocator,
    client: lsp.Client,
    resolver: anchor.Resolver,
    fixture: []const u8,

    fn uri(self: *Session, relative: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "file://{s}/{s}", .{ self.fixture, relative });
    }

    fn openDisk(self: *Session, relative: []const u8) ![]const u8 {
        const u = try self.uri(relative);
        try self.client.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = u, .languageId = "yaml", .version = @as(u32, 1), .text = try self.resolver.readText(relative) } });
        return u;
    }

    fn change(self: *Session, u: []const u8, text: []const u8) !void {
        try self.client.notify("textDocument/didChange", .{ .textDocument = .{ .uri = u, .version = @as(u32, 2) }, .contentChanges = &.{.{ .text = text }} });
    }

    fn at(self: *Session, cursor: m.Anchor) !anchor.Cursor {
        return self.resolver.cursor(cursor);
    }

    fn span(self: *Session, path: []const u8, snippet: []const u8) !anchor.Location {
        return self.resolver.location(m.span(path, snippet));
    }

    fn navigate(self: *Session, method: []const u8, origin: anchor.Cursor) ![]anchor.Location {
        return locations(self.a, try self.client.request(method, .{ .textDocument = .{ .uri = origin.uri }, .position = origin.position }));
    }

    fn references(self: *Session, origin: anchor.Cursor, include: bool) ![]anchor.Location {
        const actual = try locations(self.a, try self.client.request("textDocument/references", .{
            .textDocument = .{ .uri = origin.uri },
            .position = origin.position,
            .context = .{ .includeDeclaration = include },
        }));
        std.mem.sort(anchor.Location, actual, {}, lessLocation);
        return actual;
    }

    fn deinit(self: *Session) void {
        self.client.deinit();
    }
};

fn start(a: Allocator, home: []const u8) !Session {
    const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/e2e-workspace");
    const deps = try std.fs.cwd().realpathAlloc(a, "test/dependencies");
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
    var client = try lsp.Client.start(a, binary, fixture, deps, home);
    errdefer client.deinit();
    _ = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = try std.fmt.allocPrint(a, "file://{s}", .{fixture}),
        .capabilities = .{},
        .initializationOptions = .{ .ansible = .{
            .workspace = .{ .rootMarker = "fixture-workspace-root" },
            .python = .{ .venvPath = "" },
            .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
        } },
    });
    try client.notify("initialized", .{});
    try client.waitForIndex();
    return .{ .a = a, .client = client, .resolver = .{ .allocator = a, .fixture = fixture, .deps = deps }, .fixture = fixture };
}

test "removing a vars load in an unsaved playbook unbinds its target outside vars/" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var s = try start(arena.allocator(), try home.dir.realpathAlloc(arena.allocator(), "."));
    defer s.deinit();

    const play_uri = try s.openDisk(play);
    _ = try s.openDisk(settings);
    const key = try s.at(m.cursor(settings, "<plugin_routing>: disabled"));
    const field_key = try s.at(m.cursor(settings, "  <image>: example/app:candidate"));
    const binding = try s.span(settings, "<plugin_routing>: disabled");
    const field_binding = try s.span(settings, "  <image>: example/app:candidate");

    // While the disk playbook loads it, the settings file is a Variable file.
    try expectLocations(&.{binding}, try s.navigate("textDocument/definition", key));
    try expectLocations(&.{field_binding}, try s.navigate("textDocument/definition", field_key));

    try s.change(play_uri,
        \\---
        \\- hosts: localhost
        \\  tasks:
        \\    - ansible.builtin.debug:
        \\        msg: "{{ plugin_routing }} {{ release_window.image }}"
        \\
    );
    // Independently authored UTF-16 coordinates in the buffer above.
    const read: anchor.Location = .{ .uri = play_uri, .range = range(4, 17, 4, 31) };
    const field_read: anchor.Location = .{ .uri = play_uri, .range = range(4, 53, 4, 58) };
    const read_at: anchor.Cursor = .{ .uri = play_uri, .position = .{ .line = 4, .character = 20 } };
    const field_at: anchor.Cursor = .{ .uri = play_uri, .position = .{ .line = 4, .character = 55 } };

    try expectLocations(&.{}, try s.navigate("textDocument/definition", read_at));
    try expectLocations(&.{}, try s.navigate("textDocument/implementation", read_at));
    try expectLocations(&.{read}, try s.references(read_at, true));
    try expectLocations(&.{}, try s.navigate("textDocument/definition", field_at));
    try expectLocations(&.{field_read}, try s.references(field_at, true));
    // Its keys are no longer navigation subjects.
    try expectLocations(&.{}, try s.navigate("textDocument/definition", key));
    try expectLocations(&.{}, try s.references(key, true));
    try expectLocations(&.{}, try s.references(field_key, true));
}

test "adding a vars load in an unsaved playbook makes a Compose file a Variable file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var s = try start(arena.allocator(), try home.dir.realpathAlloc(arena.allocator(), "."));
    defer s.deinit();

    const play_uri = try s.openDisk(play);
    _ = try s.openDisk(compose);
    _ = try s.openDisk(galaxy);
    const compose_key = try s.at(m.cursor(compose, "<version>: \"3.8\""));
    const galaxy_key = try s.at(m.cursor(galaxy, "<version>: 1.0.0"));
    const compose_version = try s.span(compose, "<version>: \"3.8\"");
    const compose_image = try s.span(compose, "<image>: example/app:stable");

    // Unloaded on disk: not a Variable file.
    try expectLocations(&.{}, try s.references(compose_key, true));

    try s.change(play_uri,
        \\---
        \\- hosts: localhost
        \\  vars_files:
        \\    - ../docker-compose.yml
        \\  tasks:
        \\    - ansible.builtin.debug:
        \\        msg: "{{ version }} {{ services.app.image }}"
        \\
    );
    const read: anchor.Location = .{ .uri = play_uri, .range = range(6, 17, 6, 24) };
    const field_read: anchor.Location = .{ .uri = play_uri, .range = range(6, 44, 6, 49) };
    const read_at: anchor.Cursor = .{ .uri = play_uri, .position = .{ .line = 6, .character = 20 } };
    const field_at: anchor.Cursor = .{ .uri = play_uri, .position = .{ .line = 6, .character = 46 } };

    try expectLocations(&.{compose_version}, try s.navigate("textDocument/definition", read_at));
    try expectLocations(&.{compose_version}, try s.navigate("textDocument/implementation", read_at));
    const both = try sorted(s.a, &.{ read, compose_version });
    try expectLocations(both, try s.references(read_at, true));
    try expectLocations(both, try s.references(compose_key, true));
    try expectLocations(&.{read}, try s.references(compose_key, false));
    try expectLocations(&.{compose_image}, try s.navigate("textDocument/definition", field_at));
    try expectLocations(try sorted(s.a, &.{ field_read, compose_image }), try s.references(field_at, true));
    // The load names only Compose; galaxy.yml still binds nothing.
    try expectLocations(&.{}, try s.references(galaxy_key, true));
}

const callee_caller = m.cursor(field_play, "            <region_name>: passed-main-region");
const callee_load = "- name: Unsaved callee load outside its conventional directories\n  include_vars: ../../../../../../playbooks/settings/receiver-values.yml\n";

test "a callee load outside vars/ supplies a passed field implementation from the index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var s = try start(arena.allocator(), try home.dir.realpathAlloc(arena.allocator(), "."));
    defer s.deinit();

    _ = try s.openDisk(field_play);
    const caller = try s.at(callee_caller);
    const loaded = try s.span("playbooks/settings/receiver-values.yml", "    <region_name>: settings-region");
    const vars = try s.span(receiver ++ "vars/main.yml", "    <region_name>: receiver-region-vars");
    const default = try s.span(receiver ++ "defaults/main.yml", "    <region_name>: receiver-region-default");

    // Unloaded on disk, the settings file is not a callee binding, and the
    // Role's map-rooted `templates/settings.yml.j2` never is.
    try expectLocations(&.{ vars, default }, try s.navigate("textDocument/implementation", caller));

    const tasks_uri = try s.openDisk(receiver ++ "tasks/main.yml");
    try s.change(tasks_uri, callee_load);
    // include_vars precedence precedes role vars and defaults; the Role
    // template still binds nothing.
    try expectLocations(&.{ loaded, vars, default }, try s.navigate("textDocument/implementation", caller));
}

test "a callee load outside vars/ supplies a passed field implementation from an unsaved buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var s = try start(arena.allocator(), try home.dir.realpathAlloc(arena.allocator(), "."));
    defer s.deinit();

    _ = try s.openDisk(field_play);
    const caller = try s.at(callee_caller);
    const vars = try s.span(receiver ++ "vars/main.yml", "    <region_name>: receiver-region-vars");
    const default = try s.span(receiver ++ "defaults/main.yml", "    <region_name>: receiver-region-default");
    const tasks_uri = try s.openDisk(receiver ++ "tasks/main.yml");
    const loaded_uri = try s.openDisk("playbooks/settings/receiver-values.yml");
    try s.change(tasks_uri, callee_load);
    try s.change(loaded_uri,
        \\# Unsaved settings outside a vars directory
        \\input_config:
        \\  endpoint:
        \\    region_name: buffer-region
        \\
    );
    const loaded: anchor.Location = .{ .uri = loaded_uri, .range = range(3, 4, 3, 15) };
    // Still no binding from the Role's `templates/settings.yml.j2`.
    try expectLocations(&.{ loaded, vars, default }, try s.navigate("textDocument/implementation", caller));
}

fn range(start_line: u32, start_character: u32, end_line: u32, end_character: u32) anchor.Range {
    return .{ .start = .{ .line = start_line, .character = start_character }, .end = .{ .line = end_line, .character = end_character } };
}

fn sorted(a: Allocator, items: []const anchor.Location) ![]anchor.Location {
    const out = try a.dupe(anchor.Location, items);
    std.mem.sort(anchor.Location, out, {}, lessLocation);
    return out;
}

fn locations(a: Allocator, value: Value) ![]anchor.Location {
    if (value == .null) return &.{};
    if (value == .array) {
        const out = try a.alloc(anchor.Location, value.array.items.len);
        for (value.array.items, 0..) |item, i| out[i] = try std.json.parseFromValueLeaky(anchor.Location, a, item, .{});
        return out;
    }
    const out = try a.alloc(anchor.Location, 1);
    out[0] = try std.json.parseFromValueLeaky(anchor.Location, a, value, .{});
    return out;
}

fn expectLocations(expected: []const anchor.Location, actual: []const anchor.Location) !void {
    if (expected.len != actual.len) {
        std.debug.print("expected {d} locations, got {d}:\n", .{ expected.len, actual.len });
        for (actual) |loc| std.debug.print("  {s} {d}:{d}-{d}:{d}\n", .{ loc.uri, loc.range.start.line, loc.range.start.character, loc.range.end.line, loc.range.end.character });
    }
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| {
        try std.testing.expectEqualStrings(left.uri, right.uri);
        try std.testing.expectEqualDeep(left.range, right.range);
    }
}

fn lessLocation(_: void, left: anchor.Location, right: anchor.Location) bool {
    const order = std.mem.order(u8, left.uri, right.uri);
    if (order != .eq) return order == .lt;
    if (left.range.start.line != right.range.start.line) return left.range.start.line < right.range.start.line;
    if (left.range.start.character != right.range.start.character) return left.range.start.character < right.range.start.character;
    if (left.range.end.line != right.range.end.line) return left.range.end.line < right.range.end.line;
    return left.range.end.character < right.range.end.character;
}

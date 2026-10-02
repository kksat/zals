//! Black-box selected-venv contracts. Ordinary static fixtures, explicit
//! expected files, and stdio LSP only: no service imports or fixture edits.
const std = @import("std");
const lsp = @import("e2e/client.zig");
const anchor = @import("e2e/anchor.zig");
const model = @import("e2e/model.zig");
const Value = std.json.Value;

const Session = struct {
    arena: *std.heap.ArenaAllocator,
    home: std.testing.TmpDir,
    client: lsp.Client,
    resolver: anchor.Resolver,

    fn start(venv: []const u8, options: lsp.Client.StartOptions) !Session {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        errdefer std.testing.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/selected-venv");
        const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
        var home = std.testing.tmpDir(.{});
        errdefer home.cleanup();
        var client = try lsp.Client.startWithOptions(a, binary, fixture, fixture, try home.dir.realpathAlloc(a, "."), options);
        errdefer client.deinit();
        _ = try client.request("initialize", .{
            .processId = @as(?i64, null),
            .rootUri = try std.fmt.allocPrint(a, "file://{s}", .{fixture}),
            .capabilities = .{},
            .initializationOptions = .{ .ansible = .{
                .workspace = .{ .rootMarker = "fixture-workspace-root" },
                .python = .{ .venvPath = venv },
                .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
            } },
        });
        try client.notify("initialized", .{});
        try client.waitForIndex();
        return .{ .arena = arena, .home = home, .client = client, .resolver = .{ .allocator = a, .fixture = fixture, .deps = fixture } };
    }

    fn deinit(self: *Session) void {
        self.client.deinit();
        self.home.cleanup();
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }

    fn at(self: *Session, method: []const u8, from: model.Anchor) !Value {
        const source = try self.resolver.cursor(from);
        try self.client.notify("textDocument/didOpen", .{ .textDocument = .{
            .uri = source.uri,
            .languageId = "ansible",
            .version = @as(u32, 1),
            .text = try self.resolver.readText(from.path),
        } });
        return self.client.request(method, .{ .textDocument = .{ .uri = source.uri }, .position = source.position });
    }

    fn definition(self: *Session, from: model.Anchor, expected_file: []const u8) !void {
        const result = try self.at("textDocument/definition", from);
        const expected = try self.resolver.location(model.fileStart(expected_file));
        const actual = if (result == .array and result.array.items.len == 1) result.array.items[0] else result;
        const uri = lsp.field(actual, "uri") orelse {
            std.debug.print("Expected definition {s}, got {s}\n", .{ expected_file, @tagName(result) });
            return error.MissingDefinition;
        };
        try std.testing.expectEqualStrings(expected.uri, uri.string);
        const range = lsp.field(actual, "range") orelse return error.MissingRange;
        for ([_][]const u8{ "start", "end" }) |edge| {
            const pos = lsp.field(range, edge) orelse return error.MissingPosition;
            try std.testing.expectEqual(@as(i64, 0), (lsp.field(pos, "line") orelse return error.MissingLine).integer);
            try std.testing.expectEqual(@as(i64, 0), (lsp.field(pos, "character") orelse return error.MissingCharacter).integer);
        }
    }

    fn missing(self: *Session, from: model.Anchor) !void {
        const result = try self.at("textDocument/definition", from);
        try std.testing.expect(result == .null or (result == .array and result.array.items.len == 0));
    }

    fn hover(self: *Session, from: model.Anchor, expected: []const u8) !void {
        const result = try self.at("textDocument/hover", from);
        const contents = lsp.field(result, "contents") orelse return error.MissingHover;
        const value = lsp.field(contents, "value") orelse return error.MissingHoverText;
        if (std.mem.indexOf(u8, value.string, expected) == null) {
            std.debug.print("Expected hover containing {s}, got {s}\n", .{ expected, value.string });
            return error.WrongHover;
        }
    }
};

test "selected venv includes every POSIX site-packages alongside its root" {
    var session = try Session.start(".venv", .{});
    defer session.deinit();
    try session.definition(model.cursor("layouts.yml", "    - <fixture.posix>\n"), ".venv/lib/python3.12/site-packages/ansible_collections/fixture/posix/galaxy.yml");
    try session.definition(model.cursor("layouts.yml", "    - <fixture.posix_next>"), ".venv/lib/python3.13/site-packages/ansible_collections/fixture/posix_next/galaxy.yml");
}

test "selected Windows venv includes root before site-packages" {
    var session = try Session.start("windows-env", .{});
    defer session.deinit();
    try session.definition(model.cursor("layouts.yml", "    - <fixture.windows>"), "windows-env/Lib/site-packages/ansible_collections/fixture/windows/galaxy.yml");
    try session.definition(model.cursor("site.yml", "    - <fixture.root>"), "windows-env/ansible_collections/fixture/root/galaxy.yml");
}

test "selected venv root collection definition and hover" {
    var session = try Session.start(".venv", .{});
    defer session.deinit();
    const from = model.cursor("site.yml", "    - <fixture.root>");
    try session.definition(from, ".venv/ansible_collections/fixture/root/galaxy.yml");
    try session.hover(from, "# Selected root collection");
    try session.missing(model.cursor("selection.yml", "    - <fixture.unselected>"));
}

// These characterize preserved selection/precedence contracts (already green),
// rather than pretending they reproduce another defect.
test "venv selection, empty disable, CLI override, and path precedence are preserved" {
    const from = model.cursor("selection.yml", "    - <fixture.root>");
    {
        var s = try Session.start("other-env", .{});
        defer s.deinit();
        try s.definition(from, "other-env/ansible_collections/fixture/root/galaxy.yml");
        try s.missing(model.cursor("layouts.yml", "    - <fixture.windows>"));
    }
    {
        var s = try Session.start(".venv", .{ .venv_override = "other-env" });
        defer s.deinit();
        try s.definition(from, "other-env/ansible_collections/fixture/root/galaxy.yml");
    }
    {
        var s = try Session.start("", .{});
        defer s.deinit();
        try s.missing(model.cursor("layouts.yml", "    - <fixture.windows>"));
        try s.missing(model.cursor("selection.yml", "    - <fixture.unselected>"));
    }
    {
        var s = try Session.start(".venv", .{ .collections_path = "", .use_fixture_config = false });
        defer s.deinit();
        try s.definition(from, "configured/ansible_collections/fixture/root/galaxy.yml");
        try s.definition(model.cursor("adjacent/site.yml", "    - <fixture.root>"), "adjacent/collections/ansible_collections/fixture/root/galaxy.yml");
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const absolute_venv = try std.fs.cwd().realpathAlloc(arena.allocator(), "test/fixtures/selected-venv/other-env");
        var s = try Session.start(absolute_venv, .{});
        defer s.deinit();
        try s.definition(from, "other-env/ansible_collections/fixture/root/galaxy.yml");
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const env_path = try std.fs.cwd().realpathAlloc(arena.allocator(), "test/fixtures/selected-venv/adjacent/collections");
        var s = try Session.start(".venv", .{ .collections_path = env_path });
        defer s.deinit();
        try s.definition(from, "adjacent/collections/ansible_collections/fixture/root/galaxy.yml");
    }
}

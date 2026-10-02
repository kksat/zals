//! Workspace collection member contracts through real stdio LSP requests.
//! Oracles name every expected symbol and target, never enumerate the fixture.
const std = @import("std");
const lsp = @import("e2e/client.zig");
const anchor = @import("e2e/anchor.zig");
const m = @import("e2e/model.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Session = struct {
    arena: *std.heap.ArenaAllocator,
    home: std.testing.TmpDir,
    client: lsp.Client,
    resolver: anchor.Resolver,

    fn start() !Session {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        errdefer std.testing.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/collection-symbols-workspace");
        const deps = try std.fs.cwd().realpathAlloc(a, "test/dependencies");
        const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
        var home = std.testing.tmpDir(.{});
        errdefer home.cleanup();
        const home_path = try home.dir.realpathAlloc(a, ".");
        var client = try lsp.Client.start(a, binary, fixture, deps, home_path);
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
        return .{
            .arena = arena,
            .home = home,
            .client = client,
            .resolver = .{ .allocator = a, .fixture = fixture, .deps = deps },
        };
    }

    fn deinit(self: *Session) void {
        self.client.deinit();
        self.home.cleanup();
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }

    fn navigation(self: *Session, method: []const u8, from: m.Anchor, expected: []const []const u8) !void {
        const source = try self.resolver.cursor(from);
        try self.client.notify("textDocument/didOpen", .{ .textDocument = .{
            .uri = source.uri,
            .languageId = "yaml",
            .version = @as(u32, 1),
            .text = try self.resolver.readText(from.path),
        } });
        try self.navigationAt(method, source, expected);
    }

    fn navigationAt(self: *Session, method: []const u8, source: anchor.Cursor, expected: []const []const u8) !void {
        const result = try self.client.request(method, .{
            .textDocument = .{ .uri = source.uri },
            .position = source.position,
        });
        const items: []const Value = switch (result) {
            .null => &.{},
            .array => result.array.items,
            .object => &.{result},
            else => return error.InvalidNavigationResult,
        };
        if (items.len != expected.len) {
            std.debug.print("{s}: expected {d} locations, got {s}\n", .{
                method, expected.len, try std.json.Stringify.valueAlloc(self.resolver.allocator, result, .{}),
            });
            return error.UnexpectedLocations;
        }
        for (items, expected) |item, path| {
            const location = try self.resolver.location(.{ .file_start = path });
            try std.testing.expectEqualStrings(location.uri, try stringField(item, "uri"));
            const range = lsp.field(item, "range") orelse return error.MissingRange;
            try std.testing.expect(try zeroPosition(lsp.field(range, "start") orelse return error.MissingStart));
            try std.testing.expect(try zeroPosition(lsp.field(range, "end") orelse return error.MissingEnd));
        }
    }

    fn symbols(self: *Session, query: []const u8, expected: []const ExpectedSymbol) !void {
        const result = try self.client.request("workspace/symbol", .{ .query = query });
        if (result != .array) return error.InvalidSymbolResult;
        if (result.array.items.len != expected.len) {
            std.debug.print("Query '{s}': expected {d} symbols, got {d}: {s}\n", .{
                query,                                                                   expected.len, result.array.items.len,
                try std.json.Stringify.valueAlloc(self.resolver.allocator, result, .{}),
            });
            return error.UnexpectedSymbols;
        }
        // Order-independent, preserving duplicates by consuming each match.
        const used = try self.resolver.allocator.alloc(bool, expected.len);
        @memset(used, false);
        for (expected) |symbol| {
            const location = try self.resolver.location(.{ .file_start = symbol.path });
            var matched = false;
            for (result.array.items, 0..) |actual, i| {
                if (used[i]) continue;
                if (!try symbolEqual(actual, symbol, location)) continue;
                used[i] = true;
                matched = true;
                break;
            }
            if (!matched) {
                std.debug.print("Query '{s}': missing {s} in {s} -> {s}\nActual: {s}\n", .{
                    query,                                                                   symbol.name, symbol.container, symbol.path,
                    try std.json.Stringify.valueAlloc(self.resolver.allocator, result, .{}),
                });
                return error.MissingExpectedSymbol;
            }
        }
    }
};

const ExpectedSymbol = struct {
    name: []const u8,
    kind: i64,
    container: []const u8 = "",
    path: []const u8,
};

fn stringField(value: Value, name: []const u8) ![]const u8 {
    const field = lsp.field(value, name) orelse return error.MissingField;
    if (field != .string) return error.InvalidStringField;
    return field.string;
}

fn symbolEqual(actual: Value, expected: ExpectedSymbol, location: anchor.Location) !bool {
    const name = try stringField(actual, "name");
    const kind = lsp.field(actual, "kind") orelse return error.MissingKind;
    if (kind != .integer) return error.InvalidKind;
    const container = if (lsp.field(actual, "containerName")) |_| try stringField(actual, "containerName") else "";
    const loc = lsp.field(actual, "location") orelse return error.MissingLocation;
    const uri = try stringField(loc, "uri");
    // Absolute file URIs are required, and every actual target must exist.
    if (!std.mem.startsWith(u8, uri, "file:///")) return error.NonAbsoluteFileUri;
    const target = try std.fs.openFileAbsolute(uri["file://".len..], .{});
    target.close();
    const range = lsp.field(loc, "range") orelse return error.MissingRange;
    const start = lsp.field(range, "start") orelse return error.MissingStart;
    const end = lsp.field(range, "end") orelse return error.MissingEnd;
    return std.mem.eql(u8, name, expected.name) and kind.integer == expected.kind and
        std.mem.eql(u8, container, expected.container) and std.mem.eql(u8, uri, location.uri) and
        try zeroPosition(start) and try zeroPosition(end);
}

fn zeroPosition(value: Value) !bool {
    const line = lsp.field(value, "line") orelse return error.MissingLine;
    const character = lsp.field(value, "character") orelse return error.MissingCharacter;
    if (line != .integer or character != .integer) return error.InvalidPosition;
    return line.integer == 0 and character.integer == 0;
}

test "FQCN role navigation resolves dotted metadata collection roots" {
    var session = try Session.start();
    defer session.deinit();
    const source = m.cursor("site.yml", "- <contract.dotted.dotted_role>");
    const targets = &.{"ansible_collections/contract.dotted/roles/dotted_role/tasks/main.yml"};
    try session.navigation("textDocument/definition", source, targets);
    try session.navigation("textDocument/implementation", source, targets);
}

test "metadata collection layouts share role identity and containers" {
    var session = try Session.start();
    defer session.deinit();
    const cases = [_]struct { name: []const u8, target: []const u8 }{
        .{ .name = "contract.standard.standard_role", .target = "ansible_collections/contract/standard/roles/standard_role/tasks/main.yml" },
        .{ .name = "contract.arbitrary.arbitrary_role", .target = "ansible_collections/unusual/deep/content/roles/arbitrary_role/tasks/main.yaml" },
        .{ .name = "contract.root.root_role", .target = "roles/root_role/tasks/main.yml" },
        .{ .name = "dotted_role", .target = "ansible_collections/contract.dotted/roles/dotted_role/tasks/main.yml" },
    };
    for (cases) |case| {
        const snippet = try std.fmt.allocPrint(session.resolver.allocator, "- <{s}>", .{case.name});
        const from = m.cursor("site.yml", snippet);
        try session.navigation("textDocument/definition", from, &.{case.target});
        try session.navigation("textDocument/implementation", from, &.{case.target});
    }
    try session.symbols("_role", &.{
        .{ .name = "standard_role", .kind = 2, .container = "contract.standard", .path = "ansible_collections/contract/standard/roles/standard_role/tasks/main.yml" },
        .{ .name = "dotted_role", .kind = 2, .container = "contract.dotted", .path = "ansible_collections/contract.dotted/roles/dotted_role/tasks/main.yml" },
        .{ .name = "arbitrary_role", .kind = 2, .container = "contract.arbitrary", .path = "ansible_collections/unusual/deep/content/roles/arbitrary_role/tasks/main.yaml" },
        .{ .name = "root_role", .kind = 2, .container = "contract.root", .path = "roles/root_role/tasks/main.yml" },
    });
}

test "collection definitions target real metadata in every supported layout" {
    var session = try Session.start();
    defer session.deinit();
    try session.navigation("textDocument/definition", m.cursor("site.yml", "- <contract.standard>.standard_role"), &.{"ansible_collections/contract/standard/galaxy.yml"});
    try session.navigation("textDocument/definition", m.cursor("site.yml", "- <contract.dotted>.dotted_role"), &.{"ansible_collections/contract.dotted/galaxy.yml"});
    try session.navigation("textDocument/definition", m.cursor("site.yml", "- <contract.arbitrary>.arbitrary_role"), &.{"ansible_collections/unusual/deep/content/galaxy.yaml"});
    try session.navigation("textDocument/definition", m.cursor("site.yml", "- <contract.root>.root_role"), &.{"galaxy.yaml"});
}

test "role symbols retain short names but match their collection-qualified identity" {
    var session = try Session.start();
    defer session.deinit();
    try session.symbols("CoNtRaCt.DoTtEd.DoTtEd_RoLe", &.{
        .{ .name = "dotted_role", .kind = 2, .container = "contract.dotted", .path = "ansible_collections/contract.dotted/roles/dotted_role/tasks/main.yml" },
    });
}

test "metadata outside collection roots and excluded Workspaces is not a Workspace collection" {
    var session = try Session.start();
    defer session.deinit();
    try session.symbols("noncollection.decoy", &.{});
    try session.symbols("excluded.", &.{});
    try session.symbols("fixture.metrics", &.{});
    try session.symbols("fixture.notes", &.{});
}

test "unsaved metadata edits update collection symbols and FQCN role identity" {
    var session = try Session.start();
    defer session.deinit();
    const metadata = try session.resolver.location(.{ .file_start = "galaxy.yaml" });
    try session.client.notify("textDocument/didOpen", .{ .textDocument = .{
        .uri = metadata.uri,
        .languageId = "yaml",
        .version = @as(u32, 1),
        .text = try session.resolver.readText("galaxy.yaml"),
    } });
    try session.client.notify("textDocument/didChange", .{
        .textDocument = .{ .uri = metadata.uri, .version = @as(u32, 2) },
        .contentChanges = &.{.{ .text = "namespace: contract\nname: edit\nversion: 1.0.0\n" }},
    });
    try session.symbols("contract.root", &.{});
    try session.symbols("contract.edit", &.{
        .{ .name = "contract.edit", .kind = 4, .path = "galaxy.yaml" },
        .{ .name = "root_role", .kind = 2, .container = "contract.edit", .path = "roles/root_role/tasks/main.yml" },
    });
    const from = m.cursor("site.yml", "- <contract.root.root_role>");
    try session.navigation("textDocument/implementation", from, &.{});
    const source = try session.resolver.cursor(from);
    const edited = try std.mem.replaceOwned(u8, session.resolver.allocator, try session.resolver.readText("site.yml"), "contract.root.root_role", "contract.edit.root_role");
    try session.client.notify("textDocument/didChange", .{
        .textDocument = .{ .uri = source.uri, .version = @as(u32, 2) },
        .contentChanges = &.{.{ .text = edited }},
    });
    try session.navigationAt("textDocument/definition", source, &.{"roles/root_role/tasks/main.yml"});
    try session.navigationAt("textDocument/implementation", source, &.{"roles/root_role/tasks/main.yml"});
}

test "Workspace root collection symbol targets its actual yaml metadata" {
    var session = try Session.start();
    defer session.deinit();
    try session.symbols("contract.root", &.{
        .{ .name = "contract.root", .kind = 4, .path = "galaxy.yaml" },
        .{ .name = "root_role", .kind = 2, .container = "contract.root", .path = "roles/root_role/tasks/main.yml" },
    });
}

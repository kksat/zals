//! End-to-end semantic navigation contract. A single zals stdio process sees
//! the checked-in, unmodified Ansible Workspace. Expected results come solely
//! from named cases; marker helpers compute positions, not answers.

const std = @import("std");
const m = @import("e2e/model.zig");
const cases = @import("e2e/cases.zig");
const anchor = @import("e2e/anchor.zig");
const lsp = @import("e2e/client.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

// Import helper tests without spawning a second server.
comptime {
    _ = @import("e2e/anchor.zig");
}

test "navigation contracts across a static Ansible Workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/e2e-workspace");
    const deps = try std.fs.cwd().realpathAlloc(a, "test/dependencies");
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
    var temp_home = std.testing.tmpDir(.{});
    defer temp_home.cleanup();
    const home = try temp_home.dir.realpathAlloc(a, ".");

    var client = try lsp.Client.start(a, binary, fixture, deps, home);
    defer client.deinit();
    const root_uri = try std.fmt.allocPrint(a, "file://{s}", .{fixture});
    const init_result = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = root_uri,
        .capabilities = .{}, // No position encodings advertised: default UTF-16.
        .initializationOptions = .{ .ansible = .{
            .workspace = .{ .rootMarker = "fixture-workspace-root" },
            .python = .{ .venvPath = "" },
            .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
        } },
    });
    try assertCapabilities(init_result);
    try client.notify("initialized", .{});
    try client.waitForIndex();

    const resolver: anchor.Resolver = .{ .allocator = a, .fixture = fixture, .deps = deps };
    var opened = std.StringHashMap(void).init(a);
    var failed: usize = 0;
    for (cases.all) |case| {
        const passed = runCase(a, &client, resolver, &opened, case) catch |err| {
            std.debug.print("FAIL {s}: {s}\n", .{ case.name, @errorName(err) });
            failed += 1;
            continue;
        };
        if (!passed) failed += 1;
    }
    std.debug.print("Navigation E2E: {d} cases, {d} failures\n", .{ cases.all.len, failed });
    try std.testing.expectEqual(@as(usize, 0), failed);
}

fn assertCapabilities(result: Value) !void {
    const caps = lsp.field(result, "capabilities") orelse return error.MissingCapabilities;
    for ([_][]const u8{ "definitionProvider", "implementationProvider", "referencesProvider" }) |name| {
        const value = lsp.field(caps, name) orelse {
            std.debug.print("Missing navigation capability: {s}\n", .{name});
            return error.MissingCapability;
        };
        if (value != .bool or !value.bool) return error.DisabledNavigationCapability;
    }
    // An absent positionEncoding also means UTF-16 by the LSP protocol.
    if (lsp.field(caps, "positionEncoding")) |encoding| {
        if (encoding != .string or !std.mem.eql(u8, encoding.string, "utf-16")) {
            return error.UnexpectedPositionEncoding;
        }
    }
}

fn runCase(a: Allocator, client: *lsp.Client, resolver: anchor.Resolver, opened: *std.StringHashMap(void), case: m.Case) !bool {
    const source = try resolver.cursor(case.from);
    // LSP navigation is requested from an open document. Each source is
    // opened once with its unchanged on-disk contents; there are no edits or
    // file-watcher events in this suite.
    if (!opened.contains(case.from.path)) {
        try client.notify("textDocument/didOpen", .{ .textDocument = .{
            .uri = source.uri,
            .languageId = if (std.mem.endsWith(u8, case.from.path, ".j2")) "jinja2" else "yaml",
            .version = @as(u32, 1),
            .text = try resolver.readText(case.from.path),
        } });
        try opened.put(case.from.path, {});
    }
    const document = .{ .uri = source.uri };
    const result = switch (case.method) {
        .references => try client.request("textDocument/references", .{
            .textDocument = document,
            .position = source.position,
            .context = .{ .includeDeclaration = case.include_declaration },
        }),
        .definition => try client.request("textDocument/definition", .{
            .textDocument = document,
            .position = source.position,
        }),
        .implementation => try client.request("textDocument/implementation", .{
            .textDocument = document,
            .position = source.position,
        }),
    };
    const actual = try parseLocations(a, result);
    const expected = try a.alloc(anchor.Location, case.expected.len);
    for (case.expected, 0..) |location, i| expected[i] = try resolver.location(location);
    if (case.method == .references) {
        std.mem.sort(anchor.Location, actual, {}, locationLessThan);
        std.mem.sort(anchor.Location, expected, {}, locationLessThan);
    }
    if (locationsEqual(actual, expected)) return true;

    std.debug.print("FAIL {s} ({s}, includeDeclaration={}):\n", .{
        case.name, @tagName(case.method), case.include_declaration,
    });
    std.debug.print("  expected ({d}):\n", .{expected.len});
    for (expected) |location| printLocation(resolver, location);
    std.debug.print("  actual ({d}):\n", .{actual.len});
    for (actual) |location| printLocation(resolver, location);
    return false;
}

fn parseLocations(a: Allocator, result: Value) ![]anchor.Location {
    switch (result) {
        .null => return &.{},
        .array => |items| {
            const locations = try a.alloc(anchor.Location, items.items.len);
            for (items.items, 0..) |item, i| locations[i] = try parseLocation(item);
            return locations;
        },
        .object => {
            const locations = try a.alloc(anchor.Location, 1);
            locations[0] = try parseLocation(result);
            return locations;
        },
        else => return error.InvalidLocationResult,
    }
}

fn parseLocation(value: Value) !anchor.Location {
    const uri = lsp.field(value, "uri") orelse return error.MissingLocationUri;
    if (uri != .string) return error.InvalidLocationUri;
    const range = lsp.field(value, "range") orelse return error.MissingLocationRange;
    return .{ .uri = uri.string, .range = .{
        .start = try parsePosition(lsp.field(range, "start") orelse return error.MissingRangeStart),
        .end = try parsePosition(lsp.field(range, "end") orelse return error.MissingRangeEnd),
    } };
}

fn parsePosition(value: Value) !anchor.Position {
    const line = lsp.field(value, "line") orelse return error.MissingLine;
    const character = lsp.field(value, "character") orelse return error.MissingCharacter;
    if (line != .integer or character != .integer) return error.InvalidPosition;
    return .{
        .line = std.math.cast(u32, line.integer) orelse return error.InvalidPosition,
        .character = std.math.cast(u32, character.integer) orelse return error.InvalidPosition,
    };
}

fn locationsEqual(left: []const anchor.Location, right: []const anchor.Location) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (!std.mem.eql(u8, a.uri, b.uri) or
            a.range.start.line != b.range.start.line or
            a.range.start.character != b.range.start.character or
            a.range.end.line != b.range.end.line or
            a.range.end.character != b.range.end.character) return false;
    }
    return true;
}

fn locationLessThan(_: void, a: anchor.Location, b: anchor.Location) bool {
    const order = std.mem.order(u8, a.uri, b.uri);
    if (order != .eq) return order == .lt;
    if (a.range.start.line != b.range.start.line) return a.range.start.line < b.range.start.line;
    if (a.range.start.character != b.range.start.character) return a.range.start.character < b.range.start.character;
    if (a.range.end.line != b.range.end.line) return a.range.end.line < b.range.end.line;
    return a.range.end.character < b.range.end.character;
}

fn printLocation(resolver: anchor.Resolver, location: anchor.Location) void {
    // Paths are shown relative to the Workspace or the configured dependency.
    const uri = location.uri;
    const fixture_prefix = std.fmt.allocPrint(resolver.allocator, "file://{s}/", .{resolver.fixture}) catch unreachable;
    const deps_prefix = std.fmt.allocPrint(resolver.allocator, "file://{s}/", .{resolver.deps}) catch unreachable;
    const display = if (std.mem.startsWith(u8, uri, fixture_prefix)) uri[fixture_prefix.len..] else if (std.mem.startsWith(u8, uri, deps_prefix)) uri[deps_prefix.len..] else uri;
    std.debug.print("    {s} {d}:{d}–{d}:{d}\n", .{
        display,                 location.range.start.line,    location.range.start.character,
        location.range.end.line, location.range.end.character,
    });
}

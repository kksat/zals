//! Authored lexical-boundary contracts over a real, read-only stdio LSP session.
//! Imports are test helpers only; no production seam or generated oracle.
const std = @import("std");
const m = @import("e2e/model.zig");
const anchor = @import("e2e/anchor.zig");
const lsp = @import("e2e/client.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const defaults = "roles/boundaries/defaults/main.yml";
const tasks = "roles/boundaries/tasks/main.yml";
const unrelated = "roles/unrelated/tasks/main.yml";

const raw_reads: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 before {{ data.<boundary_field> }}"),
    m.span(tasks, "after {{ data['<boundary_field>'] }}"),
    m.span(tasks, "resumed {{ data.<boundary_field> }}"),
    m.span(tasks, "}}\" ~ data.<boundary_field> }}"),
    m.span(unrelated, "{{ other.<boundary_field> }}"),
    m.span(tasks, "kept {{ data['<boundary_field>'] }}"),
};
const raw_with_declarations: []const m.ExpectedLocation = &.{
    m.span(tasks, "🛰 before {{ data.<boundary_field> }}"),
    m.span(tasks, "after {{ data['<boundary_field>'] }}"),
    m.span(tasks, "resumed {{ data.<boundary_field> }}"),
    m.span(tasks, "}}\" ~ data.<boundary_field> }}"),
    m.span(unrelated, "{{ other.<boundary_field> }}"),
    m.span(tasks, "kept {{ data['<boundary_field>'] }}"),
    m.span(defaults, "  <boundary_field>: boundary-value"),
};
const raw_targets: []const m.ExpectedLocation = &.{m.span(defaults, "  <boundary_field>: boundary-value")};
const raw_root_reads: []const m.ExpectedLocation = &.{m.span(tasks, "tail {{ <boundary_root> }}")};
const raw_root_with_declarations: []const m.ExpectedLocation = &.{
    m.span(tasks, "tail {{ <boundary_root> }}"),
    m.span(defaults, "\n<boundary_root>: root-value"),
};
const raw_root_targets: []const m.ExpectedLocation = &.{m.span(defaults, "\n<boundary_root>: root-value")};

test "stdio raw blocks exclude literal fields roots and markup while later reads remain navigable" {
    var session = try Session.start();
    defer session.deinit();
    try session.group(&.{
        m.cursor(tasks, "🛰 before {{ data.<boundary_field> }}"),
        m.cursor(tasks, "after {{ data['<boundary_field>'] }}"),
        m.cursor(tasks, "resumed {{ data.<boundary_field> }}"),
        m.cursor(tasks, "}}\" ~ data.<boundary_field> }}"),
        m.cursor(unrelated, "{{ other.<boundary_field> }}"),
        m.cursor(tasks, "kept {{ data['<boundary_field>'] }}"),
        m.cursor(defaults, "  <boundary_field>: boundary-value"),
    }, raw_reads, raw_with_declarations, raw_targets, &.{ "**Variable field** `boundary_field`", "`boundary-value`" }, &.{"**Variable**"});
    try session.group(&.{
        m.cursor(tasks, "tail {{ <boundary_root> }}"),
        m.cursor(defaults, "\n<boundary_root>: root-value"),
    }, raw_root_reads, raw_root_with_declarations, raw_root_targets, &.{ "**Variable** `boundary_root`", "`root-value`" }, &.{"**Variable field**"});
    try session.negatives(&.{
        m.cursor(tasks, "\n      {% <raw> %}{{ dummy.boundary_field"),
        m.cursor(tasks, "boundary_root }}{% <endraw> %} after"),
        m.cursor(tasks, "🛰 {%- <raw> -%}"),
        m.cursor(tasks, "{%- <endraw> -%} resumed"),
        m.cursor(tasks, "\n      {% raw %}{{ dummy.<boundary_field> }}"),
        m.cursor(tasks, "\n      {% raw %}{{ <dummy>.boundary_field }}"),
        m.cursor(tasks, "{% raw %}{{ dummy.boundary_field }} {{ <boundary_root> }}"),
        m.cursor(tasks, "🛰 {%- raw -%}{{ dummy[\"<boundary_field>\"] }}"),
        m.cursor(tasks, "🛰 {%- raw -%}{{ <dummy>[\"boundary_field\"] }}"),
        m.cursor(tasks, "dummy[\"boundary_field\"] }} {{ <boundary_root> }}"),
        m.cursor(tasks, "unclosed ' {# {{ dummy.<boundary_field> }}"),
        m.cursor(tasks, "unclosed ' {# {{ <dummy>.boundary_field }}"),
        m.cursor(tasks, "{% set ns.<boundary_field> = dummy"),
        m.cursor(tasks, "{% set <ns>.boundary_field = dummy"),
        m.cursor(tasks, "ns.boundary_field = dummy.<boundary_field> %}"),
        m.cursor(tasks, "ns.boundary_field = <dummy>.boundary_field %}"),
        m.cursor(tasks, "quoted {{ \"{% raw %}{{ dummy.<boundary_field> }}"),
        m.cursor(tasks, "quoted {{ \"{% raw %}{{ <dummy>.boundary_field }}"),
        m.cursor(tasks, "preserved-raw {%+ <raw> %}"),
        m.cursor(tasks, "{%+ <endraw> +%} kept"),
        m.cursor(tasks, "preserved-raw {%+ raw %}{{ dummy.<boundary_field> }}"),
        m.cursor(tasks, "preserved-raw {%+ raw %}{{ <dummy>.boundary_field }}"),
        m.cursor(tasks, "boundary_field }} {{ <boundary_root> }}{%+ endraw"),
    });
    try session.finish();
}

const assignments = "roles/boundaries/tasks/assignments.yml";
const unrelated_assignments = "roles/unrelated/tasks/assignments.yml";
const assignment_reads: []const m.ExpectedLocation = &.{
    m.span(assignments, "🛰 same-name {% set ns.region = other.<region> %}"),
    m.span(assignments, "single-subscript {% set ns.region = other['<region>'] %}"),
    m.span(assignments, "trimmed {%- set ns.region = other[\"<region>\"] -%}"),
    m.span(assignments, "selector {% set ns.region = other[chooser.<region>].region %}"),
    m.span(assignments, "selector {% set ns.region = other[chooser.region].<region> %}"),
    m.span(assignments, "named-selector {% set ns.region = other[chooser.selector].<region> %}"),
    m.span(assignments, "capture {% set ns.region %}{{ other.<region> }}"),
    m.span(assignments, "capture-filter {% set ns.region | acme.tools.apply(other.<region>)"),
    m.span(unrelated_assignments, "{{ unrelated.<region> }}"),
    m.span(assignments, "preserved-set {%+ set ns.region = other.<region> +%}"),
};
const assignments_with_declarations: []const m.ExpectedLocation = &.{
    m.span(assignments, "🛰 same-name {% set ns.region = other.<region> %}"),
    m.span(assignments, "single-subscript {% set ns.region = other['<region>'] %}"),
    m.span(assignments, "trimmed {%- set ns.region = other[\"<region>\"] -%}"),
    m.span(assignments, "selector {% set ns.region = other[chooser.<region>].region %}"),
    m.span(assignments, "selector {% set ns.region = other[chooser.region].<region> %}"),
    m.span(assignments, "named-selector {% set ns.region = other[chooser.selector].<region> %}"),
    m.span(assignments, "capture {% set ns.region %}{{ other.<region> }}"),
    m.span(assignments, "capture-filter {% set ns.region | acme.tools.apply(other.<region>)"),
    m.span(unrelated_assignments, "{{ unrelated.<region> }}"),
    m.span(assignments, "preserved-set {%+ set ns.region = other.<region> +%}"),
    m.span(defaults, "  <region>: region-value"),
};
const assignment_targets: []const m.ExpectedLocation = &.{m.span(defaults, "  <region>: region-value")};
const selector_reads: []const m.ExpectedLocation = &.{
    m.span(assignments, "other[chooser.<selector>].region"),
    m.span(unrelated_assignments, "{{ unrelated.<selector> }}"),
};
const selectors_with_declarations: []const m.ExpectedLocation = &.{
    m.span(assignments, "other[chooser.<selector>].region"),
    m.span(unrelated_assignments, "{{ unrelated.<selector> }}"),
    m.span(defaults, "  <selector>: selector-value"),
};
const selector_targets: []const m.ExpectedLocation = &.{m.span(defaults, "  <selector>: selector-value")};
const region_root_reads: []const m.ExpectedLocation = &.{m.span(assignments, "root-read {{ <region> }}")};
const region_roots_with_declarations: []const m.ExpectedLocation = &.{
    m.span(assignments, "root-read {{ <region> }}"),
    m.span(defaults, "\n<region>: separate-root-region"),
};
const region_root_targets: []const m.ExpectedLocation = &.{m.span(defaults, "\n<region>: separate-root-region")};
const selector_root_reads: []const m.ExpectedLocation = &.{m.span(assignments, "root-selector {{ <selector> }}")};
const selector_roots_with_declarations: []const m.ExpectedLocation = &.{
    m.span(assignments, "root-selector {{ <selector> }}"),
    m.span(defaults, "\n<selector>: separate-root-selector"),
};
const selector_root_targets: []const m.ExpectedLocation = &.{m.span(defaults, "\n<selector>: separate-root-selector")};

test "stdio set field targets are not reads while RHS fields and subscript selectors join their ordinary groups" {
    var session = try Session.start();
    defer session.deinit();
    try session.group(&.{
        m.cursor(assignments, "🛰 same-name {% set ns.region = other.<region> %}"),
        m.cursor(assignments, "single-subscript {% set ns.region = other['<region>'] %}"),
        m.cursor(assignments, "trimmed {%- set ns.region = other[\"<region>\"] -%}"),
        m.cursor(assignments, "selector {% set ns.region = other[chooser.<region>].region %}"),
        m.cursor(assignments, "selector {% set ns.region = other[chooser.region].<region> %}"),
        m.cursor(assignments, "named-selector {% set ns.region = other[chooser.selector].<region> %}"),
        m.cursor(assignments, "capture {% set ns.region %}{{ other.<region> }}"),
        m.cursor(assignments, "capture-filter {% set ns.region | acme.tools.apply(other.<region>)"),
        m.cursor(unrelated_assignments, "{{ unrelated.<region> }}"),
        m.cursor(assignments, "preserved-set {%+ set ns.region = other.<region> +%}"),
        m.cursor(defaults, "  <region>: region-value"),
    }, assignment_reads, assignments_with_declarations, assignment_targets, &.{ "**Variable field** `region`", "`region-value`" }, &.{ "**Variable**", "separate-root-region" });
    try session.group(&.{
        m.cursor(assignments, "other[chooser.<selector>].region"),
        m.cursor(unrelated_assignments, "{{ unrelated.<selector> }}"),
        m.cursor(defaults, "  <selector>: selector-value"),
    }, selector_reads, selectors_with_declarations, selector_targets, &.{ "**Variable field** `selector`", "`selector-value`" }, &.{ "**Variable**", "separate-root-selector" });
    try session.group(&.{
        m.cursor(assignments, "root-read {{ <region> }}"),
        m.cursor(defaults, "\n<region>: separate-root-region"),
    }, region_root_reads, region_roots_with_declarations, region_root_targets, &.{ "**Variable** `region`", "`separate-root-region`" }, &.{ "**Variable field**", "region-value" });
    try session.group(&.{
        m.cursor(assignments, "root-selector {{ <selector> }}"),
        m.cursor(defaults, "\n<selector>: separate-root-selector"),
    }, selector_root_reads, selector_roots_with_declarations, selector_root_targets, &.{ "**Variable** `selector`", "`separate-root-selector`" }, &.{ "**Variable field**", "selector-value" });
    try session.negatives(&.{
        m.cursor(assignments, "🛰 same-name {% set ns.<region> ="),
        m.cursor(assignments, "single-subscript {% set ns.<region> ="),
        m.cursor(assignments, "trimmed {%- set ns.<region> ="),
        m.cursor(assignments, "selector {% set ns.<region> = other[chooser.region]"),
        m.cursor(assignments, "named-selector {% set ns.<region> = other[chooser.selector]"),
        m.cursor(assignments, "capture {% set ns.<region> %}"),
        m.cursor(assignments, "capture-filter {% set ns.<region> |"),
        m.cursor(assignments, "preserved-set {%+ set ns.<region> ="),
    });
    try session.finish();
}

const Session = struct {
    arena: *std.heap.ArenaAllocator,
    client: lsp.Client,
    resolver: anchor.Resolver,
    opened: std.StringHashMap(void),
    home: std.testing.TmpDir,
    failures: usize = 0,
    requests: usize = 0,

    fn start() !Session {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer {
            arena.deinit();
            std.testing.allocator.destroy(arena);
        }
        const a = arena.allocator();
        const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/field-lexical-boundaries-workspace");
        const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
        var home = std.testing.tmpDir(.{});
        errdefer home.cleanup();
        var client = try lsp.Client.startWithOptions(a, binary, fixture, fixture, try home.dir.realpathAlloc(a, "."), .{ .collections_path = fixture });
        errdefer client.deinit();
        const initialized = try client.request("initialize", .{
            .processId = @as(?i64, null),
            .rootUri = try std.fmt.allocPrint(a, "file://{s}", .{fixture}),
            .capabilities = .{},
            .initializationOptions = .{ .ansible = .{
                .workspace = .{ .rootMarker = "fixture-workspace-root" },
                .python = .{ .venvPath = "" },
                .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
            } },
        });
        const caps = lsp.field(initialized, "capabilities") orelse return error.MissingCapabilities;
        for ([_][]const u8{ "referencesProvider", "definitionProvider", "implementationProvider", "hoverProvider" }) |name| {
            const enabled = lsp.field(caps, name) orelse return error.MissingCapability;
            try std.testing.expect(enabled == .bool and enabled.bool);
        }
        if (lsp.field(caps, "positionEncoding")) |encoding| try std.testing.expectEqualStrings("utf-16", encoding.string);
        try client.notify("initialized", .{});
        try client.waitForIndex();
        return .{
            .arena = arena,
            .client = client,
            .resolver = .{ .allocator = a, .fixture = fixture, .deps = fixture },
            .opened = std.StringHashMap(void).init(a),
            .home = home,
        };
    }

    fn deinit(self: *Session) void {
        self.client.deinit();
        self.home.cleanup();
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }

    fn group(self: *Session, origins: []const m.Anchor, reads: []const m.ExpectedLocation, declarations: []const m.ExpectedLocation, targets: []const m.ExpectedLocation, contains: []const []const u8, excludes: []const []const u8) !void {
        for (origins) |origin| {
            try self.check(origin, .references, false, reads, &.{}, &.{});
            try self.check(origin, .references, true, declarations, &.{}, &.{});
            try self.check(origin, .definition, false, targets, &.{}, &.{});
            try self.check(origin, .implementation, false, targets, &.{}, &.{});
            try self.check(origin, .hover, false, &.{.{ .marked = origin }}, contains, excludes);
        }
    }

    fn negatives(self: *Session, origins: []const m.Anchor) !void {
        for (origins) |origin| {
            try self.check(origin, .references, false, &.{}, &.{}, &.{});
            try self.check(origin, .references, true, &.{}, &.{}, &.{});
            try self.check(origin, .definition, false, &.{}, &.{}, &.{});
            try self.check(origin, .implementation, false, &.{}, &.{}, &.{});
            try self.check(origin, .hover, false, &.{}, &.{}, &.{});
        }
    }

    fn check(self: *Session, origin: m.Anchor, method: m.Method, include: bool, expectations: []const m.ExpectedLocation, contains: []const []const u8, excludes: []const []const u8) !void {
        const a = self.arena.allocator();
        const cursor = try self.resolver.cursor(origin);
        if (!self.opened.contains(origin.path)) {
            try self.client.notify("textDocument/didOpen", .{ .textDocument = .{
                .uri = cursor.uri,
                .languageId = "yaml",
                .version = @as(u32, 1),
                .text = try self.resolver.readText(origin.path),
            } });
            try self.opened.put(origin.path, {});
        }
        const result = if (method == .references)
            try self.client.request("textDocument/references", .{ .textDocument = .{ .uri = cursor.uri }, .position = cursor.position, .context = .{ .includeDeclaration = include } })
        else
            try self.client.request(try std.fmt.allocPrint(a, "textDocument/{s}", .{@tagName(method)}), .{ .textDocument = .{ .uri = cursor.uri }, .position = cursor.position });
        self.requests += 1;
        const expected = try a.alloc(anchor.Location, expectations.len);
        for (expectations, 0..) |expectation, i| expected[i] = try self.resolver.location(expectation);
        const actual = if (method == .hover) try hoverLocations(a, cursor.uri, result) else try parseLocations(a, result);
        if (method == .references) {
            std.mem.sort(anchor.Location, actual, {}, locationLessThan);
            std.mem.sort(anchor.Location, expected, {}, locationLessThan);
        }
        expectLocations(expected, actual) catch |err| {
            std.debug.print("FAIL {s} (declarations={}): {s}: {s}\n", .{ @tagName(method), include, origin.snippet, @errorName(err) });
            std.debug.print("expected: {s}\nactual: {s}\n", .{ try std.json.Stringify.valueAlloc(a, expected, .{}), try std.json.Stringify.valueAlloc(a, actual, .{}) });
            self.failures += 1;
        };
        if (method == .hover and expected.len != 0) {
            expectHover(result, contains, excludes) catch |err| {
                std.debug.print("FAIL hover contents: {s}: {s}\n", .{ origin.snippet, @errorName(err) });
                self.failures += 1;
            };
        } else if (method == .hover and result != .null) {
            std.debug.print("FAIL negative hover must be null: {s}\n", .{origin.snippet});
            self.failures += 1;
        }
    }

    fn finish(self: *Session) !void {
        std.debug.print("lexical boundary stdio: {d} requests, {d} failures\n", .{ self.requests, self.failures });
        try std.testing.expectEqual(@as(usize, 0), self.failures);
    }
};

fn parseLocations(a: Allocator, result: Value) ![]anchor.Location {
    if (result == .null) return &.{};
    if (result == .object) {
        const locations = try a.alloc(anchor.Location, 1);
        locations[0] = try std.json.parseFromValueLeaky(anchor.Location, a, result, .{});
        return locations;
    }
    if (result != .array) return error.InvalidLocationResult;
    const locations = try a.alloc(anchor.Location, result.array.items.len);
    for (result.array.items, 0..) |item, i| locations[i] = try std.json.parseFromValueLeaky(anchor.Location, a, item, .{});
    return locations;
}

fn hoverLocations(a: Allocator, uri: []const u8, result: Value) ![]anchor.Location {
    if (result == .null) return &.{};
    const range = lsp.field(result, "range") orelse return error.MissingHoverRange;
    const locations = try a.alloc(anchor.Location, 1);
    locations[0] = .{ .uri = uri, .range = try std.json.parseFromValueLeaky(anchor.Range, a, range, .{}) };
    return locations;
}

fn expectHover(result: Value, contains: []const []const u8, excludes: []const []const u8) !void {
    const contents = lsp.field(result, "contents") orelse return error.MissingHoverContents;
    const kind = lsp.field(contents, "kind") orelse return error.MissingHoverKind;
    try std.testing.expectEqualStrings("markdown", kind.string);
    const value = lsp.field(contents, "value") orelse return error.MissingHoverValue;
    for (contains) |snippet| try std.testing.expect(std.mem.indexOf(u8, value.string, snippet) != null);
    for (excludes) |snippet| try std.testing.expect(std.mem.indexOf(u8, value.string, snippet) == null);
}

fn expectLocations(expected: []const anchor.Location, actual: []const anchor.Location) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |left, right| {
        try std.testing.expectEqualStrings(left.uri, right.uri);
        try std.testing.expectEqualDeep(left.range, right.range);
    }
}

fn locationLessThan(_: void, left: anchor.Location, right: anchor.Location) bool {
    const order = std.mem.order(u8, left.uri, right.uri);
    if (order != .eq) return order == .lt;
    if (left.range.start.line != right.range.start.line) return left.range.start.line < right.range.start.line;
    if (left.range.start.character != right.range.start.character) return left.range.start.character < right.range.start.character;
    if (left.range.end.line != right.range.end.line) return left.range.end.line < right.range.end.line;
    return left.range.end.character < right.range.end.character;
}

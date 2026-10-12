//! Standalone Role repositories over real stdio LSP, with authored location
//! oracles. The Workspace root is the Role, not a playbook/collection project.
const std = @import("std");
const m = @import("e2e/model.zig");
const anchor = @import("e2e/anchor.zig");
const lsp = @import("e2e/client.zig");
const Allocator = std.mem.Allocator;

test "stdio standalone yml Role with directory defaults and file vars" {
    try standaloneRole("hardening-yml", "yml", "vars/main.yml");
}

test "stdio standalone yaml Role with directory defaults and nested directory vars" {
    try standaloneRole("hardening-yaml", "yaml", "vars/main/nested/settings.yaml");
}

fn standaloneRole(comptime name: []const u8, comptime ext: []const u8, vars: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try std.fs.cwd().realpathAlloc(a, "test/fixtures/standalone-role/" ++ name);
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    const isolated_home = try home.dir.realpathAlloc(a, ".");
    var client = try lsp.Client.startWithOptions(a, binary, fixture, fixture, isolated_home, .{
        .use_fixture_config = false, // Like RHEL10-CIS, no ansible.cfg is needed.
        .collections_path = try std.fs.path.join(a, &.{ isolated_home, "no-collections" }),
    });
    defer client.deinit();
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
    var nav: Navigation = .{
        .a = a,
        .client = &client,
        .resolver = .{ .allocator = a, .fixture = fixture, .deps = fixture },
        .opened = std.StringHashMap(void).init(a),
    };
    const defaults = "defaults/main/main." ++ ext;
    const audit = "defaults/main/audit." ++ ext;
    const specs = "meta/argument_specs." ++ ext;
    const tasks = "tasks/main." ++ ext;
    const checks = "tasks/nested/check." ++ ext;
    const handlers = "handlers/main." ++ ext;
    const template = "templates/etc/service.conf.j2";

    // Assert disk indexing before opening any source document. The only
    // matching symbol is the root Role, targeting its main task source.
    const symbols = try client.request("workspace/symbol", .{ .query = name });
    try std.testing.expect(symbols == .array);
    try std.testing.expectEqual(@as(usize, 1), symbols.array.items.len);
    const symbol = symbols.array.items[0];
    try std.testing.expectEqualStrings(name, (lsp.field(symbol, "name") orelse return error.MissingSymbolName).string);
    try std.testing.expectEqual(@as(i64, 2), (lsp.field(symbol, "kind") orelse return error.MissingSymbolKind).integer);
    const symbol_location = try std.json.parseFromValueLeaky(anchor.Location, a, lsp.field(symbol, "location") orelse return error.MissingSymbolLocation, .{});
    try std.testing.expectEqualStrings((try nav.resolver.location(m.fileStart(tasks))).uri, symbol_location.uri);

    // Root reads and binding keys must all return the same complete group.
    // The two reference oracles are written separately, never harvested from
    // the server or inferred by walking fixture contents.
    const root_reads: []const m.ExpectedLocation = &.{
        m.span(tasks, "Listening on {{ <hardening_config>.port }}"),
        m.span(handlers, "Reload on {{ <hardening_config>.port }}"),
        m.span(template, "port={{ <hardening_config>.port }}"),
    };
    const root_with_declarations: []const m.ExpectedLocation = &.{
        m.span(tasks, "Listening on {{ <hardening_config>.port }}"),
        m.span(handlers, "Reload on {{ <hardening_config>.port }}"),
        m.span(template, "port={{ <hardening_config>.port }}"),
        m.span(defaults, "\n<hardening_config>:"),
        m.span(vars, "\n<hardening_config>:"),
        m.span(specs, "      <hardening_config>:"),
    };
    const root_definitions: []const m.ExpectedLocation = &.{
        m.span(vars, "\n<hardening_config>:"),
        m.span(defaults, "\n<hardening_config>:"),
        m.span(specs, "      <hardening_config>:"),
    };
    const root_implementations: []const m.ExpectedLocation = &.{
        m.span(vars, "\n<hardening_config>:"),
        m.span(defaults, "\n<hardening_config>:"),
    };
    for ([_]m.Anchor{
        m.cursor(tasks, "Listening on {{ <hardening_config>.port }}"),
        m.cursor(handlers, "Reload on {{ <hardening_config>.port }}"),
        m.cursor(template, "port={{ <hardening_config>.port }}"),
        m.cursor(defaults, "\n<hardening_config>:"),
        m.cursor(vars, "\n<hardening_config>:"),
        m.cursor(specs, "      <hardening_config>:"),
    }) |origin| {
        try nav.locations("textDocument/references", origin, root_reads, false);
        try nav.locations("textDocument/references", origin, root_with_declarations, true);
        try nav.locations("textDocument/definition", origin, root_definitions, false);
        try nav.locations("textDocument/implementation", origin, root_implementations, false);
        try nav.hover(origin, &.{ "**Variable** `hardening_config`", "**Active:**", "8080", "(role_vars)", "(role_defaults)", "(argument_specs)" }, &.{ "(vars_files)", "Elsewhere in the Workspace" });
    }

    // Structured fields retain the same Role precedence; declarations remain
    // definitions but must never be returned as concrete implementations.
    const field_reads: []const m.ExpectedLocation = &.{
        m.span(tasks, "Listening on {{ hardening_config.<port> }}"),
        m.span(handlers, "Reload on {{ hardening_config.<port> }}"),
        m.span(template, "port={{ hardening_config.<port> }}"),
    };
    const fields_with_declarations: []const m.ExpectedLocation = &.{
        m.span(tasks, "Listening on {{ hardening_config.<port> }}"),
        m.span(handlers, "Reload on {{ hardening_config.<port> }}"),
        m.span(template, "port={{ hardening_config.<port> }}"),
        m.span(defaults, "  <port>: 80"),
        m.span(vars, "  <port>: 8080"),
        m.span(specs, "          <port>:"),
    };
    const field_definitions: []const m.ExpectedLocation = &.{
        m.span(vars, "  <port>: 8080"),
        m.span(defaults, "  <port>: 80"),
        m.span(specs, "          <port>:"),
    };
    const field_implementations: []const m.ExpectedLocation = &.{
        m.span(vars, "  <port>: 8080"),
        m.span(defaults, "  <port>: 80"),
    };
    for ([_]m.Anchor{
        m.cursor(tasks, "Listening on {{ hardening_config.<port> }}"),
        m.cursor(handlers, "Reload on {{ hardening_config.<port> }}"),
        m.cursor(template, "port={{ hardening_config.<port> }}"),
        m.cursor(defaults, "  <port>: 80"),
        m.cursor(vars, "  <port>: 8080"),
        m.cursor(specs, "          <port>:"),
    }) |origin| {
        try nav.locations("textDocument/references", origin, field_reads, false);
        try nav.locations("textDocument/references", origin, fields_with_declarations, true);
        try nav.locations("textDocument/definition", origin, field_definitions, false);
        try nav.locations("textDocument/implementation", origin, field_implementations, false);
        try nav.hover(origin, &.{ "**Variable field** `port`", "**Active:** `8080`", "(role_vars)", "(role_defaults)", "Port used by the standalone Role." }, &.{ "(vars_files)", "Elsewhere in the Workspace" });
    }

    // Each split defaults file contributes bindings, including bare when reads.
    for ([_]struct { origin: m.Anchor, target: m.ExpectedLocation }{
        .{ .origin = m.cursor(tasks, "when: <os_check>"), .target = m.span(defaults, "<os_check>: true") },
        .{ .origin = m.cursor(checks, "when: <audit_enabled>"), .target = m.span(audit, "<audit_enabled>: true") },
    }) |binding| {
        try nav.locations("textDocument/definition", binding.origin, &.{binding.target}, false);
        try nav.locations("textDocument/implementation", binding.origin, &.{binding.target}, false);
        try nav.hover(binding.origin, &.{ "**Active:** `true`", "(role_defaults)" }, &.{"(vars_files)"});
    }

    // The second include cannot resolve from its source directory or from the
    // Workspace root: it needs the enclosing Role's tasks/ fallback.
    const nested_include = m.cursor(tasks, "include_tasks: <nested/check." ++ ext ++ ">");
    const shared_include = m.cursor(checks, "import_tasks: <shared." ++ ext ++ ">");
    try nav.locations("textDocument/definition", nested_include, &.{m.fileStart(checks)}, false);
    try nav.locations("textDocument/references", nested_include, &.{m.span(tasks, "include_tasks: <nested/check." ++ ext ++ ">")}, false);
    try nav.locations("textDocument/definition", shared_include, &.{m.fileStart("tasks/shared." ++ ext)}, false);
    try nav.locations("textDocument/references", shared_include, &.{m.span(checks, "import_tasks: <shared." ++ ext ++ ">")}, false);
    std.debug.print("Standalone Role E2E ({s}): {d} navigation requests passed\n", .{ name, nav.requests });
}

const Navigation = struct {
    a: Allocator,
    client: *lsp.Client,
    resolver: anchor.Resolver,
    opened: std.StringHashMap(void),
    requests: usize = 0,

    fn open(self: *Navigation, origin: m.Anchor) !anchor.Cursor {
        const source = try self.resolver.cursor(origin);
        if (!self.opened.contains(origin.path)) {
            try self.client.notify("textDocument/didOpen", .{ .textDocument = .{
                .uri = source.uri,
                .languageId = if (std.mem.endsWith(u8, origin.path, ".j2")) "jinja2" else "yaml.ansible",
                .version = @as(u32, 1),
                .text = try self.resolver.readText(origin.path),
            } });
            try self.opened.put(origin.path, {});
        }
        return source;
    }

    fn locations(self: *Navigation, method: []const u8, origin: m.Anchor, oracle: []const m.ExpectedLocation, include_declaration: bool) !void {
        const source = try self.open(origin);
        const result = try self.client.request(method, .{
            .textDocument = .{ .uri = source.uri },
            .position = source.position,
            .context = .{ .includeDeclaration = include_declaration },
        });
        self.requests += 1;
        const actual: []anchor.Location = switch (result) {
            .null => &.{},
            .array => try std.json.parseFromValueLeaky([]anchor.Location, self.a, result, .{}),
            .object => try self.a.dupe(anchor.Location, &.{try std.json.parseFromValueLeaky(anchor.Location, self.a, result, .{})}),
            else => return error.InvalidLocationResult,
        };
        const expected = try self.a.alloc(anchor.Location, oracle.len);
        for (oracle, 0..) |location, i| expected[i] = try self.resolver.location(location);
        if (std.mem.eql(u8, method, "textDocument/references")) {
            std.mem.sort(anchor.Location, actual, {}, locationLessThan);
            std.mem.sort(anchor.Location, expected, {}, locationLessThan);
        }
        errdefer std.debug.print("{s} from {s}: {s} (includeDeclaration={})\nexpected: {f}\nactual: {f}\n", .{
            method,                      origin.path,               origin.snippet, include_declaration,
            std.json.fmt(expected, .{}), std.json.fmt(actual, .{}),
        });
        try std.testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |want, got| {
            try std.testing.expectEqualStrings(want.uri, got.uri);
            try std.testing.expectEqualDeep(want.range, got.range);
        }
    }

    fn hover(self: *Navigation, origin: m.Anchor, contains: []const []const u8, excludes: []const []const u8) !void {
        const source = try self.open(origin);
        const result = try self.client.request("textDocument/hover", .{
            .textDocument = .{ .uri = source.uri },
            .position = source.position,
        });
        self.requests += 1;
        errdefer std.debug.print("Hover from {s}: {s}\nactual: {f}\n", .{ origin.path, origin.snippet, std.json.fmt(result, .{}) });
        const range = try std.json.parseFromValueLeaky(anchor.Range, self.a, lsp.field(result, "range") orelse return error.MissingHoverRange, .{});
        const expected = try self.resolver.location(.{ .marked = origin });
        try std.testing.expectEqualDeep(expected.range, range);
        const contents = lsp.field(result, "contents") orelse return error.MissingHoverContents;
        try std.testing.expectEqualStrings("markdown", (lsp.field(contents, "kind") orelse return error.MissingMarkupKind).string);
        const markdown = (lsp.field(contents, "value") orelse return error.MissingMarkupValue).string;
        for (contains) |excerpt| try std.testing.expect(std.mem.indexOf(u8, markdown, excerpt) != null);
        for (excludes) |excerpt| try std.testing.expect(std.mem.indexOf(u8, markdown, excerpt) == null);
    }
};

fn locationLessThan(_: void, left: anchor.Location, right: anchor.Location) bool {
    const order = std.mem.order(u8, left.uri, right.uri);
    if (order != .eq) return order == .lt;
    inline for (.{ "start", "end" }) |edge| {
        const l = @field(left.range, edge);
        const r = @field(right.range, edge);
        if (l.line != r.line) return l.line < r.line;
        if (l.character != r.character) return l.character < r.character;
    }
    return false;
}

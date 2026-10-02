//! Black-box file-URI contract: relative Ansible environment search paths
//! must navigate to the exact existing dependency, outside the Workspace.

const std = @import("std");
const lsp = @import("e2e/client.zig");
const anchor = @import("e2e/anchor.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const fixture_path = "test/fixtures/navigation-uris";

test "stdio navigation returns absolute file URIs for relative role environment paths" {
    try checkNavigation(.{
        .snippet = "- role: <uri_demo>",
        .definition = "role-path/uri_demo/meta/argument_specs.yml",
        .implementation = "role-path/uri_demo/tasks/main.yml",
    });
}

test "stdio navigation preserves existing absolute role environment targets" {
    try checkNavigation(.{
        .absolute_paths = true,
        .snippet = "- role: <uri_demo>",
        .definition = "role-path/uri_demo/meta/argument_specs.yml",
        .implementation = "role-path/uri_demo/tasks/main.yml",
    });
}

test "stdio navigation returns absolute file URIs for relative collection environment paths" {
    try checkNavigation(.{
        .snippet = "- role: <uri_paths.dependency.collection_demo>",
        .definition = "collection-path/ansible_collections/uri_paths/dependency/roles/collection_demo/meta/main.yml",
        .implementation = "collection-path/ansible_collections/uri_paths/dependency/roles/collection_demo/tasks/main.yml",
    });
}

test "stdio navigation escapes literal percent space and hash in file targets" {
    try checkNavigation(.{
        .absolute_paths = true,
        .roles_path = "escaped %20#roles",
        .snippet = "- role: <uri_escaped>",
        .definition = "escaped %20#roles/uri_escaped/meta/argument_specs.yml",
        .definition_uri_path = "escaped%20%2520%23roles/uri_escaped/meta/argument_specs.yml",
        .implementation = "escaped %20#roles/uri_escaped/tasks/main.yml",
        .implementation_uri_path = "escaped%20%2520%23roles/uri_escaped/tasks/main.yml",
    });
}

test "stdio navigation can follow a returned escaped file URI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try std.fs.cwd().realpathAlloc(a, fixture_path);
    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    const home = try home_dir.dir.realpathAlloc(a, ".");
    const roles = try std.fs.path.join(a, &.{ fixture, "escaped %20#roles" });
    var client = try startClient(a, fixture, home, roles, "collection-path");
    defer client.deinit();
    try initialize(a, &client, fixture);
    const resolver: anchor.Resolver = .{ .allocator = a, .fixture = fixture, .deps = fixture };
    const invocation = try resolver.cursor(.{ .path = "workspace/site.yml", .snippet = "- role: <uri_escaped>" });
    try openDocument(&client, resolver, "workspace/site.yml", invocation.uri);
    const implementation = try client.request("textDocument/implementation", .{
        .textDocument = .{ .uri = invocation.uri },
        .position = invocation.position,
    });
    try expectFileStart(a, fixture, "escaped %20#roles/uri_escaped/tasks/main.yml", "escaped%20%2520%23roles/uri_escaped/tasks/main.yml", implementation);
    const returned = try parseLocation(a, implementation);
    // Open the exact URI the server returned, as an editor would. Only the
    // cursor position comes from the named static snippet, not server output.
    const source = try resolver.cursor(.{
        .path = "escaped %20#roles/uri_escaped/tasks/main.yml",
        .snippet = "import_tasks: <next.yml>",
    });
    try openDocument(&client, resolver, "escaped %20#roles/uri_escaped/tasks/main.yml", returned.uri);
    const next = try client.request("textDocument/definition", .{
        .textDocument = .{ .uri = returned.uri },
        .position = source.position,
    });
    try expectFileStart(a, fixture, "escaped %20#roles/uri_escaped/tasks/next.yml", "escaped%20%2520%23roles/uri_escaped/tasks/next.yml", next);
}

const NavigationCase = struct {
    absolute_paths: bool = false,
    roles_path: []const u8 = "role-path",
    snippet: []const u8,
    definition: []const u8,
    definition_uri_path: ?[]const u8 = null,
    implementation: []const u8,
    implementation_uri_path: ?[]const u8 = null,
};

fn checkNavigation(case: NavigationCase) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try std.fs.cwd().realpathAlloc(a, fixture_path);
    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    const home = try home_dir.dir.realpathAlloc(a, ".");
    const roles = if (case.absolute_paths) try std.fs.path.join(a, &.{ fixture, case.roles_path }) else case.roles_path;
    const collections = if (case.absolute_paths) try std.fs.path.join(a, &.{ fixture, "collection-path" }) else "collection-path";
    var client = try startClient(a, fixture, home, roles, collections);
    defer client.deinit();
    try initialize(a, &client, fixture);

    const resolver: anchor.Resolver = .{ .allocator = a, .fixture = fixture, .deps = fixture };
    const source = try resolver.cursor(.{ .path = "workspace/site.yml", .snippet = case.snippet });
    try openDocument(&client, resolver, "workspace/site.yml", source.uri);
    const cases = [_]struct { method: []const u8, target: []const u8, uri_path: []const u8 }{
        .{ .method = "textDocument/definition", .target = case.definition, .uri_path = case.definition_uri_path orelse case.definition },
        .{ .method = "textDocument/implementation", .target = case.implementation, .uri_path = case.implementation_uri_path orelse case.implementation },
    };
    var failures: usize = 0;
    for (cases) |request| {
        const result = try client.request(request.method, .{
            .textDocument = .{ .uri = source.uri },
            .position = source.position,
        });
        expectFileStart(a, fixture, request.target, request.uri_path, result) catch |err| {
            std.debug.print("FAIL {s}: {s}\n", .{ request.method, @errorName(err) });
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// Only process setup is local: reuse the stdio framing, timeout, JSON-RPC error
// handling, and index barrier from the shared client without changing its API.
fn startClient(a: Allocator, fixture: []const u8, home: []const u8, roles: []const u8, collections: []const u8) !lsp.Client {
    const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
    var env = try std.process.getEnvMap(a);
    defer env.deinit();
    try env.put("ANSIBLE_ROLES_PATH", roles);
    try env.put("ANSIBLE_COLLECTIONS_PATH", collections);
    env.remove("ANSIBLE_COLLECTIONS_PATHS");
    try env.put("ANSIBLE_CONFIG", try std.fs.path.join(a, &.{ fixture, "workspace/ansible.cfg" }));
    try env.put("HOME", home);
    try env.put("XDG_CACHE_HOME", try std.fs.path.join(a, &.{ home, ".cache" }));
    env.remove("VIRTUAL_ENV");
    var child = std.process.Child.init(&.{ binary, "--stdio", "--log-level", "error" }, a);
    child.env_map = &env;
    // Relative environment paths are interpreted by filesystem lookups from
    // the server's working directory, not the referencing file's directory.
    child.cwd = fixture;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    child.env_map = null;
    return .{ .allocator = a, .child = child };
}

fn initialize(a: Allocator, client: *lsp.Client, fixture: []const u8) !void {
    _ = try client.request("initialize", .{
        .processId = @as(?i64, null),
        .rootUri = try std.fmt.allocPrint(a, "file://{s}/workspace", .{fixture}),
        .capabilities = .{},
        .initializationOptions = .{ .ansible = .{
            .workspace = .{ .rootMarker = "fixture-workspace-root" },
            .python = .{ .venvPath = "" },
            .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
        } },
    });
    try client.notify("initialized", .{});
    try client.waitForIndex();
}

fn openDocument(client: *lsp.Client, resolver: anchor.Resolver, path: []const u8, uri: []const u8) !void {
    try client.notify("textDocument/didOpen", .{ .textDocument = .{
        .uri = uri,
        .languageId = "yaml",
        .version = @as(u32, 1),
        .text = try resolver.readText(path),
    } });
}

fn expectFileStart(a: Allocator, fixture: []const u8, target: []const u8, uri_path: []const u8, result: Value) !void {
    const expected_path = try std.fs.path.join(a, &.{ fixture, target });
    // The written oracle names an existing file, never a fabricated fallback.
    const file = try std.fs.openFileAbsolute(expected_path, .{});
    file.close();
    // Escaped suffixes are written explicitly in each case, independently of
    // production URI conversion. Only the checkout's absolute prefix varies.
    const expected_uri = try std.fmt.allocPrint(a, "file://{s}/{s}", .{ fixture, uri_path });
    const actual = try parseLocation(a, result);
    try std.testing.expectEqualStrings(expected_uri, actual.uri);
    const parsed = try std.Uri.parse(actual.uri);
    try std.testing.expectEqualStrings("file", parsed.scheme);
    try std.testing.expect(parsed.query == null and parsed.fragment == null);
    const returned_path = try parsed.path.toRawMaybeAlloc(a);
    try std.testing.expectEqualStrings(expected_path, returned_path);
    const returned_file = try std.fs.openFileAbsolute(returned_path, .{});
    returned_file.close();
    try std.testing.expectEqualDeep(anchor.Range{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 0 },
    }, actual.range);
}

fn parseLocation(a: Allocator, result: Value) !anchor.Location {
    const value = switch (result) {
        .object => result,
        .array => |items| blk: {
            try std.testing.expectEqual(@as(usize, 1), items.items.len);
            break :blk items.items[0];
        },
        else => return error.ExpectedLocation,
    };
    return std.json.parseFromValueLeaky(anchor.Location, a, value, .{});
}

//! Black-box module-documentation contracts against a real `ansible-doc`:
//! the global docs bootstrap (version fingerprint, catalog, full-doc fetch),
//! hover and completion serving real builtin module documentation, the docs
//! cache the bootstrap persists, and a warm restart serving from that cache.
//! Stdio LSP only, no service imports; skips when ansible-doc is absent.
const std = @import("std");
const lsp = @import("e2e/client.zig");
const anchor = @import("e2e/anchor.zig");
const model = @import("e2e/model.zig");
const Value = std.json.Value;

/// `ansible.builtin.copy`'s short description, stable across ansible-core
/// releases for years; `ansible.builtin.debug`'s likewise below.
const copy_description = "Copy files to remote locations";
const debug_description = "Print statements during execution";

const playbook =
    \\---
    \\- name: Docs bootstrap
    \\  hosts: all
    \\  tasks:
    \\    - name: Copy task
    \\      ansible.builtin.copy:
    \\        src: /tmp/a
    \\        dest: /tmp/b
    \\    - name: Debug task
    \\      ansible.builtin.debug:
    \\        msg: hello
    \\    - name: Choose a module
    \\      module_choice:
    \\
;

fn requireAnsibleDoc(a: std.mem.Allocator) !void {
    const result = std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "ansible-doc", "--version" },
        .max_output_bytes = 1 << 20,
    }) catch return error.SkipZigTest;
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}

const Session = struct {
    workspace: std.testing.TmpDir,
    home: std.testing.TmpDir,
    client: lsp.Client,
    resolver: anchor.Resolver,

    /// One server over a generated workspace and an isolated (cold) docs
    /// cache home. `home` may be shared across sessions to test warm starts;
    /// ownership stays with the caller.
    fn start(a: std.mem.Allocator, workspace: std.testing.TmpDir, home: std.testing.TmpDir) !Session {
        const ws = try workspace.dir.realpathAlloc(a, ".");
        const home_path = try home.dir.realpathAlloc(a, ".");
        const binary = try std.fs.cwd().realpathAlloc(a, "zig-out/bin/zals");
        // An empty collections path keeps the catalog deterministic
        // (ansible.builtin only) whatever the machine has installed.
        const collections = try std.fs.path.join(a, &.{ ws, "collections" });
        var client = try lsp.Client.startWithOptions(a, binary, ws, ws, home_path, .{
            .collections_path = collections,
            .use_fixture_config = false,
        });
        errdefer client.deinit();
        const initialized = try client.request("initialize", .{
            .processId = @as(?i64, null),
            .rootUri = try std.fmt.allocPrint(a, "file://{s}", .{ws}),
            .capabilities = .{},
            .initializationOptions = .{ .ansible = .{
                .workspace = .{ .rootMarker = ".git" },
                .python = .{ .venvPath = "" },
                .validation = .{ .enabled = false, .lint = .{ .enabled = false } },
            } },
        });
        _ = lsp.field(initialized, "capabilities") orelse return error.MissingCapabilities;
        try client.notify("initialized", .{});
        try client.waitForIndex();
        return .{
            .workspace = workspace,
            .home = home,
            .client = client,
            .resolver = .{ .allocator = a, .fixture = ws, .deps = ws },
        };
    }

    fn openPlaybook(self: *Session, a: std.mem.Allocator) !void {
        const uri = try std.fmt.allocPrint(a, "file://{s}/playbook.yml", .{self.resolver.fixture});
        try self.client.notify("textDocument/didOpen", .{ .textDocument = .{
            .uri = uri,
            .languageId = "ansible",
            .version = @as(u32, 1),
            .text = playbook,
        } });
    }

    fn requestAt(self: *Session, method: []const u8, from: model.Anchor) !Value {
        const cursor = try self.resolver.cursor(from);
        return self.client.request(method, .{ .textDocument = .{ .uri = cursor.uri }, .position = cursor.position });
    }

    fn hoverText(self: *Session, from: model.Anchor) ![]const u8 {
        const result = try self.requestAt("textDocument/hover", from);
        const contents = lsp.field(result, "contents") orelse return error.MissingHover;
        const value = lsp.field(contents, "value") orelse return error.MissingHoverText;
        return value.string;
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("Expected documentation containing \"{s}\", got:\n{s}\n", .{ needle, haystack });
        return error.WrongDocumentation;
    }
}

/// A generated workspace: git marker, the playbook, an empty collections dir.
fn makeWorkspace() !std.testing.TmpDir {
    var workspace = std.testing.tmpDir(.{});
    errdefer workspace.cleanup();
    try workspace.dir.makeDir(".git");
    try workspace.dir.makeDir("collections");
    try workspace.dir.writeFile(.{ .sub_path = "playbook.yml", .data = playbook });
    return workspace;
}

test "real ansible-doc serves builtin module documentation and completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try requireAnsibleDoc(a);

    var workspace = try makeWorkspace();
    defer workspace.cleanup();
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var session = try Session.start(a, workspace, home);
    defer session.client.deinit();
    try session.openPlaybook(a);

    // Hover over each module name: the documentation text itself must come
    // from a real ansible-doc subprocess (or the dump/batch fetch behind the
    // same subprocess interface), not from any bundled fixture.
    try expectContains(
        try session.hoverText(model.cursor("playbook.yml", "      <ansible.builtin.copy>:")),
        copy_description,
    );
    try expectContains(
        try session.hoverText(model.cursor("playbook.yml", "      <ansible.builtin.debug>:")),
        debug_description,
    );

    // Completion at a module-name position lists the builtin module, and
    // resolving the item returns its ansible-doc documentation. The module
    // list is eventually consistent with the background bootstrap, so a
    // user typing right after startup sees the catalog once ansible-doc has
    // answered; poll for it rather than asserting a specific interleaving.
    const deadline = std.time.milliTimestamp() + 30_000;
    while (true) {
        const completion = try session.requestAt("textDocument/completion", model.cursor("playbook.yml", "      <module_choice>:"));
        const items = lsp.field(completion, "items") orelse return error.MissingCompletions;
        for (items.array.items) |item| {
            const label = lsp.field(item, "label") orelse continue;
            if (!std.mem.eql(u8, label.string, "ansible.builtin.copy")) continue;
            const resolved = try session.client.request("completionItem/resolve", item);
            const documentation = lsp.field(resolved, "documentation") orelse return error.MissingResolvedDocumentation;
            const value = lsp.field(documentation, "value") orelse return error.MissingResolvedText;
            try expectContains(value.string, copy_description);
            std.debug.print("module docs e2e: real ansible-doc hover, completion, and resolve\n", .{});
            return;
        }
        if (std.time.milliTimestamp() > deadline) return error.MissingBuiltinModuleCompletion;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

/// Await the docs cache file the bootstrap persists, and return its path.
fn waitForDocsCache(a: std.mem.Allocator, home: *std.testing.TmpDir) ![]const u8 {
    const cache_dir = try std.fs.path.join(a, &.{ try home.dir.realpathAlloc(a, "."), ".cache", "zals" });
    const deadline = std.time.milliTimestamp() + 120_000;
    while (std.time.milliTimestamp() < deadline) {
        var dir = std.fs.openDirAbsolute(cache_dir, .{ .iterate = true }) catch {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (std.mem.startsWith(u8, entry.name, "docs-") and std.mem.endsWith(u8, entry.name, ".json")) {
                return try std.fs.path.join(a, &.{ cache_dir, entry.name });
            }
        }
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    return error.DocsCacheNeverWritten;
}

test "docs bootstrap persists real documentation and a warm restart serves it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try requireAnsibleDoc(a);

    var workspace = try makeWorkspace();
    defer workspace.cleanup();
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();

    // Cold start: run the bootstrap to completion. The docs cache file
    // appearing means the full-doc fetch finished and was persisted.
    {
        var session = try Session.start(a, workspace, home);
        defer session.client.deinit();
        try session.openPlaybook(a);
        const cache_path = try waitForDocsCache(a, &home);

        // The persisted cache carries the real ansible-doc documentation.
        const bytes = try std.fs.cwd().readFileAlloc(a, cache_path, 256 << 20);
        const parsed = try std.json.parseFromSlice(Value, a, bytes, .{});
        defer parsed.deinit();
        const modules = lsp.field(parsed.value, "modules") orelse return error.MissingCachedModules;
        const copy = lsp.field(modules, "ansible.builtin.copy") orelse return error.MissingCachedCopyDocs;
        try expectContains((lsp.field(copy, "description") orelse return error.MissingCachedDescription).string, copy_description);
    }

    // Warm start over the same home: the bootstrap loads the cache instead
    // of re-fetching, and hover still serves the documentation.
    {
        var session = try Session.start(a, workspace, home);
        defer session.client.deinit();
        try session.openPlaybook(a);
        try expectContains(
            try session.hoverText(model.cursor("playbook.yml", "      <ansible.builtin.copy>:")),
            copy_description,
        );
        std.debug.print("module docs e2e: docs cache persisted and served after warm restart\n", .{});
    }
}

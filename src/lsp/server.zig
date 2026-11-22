//! The LSP server: message loop, lifecycle, and dispatch.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");
const out = @import("outgoing.zig");
const Transport = @import("transport.zig").Transport;
const DocumentStore = @import("../workspace/store.zig").DocumentStore;
const PositionEncoding = @import("../workspace/document.zig").PositionEncoding;
const Settings = @import("../workspace/settings.zig").Settings;
const workspace_session = @import("../workspace/session.zig");
const workspace_index = @import("../workspace/index.zig");
const WorkspaceIndex = workspace_index.WorkspaceIndex;
const handlers = @import("handlers.zig");
const cancellation_mod = @import("cancellation.zig");
const exec = @import("../exec/root.zig");
const DocsLibrary = @import("../services/docs.zig").DocsLibrary;
const SchemaCatalog = @import("../services/schema_service.zig").Catalog;
const AnsibleConfig = @import("../services/ansible_config.zig").AnsibleConfig;
const concurrency = @import("../concurrency/root.zig");
const docs_service = @import("../services/docs_service.zig");
const DocsService = docs_service.DocsService;
const Writer = @import("writer.zig").Writer;
const navigation_context = @import("../queries/context.zig");
const validation_provider = @import("../providers/validation.zig");

pub const Server = struct {
    allocator: Allocator,
    transport: Transport,
    writer: *Writer,
    documents: DocumentStore,
    settings: Settings,
    runner: exec.Runner,
    docs: DocsLibrary,
    schemas: SchemaCatalog,
    ansible_config: AnsibleConfig,
    pool: *concurrency.ThreadPool,
    docs_service: DocsService,
    validation: validation_provider.Queue,
    contextual_docs: docs_service.ContextLibraries,
    encoding: PositionEncoding = .utf16,
    initialized: bool = false,
    shutdown_requested: bool = false,
    running: bool = true,
    /// True when the client advertises `workspace.workspaceEdit.resourceOperations`
    /// containing `create` (needed by the extract code actions).
    supports_create_file: bool = false,
    session: workspace_session.Session,
    /// Workspace index (ADR-0031).
    index: *WorkspaceIndex,
    /// The client supports dynamic registration of watched files.
    can_watch_files: bool = false,
    /// Watched-file events keep the index current; otherwise it re-stats.
    watching_files: bool = false,
    cancellation: cancellation_mod.Cancellation,
    deferred: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(allocator: Allocator, transport: Transport, venv_override: ?[]const u8) !Server {
        const runner = exec.Posix.posixRunner();
        // Leave room for file parsing alongside blocking docs bootstrap, but
        // bound the pool on both large and single-core machines.
        const workers = @min(4, @max(2, std.Thread.getCpuCount() catch 2));
        const pool = try concurrency.ThreadPool.init(allocator, workers);
        errdefer pool.deinit();
        const writer = try Writer.init(allocator, transport.out_file);
        errdefer writer.deinit();
        const index = try WorkspaceIndex.create(allocator);
        errdefer index.destroy();

        return Server{
            .allocator = allocator,
            .transport = transport,
            .writer = writer,
            .documents = DocumentStore.init(allocator, .utf16),
            .settings = Settings.init(allocator),
            .runner = runner,
            .docs = DocsLibrary.init(allocator, runner, "ansible-doc"),
            .schemas = SchemaCatalog.init(allocator),
            .ansible_config = AnsibleConfig.init(allocator, runner),
            .pool = pool,
            .docs_service = DocsService.init(allocator),
            .validation = validation_provider.Queue.init(allocator),
            .contextual_docs = docs_service.ContextLibraries.init(allocator, runner),
            .session = try workspace_session.Session.init(allocator, venv_override),
            .index = index,
            .cancellation = cancellation_mod.Cancellation.init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        // Ask background work to stop, then join workers so no task touches the
        // docs library afterwards.
        self.docs_service.shutdown.store(true, .release);
        self.index.shutdown.store(true, .release);
        self.validation.shutdown.store(true, .release);
        self.pool.deinit();
        self.validation.deinit();
        self.index.destroy();
        self.documents.deinit();
        self.settings.deinit();
        self.contextual_docs.deinit();
        self.docs.deinit();
        self.schemas.deinit();
        self.ansible_config.deinit();
        self.docs_service.deinit();
        self.session.deinit();
        self.cancellation.deinit();
        for (self.deferred.items) |body| self.allocator.free(body);
        self.deferred.deinit(self.allocator);
        // Flush any queued outgoing messages before tearing down the writer.
        self.writer.deinit();
    }

    pub fn run(self: *Server) !void {
        while (self.running) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            try self.drainBackground(a);
            // While bootstrap/scanning is active, wake periodically to apply
            // results and publish readiness even if the client sends nothing.
            // Once ready, return to a blocking read (no idle polling).
            if (self.deferred.items.len == 0 and (self.index.isScanning() or self.docs_service.hasPendingBootstrap() or self.validation.hasPending())) {
                if (!try self.transport.waitForInput(25)) continue;
            }
            const body = self.nextDeferred() orelse (try self.transport.readMessage(self.allocator)) orelse break;
            defer self.allocator.free(body);

            const msg = std.json.parseFromSliceLeaky(Value, a, body, .{}) catch continue;
            self.dispatch(a, msg) catch |err| {
                std.log.err("dispatch failed: {s}", .{@errorName(err)});
            };
        }
    }

    fn nextDeferred(self: *Server) ?[]u8 {
        if (self.deferred.items.len == 0) return null;
        return self.deferred.orderedRemove(0);
    }

    fn dispatch(self: *Server, a: Allocator, msg: Value) !void {
        const method = json_util.string(msg, "method") orelse return;
        const id = json_util.field(msg, "id");
        const params = json_util.field(msg, "params") orelse Value.null;

        try self.drainBackground(a);

        if (id) |req_id| {
            self.drainPendingInput(a);
            if (self.cancellation.take(req_id)) {
                return self.sendError(a, req_id, -32800, "request cancelled by the client");
            }
            handlers.handleRequest(self, a, req_id, method, params) catch |err| {
                try self.sendError(a, req_id, -32603, @errorName(err));
            };
        } else {
            try handlers.handleNotification(self, a, method, params);
        }
    }

    fn drainPendingInput(self: *Server, a: Allocator) void {
        while (true) {
            const body = (self.transport.tryReadMessage(self.allocator) catch return) orelse return;
            const msg = std.json.parseFromSliceLeaky(Value, a, body, .{}) catch {
                self.allocator.free(body);
                continue;
            };
            const method = json_util.string(msg, "method") orelse "";
            if (std.mem.eql(u8, method, "$/cancelRequest")) {
                self.cancellation.record(json_util.field(msg, "params") orelse Value.null);
                self.allocator.free(body);
            } else {
                self.deferred.append(self.allocator, body) catch self.allocator.free(body);
            }
        }
    }

    fn drainBackground(self: *Server, a: Allocator) !void {
        self.index.drain();
        if (self.index.takeReadyEvent()) {
            var ready = json_util.obj(a);
            try ready.put("filesCount", json_util.num(@as(i64, @intCast(self.index.count()))));
            try self.notify(a, "ansible/workspaceIndexReady", .{ .object = ready });
        }
        if (self.docs_service.takeReadyEvent()) {
            var ready = json_util.obj(a);
            try ready.put("modulesCount", json_util.num(self.docs.catalogCount()));
            try self.notify(a, "ansible/docsLibraryReady", .{ .object = ready });
        }
        try validation_provider.drain(self, a);
    }

    pub fn sendResult(self: *Server, a: Allocator, id: Value, result: Value) !void {
        try out.sendResult(self.writer, a, id, result);
    }

    pub fn sendError(self: *Server, a: Allocator, id: Value, code: i64, message: []const u8) !void {
        try out.sendError(self.writer, a, id, code, message);
    }

    pub fn notify(self: *Server, a: Allocator, method: []const u8, params: Value) !void {
        try out.sendNotification(self.writer, a, method, params);
    }

    /// Apply session effects on the main thread, index before warning.
    pub fn applySession(self: *Server, a: Allocator, event: workspace_session.Event) !void {
        const effects = try self.session.apply(a, event);
        if (effects.sync) |sync_effect| {
            try self.index.syncRoots(self.pool, sync_effect.roots, sync_effect.marker, sync_effect.rescan);
        }
        if (effects.warning) |message| {
            try out.showMessage(self.writer, a, 2, message);
            try out.logMessage(self.writer, a, 2, message);
        }
    }

    /// Ask the client to watch navigation and collection source files
    /// (ADR-0031, ADR-0038), plus configuration and collection metadata.
    pub fn registerFileWatchers(self: *Server, a: Allocator) !void {
        if (!self.can_watch_files) return;
        var watchers = std.json.Array.init(a);
        for ([_][]const u8{ "**/*.{yml,yaml,j2}", "**/plugins/**/*.{py,ps1}", "**/ansible.cfg", "**/galaxy.{yml,yaml}" }) |glob| {
            var w = json_util.obj(a);
            try w.put("globPattern", json_util.str(glob));
            try watchers.append(.{ .object = w });
        }
        var opts = json_util.obj(a);
        try opts.put("watchers", .{ .array = watchers });
        var reg = json_util.obj(a);
        try reg.put("id", json_util.str("zals-watched-files"));
        try reg.put("method", json_util.str("workspace/didChangeWatchedFiles"));
        try reg.put("registerOptions", .{ .object = opts });
        var regs = std.json.Array.init(a);
        try regs.append(.{ .object = reg });
        var params = json_util.obj(a);
        try params.put("registrations", .{ .array = regs });
        try out.sendRequest(self.writer, a, "zals-register-watchers", "client/registerCapability", .{ .object = params });
        self.watching_files = true;
    }

    /// Re-index one file on disk if it is a member of a session Workspace.
    pub fn reindexPath(self: *Server, a: Allocator, path: []const u8) void {
        const resolved = workspace_session.resolvedPath(a, path) catch return;
        const root = self.session.snapshot().member(resolved) orelse {
            self.index.remove(resolved);
            return;
        };
        self.index.reindex(root, resolved);
    }

    /// The navigation context for one request, borrowing `lease`. Module
    /// lookup shares navigation's effective per-file collection paths,
    /// without mutating the process environment or sharing FQCN-only caches.
    /// The paths are already absolute (relative entries keep their server-cwd
    /// meaning), and `ansible-doc` runs in the server's working directory.
    pub fn navigationContext(self: *Server, a: Allocator, lease: *const WorkspaceIndex.QueryLease) !navigation_context.Context {
        return navigation_context.Context.init(a, lease, .{
            .documents = &self.documents,
            .workspaces = self.session.snapshot(),
            .ansible_config = &self.ansible_config,
            .docs = navigation_context.Docs.contextual(&self.contextual_docs),
            .encoding = self.encoding,
        });
    }
};

const testing = std.testing;

fn writeFrame(file: std.fs.File, body: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {d}\r\n\r\n", .{body.len});
    try file.writeAll(header);
    try file.writeAll(body);
}

fn runOverFrames(frames: []const []const u8, out_file: std.fs.File) !void {
    const pipe_fds = try std.posix.pipe();
    const in_file = std.fs.File{ .handle = pipe_fds[0] };
    const write_end = std.fs.File{ .handle = pipe_fds[1] };
    defer in_file.close();
    defer write_end.close();
    for (frames) |body| try writeFrame(write_end, body);

    var server = try Server.init(testing.allocator, Transport.init(in_file, out_file), null);
    errdefer server.deinit();
    try server.run();
    server.deinit();
}

fn readOutput(file: std.fs.File, a: Allocator) ![]u8 {
    try file.seekTo(0);
    return try file.readToEndAlloc(a, 64 * 1024);
}

test "a request cancelled while queued replies RequestCancelled" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_file = try tmp.dir.createFile("messages", .{ .read = true });
    defer out_file.close();

    try runOverFrames(&.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":1}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    }, out_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const output = try readOutput(out_file, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, output, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-32800") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"result\"") == null);
}

test "an uncanceled request is answered normally" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_file = try tmp.dir.createFile("messages", .{ .read = true });
    defer out_file.close();

    try runOverFrames(&.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    }, out_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const output = try readOutput(out_file, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, output, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"result\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "-32800") == null);
}

test "messages after a drained cancel are deferred in order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_file = try tmp.dir.createFile("messages", .{ .read = true });
    defer out_file.close();

    try runOverFrames(&.{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancelRequest\",\"params\":{\"id\":1}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/symbol\",\"params\":{\"query\":\"\"}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}",
    }, out_file);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const output = try readOutput(out_file, arena.allocator());
    const first_cancel = std.mem.indexOf(u8, output, "-32800").?;
    const second = std.mem.indexOf(u8, output, "\"id\":2").?;
    try testing.expect(first_cancel < second);
    try testing.expect(std.mem.indexOf(u8, output, "\"result\"") != null);
}

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
const handlers = @import("handlers.zig");
const exec = @import("../exec/root.zig");
const DocsLibrary = @import("../services/docs.zig").DocsLibrary;
const SchemaCatalog = @import("../services/schema_service.zig").Catalog;
const concurrency = @import("../concurrency/root.zig");
const docs_service = @import("../services/docs_service.zig");
const docs_cache = @import("../services/docs_cache.zig");
const DocsService = docs_service.DocsService;
const Writer = @import("writer.zig").Writer;

pub const Server = struct {
    allocator: Allocator,
    transport: Transport,
    writer: *Writer,
    documents: DocumentStore,
    settings: Settings,
    runner: exec.Runner,
    docs: DocsLibrary,
    schemas: SchemaCatalog,
    pool: *concurrency.ThreadPool,
    docs_service: DocsService,
    cache_path: ?[]const u8 = null,
    encoding: PositionEncoding = .utf16,
    initialized: bool = false,
    shutdown_requested: bool = false,
    running: bool = true,
    root_uris: std.array_list.Managed([]const u8),

    pub fn init(allocator: Allocator, transport: Transport) !Server {
        const runner = exec.Posix.posixRunner();
        const pool = try concurrency.ThreadPool.init(allocator, 2);
        errdefer pool.deinit();
        const writer = try Writer.init(allocator, transport.out_fd);
        errdefer writer.deinit();

        var server = Server{
            .allocator = allocator,
            .transport = transport,
            .writer = writer,
            .documents = DocumentStore.init(allocator, .utf16),
            .settings = Settings.init(allocator),
            .runner = runner,
            .docs = DocsLibrary.init(allocator, runner, "ansible-doc"),
            .schemas = SchemaCatalog.init(allocator),
            .pool = pool,
            .docs_service = DocsService.init(allocator, null),
            .root_uris = std.array_list.Managed([]const u8).init(allocator),
        };

        if (docs_service.computeFingerprint(allocator, runner)) |fp| {
            defer allocator.free(fp.hash);
            defer allocator.free(fp.version);
            server.cache_path = docs_cache.cachePath(allocator, fp.hash) catch null;
            server.docs_service.cache_path = server.cache_path;
            server.docs.ansible_version = server.docs.arena.allocator().dupe(u8, fp.version) catch "";
        }
        return server;
    }

    pub fn deinit(self: *Server) void {
        // Ask background work to stop, then join workers so no task touches the
        // docs library afterwards.
        self.docs_service.shutdown.store(true, .release);
        self.pool.deinit();
        self.documents.deinit();
        self.settings.deinit();
        self.docs.deinit();
        self.schemas.deinit();
        if (self.cache_path) |p| self.allocator.free(p);
        for (self.root_uris.items) |u| self.allocator.free(u);
        self.root_uris.deinit();
        // Flush any queued outgoing messages before tearing down the writer.
        self.writer.deinit();
    }

    pub fn run(self: *Server) !void {
        while (self.running) {
            const body = (try self.transport.readMessage(self.allocator)) orelse break;
            defer self.allocator.free(body);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const msg = std.json.parseFromSliceLeaky(Value, a, body, .{}) catch continue;
            self.dispatch(a, msg) catch |err| {
                std.log.err("dispatch failed: {s}", .{@errorName(err)});
            };
        }
    }

    fn dispatch(self: *Server, a: Allocator, msg: Value) !void {
        const method = json_util.string(msg, "method") orelse return;
        const id = json_util.field(msg, "id");
        const params = json_util.field(msg, "params") orelse Value.null;

        if (id) |req_id| {
            handlers.handleRequest(self, a, req_id, method, params) catch |err| {
                try out.sendError(&self.transport, a, req_id, -32603, @errorName(err));
            };
        } else {
            try handlers.handleNotification(self, a, method, params);
        }
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
};

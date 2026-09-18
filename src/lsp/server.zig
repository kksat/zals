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

pub const Server = struct {
    allocator: Allocator,
    transport: Transport,
    documents: DocumentStore,
    settings: Settings,
    runner: exec.Runner,
    docs: DocsLibrary,
    schemas: SchemaCatalog,
    encoding: PositionEncoding = .utf16,
    initialized: bool = false,
    shutdown_requested: bool = false,
    running: bool = true,
    root_uris: std.array_list.Managed([]const u8),

    pub fn init(allocator: Allocator, transport: Transport) Server {
        const runner = exec.Posix.posixRunner();
        return .{
            .allocator = allocator,
            .transport = transport,
            .documents = DocumentStore.init(allocator, .utf16),
            .settings = Settings.init(allocator),
            .runner = runner,
            .docs = DocsLibrary.init(allocator, runner, "ansible-doc"),
            .schemas = SchemaCatalog.init(allocator),
            .root_uris = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        self.documents.deinit();
        self.settings.deinit();
        self.docs.deinit();
        self.schemas.deinit();
        for (self.root_uris.items) |u| self.allocator.free(u);
        self.root_uris.deinit();
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
        try out.sendResult(&self.transport, a, id, result);
    }

    pub fn sendError(self: *Server, a: Allocator, id: Value, code: i64, message: []const u8) !void {
        try out.sendError(&self.transport, a, id, code, message);
    }

    pub fn notify(self: *Server, a: Allocator, method: []const u8, params: Value) !void {
        try out.sendNotification(&self.transport, a, method, params);
    }
};

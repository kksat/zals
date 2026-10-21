//! Request and notification handlers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");
const encode = @import("encode.zig");
const capabilities = @import("capabilities.zig");
const sync = @import("sync.zig");
const navigation = @import("navigation.zig");
const Server = @import("server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const providers = @import("../providers/root.zig");
const cursor = @import("../cursor.zig");
const Context = @import("../queries/context.zig").Context;

pub fn handleRequest(self: *Server, a: Allocator, id: Value, method: []const u8, params: Value) !void {
    if (std.mem.eql(u8, method, "initialize")) return onInitialize(self, a, id, params);
    if (std.mem.eql(u8, method, "shutdown")) {
        self.shutdown_requested = true;
        return self.sendResult(a, id, Value.null);
    }

    // Lifecycle requests above are writers. Remaining requests
    // share a lazy lease through response encoding and enqueueing; nested
    // Workspace/role/collection reads borrow one revision. Notifications
    // run separately, so documents, roots, settings and the selected venv also
    // remain stable without copying them into a second snapshot.
    var lease = self.index.acquireQuery(!self.watching_files);
    defer lease.release();
    // Holding the navigation context is holding the lease.
    var context = try self.navigationContext(a, &lease);

    if (std.mem.eql(u8, method, "textDocument/completion"))
        return self.sendResult(a, id, try completionResult(self, &context, params));
    if (std.mem.eql(u8, method, "completionItem/resolve"))
        return self.sendResult(a, id, try resolveResult(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/hover"))
        return self.sendResult(a, id, try navigation.result(&context, .hover, params));
    if (std.mem.eql(u8, method, "textDocument/definition"))
        return self.sendResult(a, id, try navigation.result(&context, .definition, params));
    if (std.mem.eql(u8, method, "textDocument/implementation"))
        return self.sendResult(a, id, try navigation.result(&context, .implementation, params));
    if (std.mem.eql(u8, method, "textDocument/references"))
        return self.sendResult(a, id, try navigation.result(&context, .references, params));
    if (std.mem.eql(u8, method, "textDocument/semanticTokens/full"))
        return self.sendResult(a, id, try semanticResult(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/documentSymbol"))
        return self.sendResult(a, id, try providers.document_symbols.documentSymbol(self, a, params));
    if (std.mem.eql(u8, method, "workspace/symbol"))
        return self.sendResult(a, id, try providers.workspace_symbols.workspaceSymbol(&context, params));
    if (std.mem.eql(u8, method, "textDocument/codeAction"))
        return self.sendResult(a, id, try providers.code_actions.codeActions(self, a, params));
    return self.sendError(a, id, -32601, "method not found");
}

pub fn handleNotification(self: *Server, a: Allocator, method: []const u8, params: Value) !void {
    if (std.mem.eql(u8, method, "initialized")) {
        self.initialized = true;
        self.docs_service.start(&self.docs, self.pool);
        try self.warnMissingWorkspace(a);
        try self.registerFileWatchers(a);
        try self.syncIndex(false);
        return;
    }
    if (std.mem.eql(u8, method, "exit")) {
        self.running = false;
        return;
    }
    if (std.mem.eql(u8, method, "textDocument/didOpen")) return sync.didOpen(self, a, params);
    if (std.mem.eql(u8, method, "textDocument/didChange")) return sync.didChange(self, params);
    if (std.mem.eql(u8, method, "textDocument/didClose")) return sync.didClose(self, params);
    if (std.mem.eql(u8, method, "textDocument/didSave")) return sync.didSave(self, a, params);
    if (std.mem.eql(u8, method, "workspace/didChangeConfiguration")) {
        const previous = try self.allocator.dupe(u8, self.settings.root_marker);
        defer self.allocator.free(previous);
        try self.settings.update(params);
        const marker_changed = !std.mem.eql(u8, previous, self.settings.root_marker);
        if (marker_changed) self.warned_missing_workspace = false;
        try self.rebuildWorkspaces();
        if (marker_changed) try self.syncIndex(true);
        try self.warnMissingWorkspace(a);
        return;
    }
    if (std.mem.eql(u8, method, "workspace/didChangeWorkspaceFolders")) {
        return sync.didChangeWorkspaceFolders(self, a, params);
    }
    if (std.mem.eql(u8, method, "workspace/didChangeWatchedFiles")) {
        return sync.didChangeWatchedFiles(self, a, params);
    }
    // Unknown notifications are ignored, per the LSP spec.
}

fn documentByUri(self: *Server, params: Value) ?*Document {
    const td = json_util.field(params, "textDocument") orelse return null;
    const uri = json_util.string(td, "uri") orelse return null;
    return self.documents.get(uri);
}

fn emptyCompletion(a: Allocator) !Value {
    return encode.completionList(a, .{ .items = &.{} });
}

fn completionResult(self: *Server, context: *Context, params: Value) !Value {
    const a = context.allocator;
    const loc = navigation.cursorAt(context.session.documents, params) orelse return emptyCompletion(a);
    if (try providers.collections.completion(context, loc.doc, loc.offset)) |items| {
        return encode.completionList(a, .{ .items = items });
    }
    var opened = cursor.Doc.open(a, loc.doc.bytes()) catch return emptyCompletion(a);
    defer opened.deinit();
    const lib = try self.docsForUri(a, loc.doc.uri);
    const lookup = cursor.fromLibrary(lib);
    const cur = try opened.at(loc.doc.uri, loc.offset, lookup);
    var result = try encode.completionList(a, try providers.completion.list(a, cur, lookup));
    // LSP returns this opaque data unchanged to completionItem/resolve.
    // Preserve document context instead of resolving against a global library.
    var data = json_util.obj(a);
    try data.put("uri", json_util.str(loc.doc.uri));
    if (result.object.getPtr("items")) |items| {
        for (items.array.items) |*item| try item.object.put("data", .{ .object = data });
    }
    return result;
}

fn resolveResult(self: *Server, a: Allocator, params: Value) !Value {
    const label = json_util.string(params, "label") orelse return params;
    const data = json_util.field(params, "data") orelse Value.null;
    const lib = if (json_util.string(data, "uri")) |uri| try self.docsForUri(a, uri) else &self.docs;
    const extra = providers.completion.resolve(a, label, cursor.fromLibrary(lib));
    var obj = switch (params) {
        .object => |o| o,
        else => return params,
    };
    if (extra.detail) |d| try obj.put("detail", json_util.str(d));
    if (extra.documentation) |doc| try obj.put("documentation", try encode.markup(a, doc));
    return .{ .object = obj };
}

fn semanticResult(self: *Server, a: Allocator, params: Value) !Value {
    const doc = documentByUri(self, params) orelse return encode.semanticTokens(a, &.{});
    const lib = try self.docsForUri(a, doc.uri);
    const tokens = try providers.semantic_tokens.collect(a, doc, cursor.fromLibrary(lib));
    return encode.semanticTokens(a, tokens);
}

fn onInitialize(self: *Server, a: Allocator, id: Value, params: Value) !void {
    // Position encoding: prefer utf-8 when the client advertises it.
    var encoding_name: []const u8 = "utf-16";
    if (json_util.field(params, "capabilities")) |caps| {
        if (json_util.field(caps, "general")) |general| {
            if (json_util.array(general, "positionEncodings")) |encodings| {
                for (encodings.items) |e| {
                    if (e == .string and std.mem.eql(u8, e.string, "utf-8")) {
                        self.encoding = .utf8;
                        encoding_name = "utf-8";
                        break;
                    }
                }
            }
        }
        // Resource operations the client can apply in a `WorkspaceEdit`.
        if (json_util.field(caps, "workspace")) |workspace| {
            if (json_util.field(workspace, "didChangeWatchedFiles")) |w| {
                self.can_watch_files = json_util.boolean(w, "dynamicRegistration") orelse false;
            }
            if (json_util.field(workspace, "workspaceEdit")) |we| {
                if (json_util.array(we, "resourceOperations")) |ops| {
                    for (ops.items) |op| {
                        if (op == .string and std.mem.eql(u8, op.string, "create")) {
                            self.supports_create_file = true;
                            break;
                        }
                    }
                }
            }
        }
    }
    self.documents.encoding = self.encoding;

    // Initialization options may carry settings. Apply them before resolving
    // Workspaces so a disabled missing-git warning is already in effect.
    if (json_util.field(params, "initializationOptions")) |opts| {
        self.settings.update(opts) catch {};
    }

    var opened = std.array_list.Managed([]const u8).init(a);
    if (json_util.array(params, "workspaceFolders")) |folders| {
        for (folders.items) |f| {
            if (json_util.string(f, "uri")) |uri| try opened.append(uri);
        }
    } else if (json_util.string(params, "rootUri")) |uri| {
        try opened.append(uri);
    }
    const has_folders = opened.items.len > 0;
    try self.setOpenedFolders(opened.items);

    var result = json_util.obj(a);
    try result.put("capabilities", try capabilities.build(a, encoding_name, has_folders));
    var info = json_util.obj(a);
    try info.put("name", json_util.str("zals"));
    try info.put("version", json_util.str("0.0.0"));
    try result.put("serverInfo", .{ .object = info });

    try self.sendResult(a, id, .{ .object = result });
}

test "removed refresh leaves settings and Workspaces unchanged while standard configuration still works" {
    const testing = std.testing;
    const Transport = @import("transport.zig").Transport;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    (try tmp.dir.createFile("workspace-marker", .{})).close();
    (try tmp.dir.createFile("next-marker", .{})).close();
    const output = try tmp.dir.createFile("messages", .{ .read = true });
    defer output.close();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const root_uri = try @import("../paths.zig").pathToUri(a, root);
    const ids = [_]Value{ .{ .integer = 0 }, json_util.str("refresh") };
    {
        var server = try Server.init(testing.allocator, Transport.init(output, output));
        defer server.deinit(); // Flush the writer before inspecting the wire output.
        var params = try std.json.parseFromSliceLeaky(Value, a,
            \\{"initializationOptions":{"ansible":{"workspace":{"rootMarker":"workspace-marker"},"python":{"venvPath":"custom-venv"},"validation":{"enabled":false}}}}
        , .{});
        try params.object.put("rootUri", json_util.str(root_uri));
        try handleRequest(&server, a, .{ .integer = 1 }, "initialize", params);
        try testing.expectEqualStrings("workspace-marker", server.settings.root_marker);
        try testing.expectEqualStrings("custom-venv", server.settings.venv_path);
        try testing.expect(!server.settings.validation_enabled);
        try testing.expectEqual(@as(usize, 1), server.root_uris.items.len);
        try testing.expectEqualStrings(root_uri, server.root_uris.items[0]);

        for (ids) |id| {
            try handleRequest(&server, a, id, "ansible/refreshConfiguration", .null);
            try testing.expectEqualStrings("workspace-marker", server.settings.root_marker);
            try testing.expectEqualStrings("custom-venv", server.settings.venv_path);
            try testing.expect(!server.settings.validation_enabled);
            try testing.expectEqual(@as(usize, 1), server.root_uris.items.len);
            try testing.expectEqualStrings(root_uri, server.root_uris.items[0]);
        }
        try handleNotification(&server, a, "ansible/refreshConfiguration", .null);
        try testing.expectEqualStrings("workspace-marker", server.settings.root_marker);
        try testing.expectEqualStrings("custom-venv", server.settings.venv_path);
        try testing.expect(!server.settings.validation_enabled);
        try testing.expectEqual(@as(usize, 1), server.root_uris.items.len);
        try testing.expectEqualStrings(root_uri, server.root_uris.items[0]);

        const changed = try std.json.parseFromSliceLeaky(Value, a,
            \\{"settings":{"ansible":{"workspace":{"rootMarker":"next-marker"},"python":{"venvPath":"next-venv"},"validation":{"enabled":false}}}}
        , .{});
        try handleNotification(&server, a, "workspace/didChangeConfiguration", changed);
        try testing.expectEqualStrings("next-marker", server.settings.root_marker);
        try testing.expectEqualStrings("next-venv", server.settings.venv_path);
        try testing.expect(!server.settings.validation_enabled);
        try testing.expectEqual(@as(usize, 1), server.root_uris.items.len);
        try testing.expectEqualStrings(root_uri, server.root_uris.items[0]);
    }

    try output.seekTo(0);
    var transport = Transport.init(output, output);
    const initialized = try std.json.parseFromSliceLeaky(Value, a, (try transport.readMessage(a)).?, .{});
    try testing.expectEqual(@as(i64, 1), json_util.field(initialized, "id").?.integer);
    try testing.expect(json_util.field(initialized, "result") != null);
    for (ids) |id| {
        const response = try std.json.parseFromSliceLeaky(Value, a, (try transport.readMessage(a)).?, .{});
        const response_id = json_util.field(response, "id").?;
        switch (id) {
            .integer => |n| try testing.expectEqual(n, response_id.integer),
            .string => |s| try testing.expectEqualStrings(s, response_id.string),
            else => unreachable,
        }
        try testing.expect(json_util.field(response, "result") == null);
        const err = json_util.field(response, "error").?;
        try testing.expectEqual(@as(i64, -32601), json_util.field(err, "code").?.integer);
        try testing.expectEqualStrings("method not found", json_util.string(err, "message").?);
    }
    // Neither the removed notification nor standard configuration emits a response.
    try testing.expectEqual(@as(?[]u8, null), try transport.readMessage(a));
}

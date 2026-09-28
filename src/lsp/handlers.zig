//! Request and notification handlers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");
const capabilities = @import("capabilities.zig");
const sync = @import("sync.zig");
const Server = @import("server.zig").Server;
const providers = @import("../providers/root.zig");

pub fn handleRequest(self: *Server, a: Allocator, id: Value, method: []const u8, params: Value) !void {
    if (std.mem.eql(u8, method, "initialize")) return onInitialize(self, a, id, params);
    if (std.mem.eql(u8, method, "shutdown")) {
        self.shutdown_requested = true;
        return self.sendResult(a, id, Value.null);
    }
    if (std.mem.eql(u8, method, "textDocument/completion"))
        return self.sendResult(a, id, try providers.completion.complete(self, a, params));
    if (std.mem.eql(u8, method, "completionItem/resolve"))
        return self.sendResult(a, id, try providers.completion.resolve(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/hover"))
        return self.sendResult(a, id, try providers.hover.hover(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/definition"))
        return self.sendResult(a, id, try providers.definition.definition(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/implementation"))
        return self.sendResult(a, id, try providers.implementation.implementation(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/references"))
        return self.sendResult(a, id, try providers.references.references(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/semanticTokens/full"))
        return self.sendResult(a, id, try providers.semantic_tokens.full(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/documentSymbol"))
        return self.sendResult(a, id, try providers.document_symbols.documentSymbol(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/codeAction"))
        return self.sendResult(a, id, try providers.code_actions.codeActions(self, a, params));
    return self.sendError(a, id, -32601, "method not found");
}

pub fn handleNotification(self: *Server, a: Allocator, method: []const u8, params: Value) !void {
    if (std.mem.eql(u8, method, "initialized")) {
        self.initialized = true;
        self.docs_service.start(&self.docs, self.pool, &self.ansible_config);
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
        try self.settings.update(params);
        return;
    }
    if (std.mem.eql(u8, method, "workspace/didChangeWorkspaceFolders")) {
        return sync.didChangeWorkspaceFolders(self, params);
    }
    // Unknown notifications are ignored, per the LSP spec.
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

    // Workspace folders.
    var has_folders = false;
    if (json_util.array(params, "workspaceFolders")) |folders| {
        for (folders.items) |f| {
            if (json_util.string(f, "uri")) |uri| {
                try self.root_uris.append(try self.allocator.dupe(u8, uri));
                has_folders = true;
            }
        }
    } else if (json_util.string(params, "rootUri")) |uri| {
        try self.root_uris.append(try self.allocator.dupe(u8, uri));
        has_folders = true;
    }

    // Initialization options may carry settings.
    if (json_util.field(params, "initializationOptions")) |opts| {
        self.settings.update(opts) catch {};
    }

    var result = json_util.obj(a);
    try result.put("capabilities", try capabilities.build(a, encoding_name, has_folders));
    var info = json_util.obj(a);
    try info.put("name", json_util.str("zals"));
    try info.put("version", json_util.str("0.0.0"));
    try result.put("serverInfo", .{ .object = info });

    try self.sendResult(a, id, .{ .object = result });
}

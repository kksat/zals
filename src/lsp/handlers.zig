//! Request and notification handlers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");
const encode = @import("encode.zig");
const capabilities = @import("capabilities.zig");
const sync = @import("sync.zig");
const Server = @import("server.zig").Server;
const Document = @import("../workspace/document.zig").Document;
const providers = @import("../providers/root.zig");
const cursor = @import("../cursor.zig");

pub fn handleRequest(self: *Server, a: Allocator, id: Value, method: []const u8, params: Value) !void {
    if (std.mem.eql(u8, method, "initialize")) return onInitialize(self, a, id, params);
    if (std.mem.eql(u8, method, "shutdown")) {
        self.shutdown_requested = true;
        return self.sendResult(a, id, Value.null);
    }
    if (std.mem.eql(u8, method, "textDocument/completion"))
        return self.sendResult(a, id, try completionResult(self, a, params));
    if (std.mem.eql(u8, method, "completionItem/resolve"))
        return self.sendResult(a, id, try resolveResult(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/hover"))
        return self.sendResult(a, id, try hoverResult(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/definition"))
        return self.sendResult(a, id, try definitionResult(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/implementation"))
        return self.sendResult(a, id, try implementationResult(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/references"))
        return self.sendResult(a, id, try referencesResult(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/semanticTokens/full"))
        return self.sendResult(a, id, try semanticResult(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/documentSymbol"))
        return self.sendResult(a, id, try providers.document_symbols.documentSymbol(self, a, params));
    if (std.mem.eql(u8, method, "workspace/symbol"))
        return self.sendResult(a, id, try providers.workspace_symbols.workspaceSymbol(self, a, params));
    if (std.mem.eql(u8, method, "textDocument/codeAction"))
        return self.sendResult(a, id, try providers.code_actions.codeActions(self, a, params));
    if (std.mem.eql(u8, method, "ansible/refreshConfiguration")) {
        self.settings.reload();
        try self.rebuildWorkspaces();
        try self.warnMissingWorkspace(a);
        return self.sendResult(a, id, Value.null);
    }
    return self.sendError(a, id, -32601, "method not found");
}

pub fn handleNotification(self: *Server, a: Allocator, method: []const u8, params: Value) !void {
    if (std.mem.eql(u8, method, "initialized")) {
        self.initialized = true;
        self.docs_service.start(&self.docs, self.pool, &self.ansible_config);
        var ready = json_util.obj(a);
        try ready.put("modulesCount", json_util.num(self.docs.catalogCount()));
        try self.notify(a, "ansible/docsLibraryReady", .{ .object = ready });
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

fn documentOffset(self: *Server, params: Value) ?struct { doc: *Document, offset: usize } {
    const td = json_util.field(params, "textDocument") orelse return null;
    const uri = json_util.string(td, "uri") orelse return null;
    const pos_v = json_util.field(params, "position") orelse return null;
    const pos = json_util.position(pos_v) orelse return null;
    const doc = self.documents.get(uri) orelse return null;
    const offset = doc.offsetAt(pos) orelse return null;
    return .{ .doc = doc, .offset = offset };
}

fn documentByUri(self: *Server, params: Value) ?*Document {
    const td = json_util.field(params, "textDocument") orelse return null;
    const uri = json_util.string(td, "uri") orelse return null;
    return self.documents.get(uri);
}

fn emptyCompletion(a: Allocator) !Value {
    return encode.completionList(a, .{ .items = &.{} });
}

fn completionResult(self: *Server, a: Allocator, params: Value) !Value {
    const loc = documentOffset(self, params) orelse return emptyCompletion(a);
    if (try providers.collections.completion(self, a, params)) |items| {
        return encode.completionList(a, .{ .items = items });
    }
    var opened = cursor.Doc.open(a, loc.doc.bytes()) catch return emptyCompletion(a);
    defer opened.deinit();
    const lookup = cursor.fromLibrary(&self.docs);
    const cur = try opened.at(loc.doc.uri, loc.offset, lookup);
    return encode.completionList(a, try providers.completion.list(a, cur, lookup));
}

fn resolveResult(self: *Server, a: Allocator, params: Value) !Value {
    const label = json_util.string(params, "label") orelse return params;
    const extra = providers.completion.resolve(a, label, cursor.fromLibrary(&self.docs));
    var obj = switch (params) {
        .object => |o| o,
        else => return params,
    };
    if (extra.detail) |d| try obj.put("detail", json_util.str(d));
    if (extra.documentation) |doc| try obj.put("documentation", try encode.markup(a, doc));
    return .{ .object = obj };
}

fn hoverResult(self: *Server, a: Allocator, params: Value) !Value {
    const loc = documentOffset(self, params) orelse return Value.null;
    var opened = cursor.Doc.open(a, loc.doc.bytes()) catch return Value.null;
    defer opened.deinit();
    const cur = try opened.at(loc.doc.uri, loc.offset, cursor.fromLibrary(&self.docs));
    if (try providers.collections.hover(self, a, params)) |h| return encode.hover(a, h);
    if (cur) |c| switch (c) {
        .role_reference => return encode.hover(a, try providers.role_navigation.hover(self, a, params)),
        else => {},
    };
    if (try providers.role_navigation.parameterHover(self, a, params)) |h| return encode.hover(a, h);
    if (cur) |c| switch (c) {
        .variable => return encode.hover(a, try providers.variable_hover.hover(self, a, params)),
        else => {},
    };
    return encode.hover(a, try providers.hover.format(a, loc.doc, cur));
}

fn definitionResult(self: *Server, a: Allocator, params: Value) !Value {
    return switch (try providers.definition.definition(self, a, params)) {
        .none => Value.null,
        .location => |loc| try encode.location(a, loc),
        .locations => |locs| try encode.locations(a, locs),
    };
}

fn implementationResult(self: *Server, a: Allocator, params: Value) !Value {
    const locs = (try providers.implementation.implementation(self, a, params)) orelse return Value.null;
    if (locs.len == 1) return encode.location(a, locs[0]);
    return encode.locations(a, locs);
}

fn referencesResult(self: *Server, a: Allocator, params: Value) !Value {
    const locs = (try providers.references.references(self, a, params)) orelse return Value.null;
    return encode.locations(a, locs);
}

fn semanticResult(self: *Server, a: Allocator, params: Value) !Value {
    const doc = documentByUri(self, params) orelse return encode.semanticTokens(a, &.{});
    const tokens = try providers.semantic_tokens.collect(a, doc, cursor.fromLibrary(&self.docs));
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

//! Go to definition: module source files, variable definitions, and roles.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");
const variables = @import("../variables/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");
const vs = @import("variable_source.zig");

pub fn definition(self: *Server, a: Allocator, params: Value) !Value {
    if (try variableDefinition(self, a, params)) |result| return result;
    if (try roleDefinition(self, a, params)) |result| return result;
    return moduleDefinition(self, a, params);
}

/// Jump from a variable reference to its visible definitions (ADR-0024).
fn variableDefinition(self: *Server, a: Allocator, params: Value) !?Value {
    const td = json_util.field(params, "textDocument") orelse return null;
    const uri = json_util.string(td, "uri") orelse return null;
    const pos_v = json_util.field(params, "position") orelse return null;
    const pos = json_util.position(pos_v) orelse return null;
    const doc = self.documents.get(uri) orelse return null;
    const offset = doc.offsetAt(pos) orelse return null;

    var src = vs.ServerSource{ .server = self };
    var index = variables.Index.init(a, src.source());
    const cur = (try index.occurrenceAt(a, uri, offset)) orelse return null;
    if (cur.kind != .reference) return null;

    const defs = try index.definitions(a, uri, cur.name);
    if (defs.len == 0) return null;

    var arr = std.json.Array.init(a);
    for (defs) |d| try arr.append(try vs.location(a, self, &index, d));
    return .{ .array = arr };
}

/// Jump from a role reference to the role's argument specs, metadata, or main
/// task file. Returns `Value.null` (stopping the chain) when the cursor is on a
/// role-name position but the role cannot be resolved.
fn roleDefinition(self: *Server, a: Allocator, params: Value) !?Value {
    var cur = util.parseAt(self, a, params) orelse return null;
    defer cur.forest.deinit();
    const arena = cur.forest.allocator();
    const ref = roles.reference.detect(cur.path, cur.forest.text) orelse return null;
    const path = try paths.uriToPath(a, cur.doc.uri);
    const collections = yaml.collections.getDeclaredCollections(arena, cur.path) catch &.{};
    const dir = util.resolveRole(self, a, ref.name, path, collections) orelse return Value.null;
    const target = roles.targets.definitionTarget(a, dir) orelse return Value.null;
    return try util.fileLocation(a, target);
}

fn moduleDefinition(self: *Server, a: Allocator, params: Value) !Value {
    var cur = util.parseAt(self, a, params) orelse return Value.null;
    defer cur.forest.deinit();
    const name = util.currentKey(cur.path) orelse return Value.null;
    const arena = cur.forest.allocator();
    const collections = yaml.collections.getDeclaredCollections(arena, cur.path) catch &.{};
    const mod = self.docs.findModuleInContext(arena, name, collections) orelse return Value.null;
    if (mod.filename.len == 0) return Value.null;
    return try util.fileLocation(a, mod.filename);
}

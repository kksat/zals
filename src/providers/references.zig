//! Find references for Ansible variables (ADR-0025).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("../lsp/json_util.zig");
const Server = @import("../lsp/server.zig").Server;
const variables = @import("../variables/root.zig");
const vs = @import("variable_source.zig");

pub fn references(self: *Server, a: Allocator, params: Value) !Value {
    const td = json_util.field(params, "textDocument") orelse return Value.null;
    const uri = json_util.string(td, "uri") orelse return Value.null;
    const pos_v = json_util.field(params, "position") orelse return Value.null;
    const pos = json_util.position(pos_v) orelse return Value.null;
    const doc = self.documents.get(uri) orelse return Value.null;
    const offset = doc.offsetAt(pos) orelse return Value.null;

    var src = vs.ServerSource{ .server = self };
    var index = variables.Index.init(a, src.source());
    const cur = (try index.occurrenceAt(a, uri, offset)) orelse return Value.null;

    const include_decl = blk: {
        const ctx = json_util.field(params, "context") orelse break :blk false;
        break :blk json_util.boolean(ctx, "includeDeclaration") orelse false;
    };

    const occ = try index.occurrences(a, uri, cur.name);
    std.mem.sort(variables.Occurrence, occ, {}, vs.lessOccurrence);

    var arr = std.json.Array.init(a);
    for (occ) |o| {
        if (o.kind == .definition and !include_decl) continue;
        try arr.append(try vs.location(a, self, &index, o));
    }
    return .{ .array = arr };
}

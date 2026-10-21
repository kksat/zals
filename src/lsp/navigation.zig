//! The navigation protocol adapter. Definition, implementation, references
//! and hover share one shape: decode the text-document position, ask
//! `queries/navigation.Query`, and encode the answer. Semantic precedence and
//! fallbacks live in the query; only JSON and result shapes live here.

const std = @import("std");
const Value = std.json.Value;
const json_util = @import("json_util.zig");
const encode = @import("encode.zig");
const Document = @import("../workspace/document.zig").Document;
const DocumentStore = @import("../workspace/store.zig").DocumentStore;
const navigation = @import("../queries/navigation.zig");
const Context = @import("../queries/context.zig").Context;

/// An open document and the byte offset of a request's LSP position in it.
pub const Cursor = struct { doc: *Document, offset: usize };

/// Decode `textDocument` and `position` params against the open documents,
/// under the session's position encoding. Null when either is missing or the
/// document is not open.
pub fn cursorAt(documents: *DocumentStore, params: Value) ?Cursor {
    const td = json_util.field(params, "textDocument") orelse return null;
    const uri = json_util.string(td, "uri") orelse return null;
    const pos_v = json_util.field(params, "position") orelse return null;
    const pos = json_util.position(pos_v) orelse return null;
    const doc = documents.get(uri) orelse return null;
    const offset = doc.offsetAt(pos) orelse return null;
    return .{ .doc = doc, .offset = offset };
}

pub const Method = enum { definition, implementation, references, hover };

/// The JSON result of a navigation request. Null when the position is not in
/// an open document or the cursor is on nothing navigable.
pub fn result(context: *Context, method: Method, params: Value) !Value {
    const a = context.allocator;
    const at = cursorAt(context.session.documents, params) orelse return Value.null;
    var query = navigation.Query.init(context);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = at.doc.uri, .offset = at.offset }) orelse return Value.null;
    defer subject.deinit();
    switch (method) {
        .definition => return switch (try query.definition(&subject)) {
            .none => Value.null,
            .location => |loc| try encode.location(a, loc),
            .locations => |locs| try encode.locations(a, locs),
        },
        .implementation => {
            const locs = (try query.implementation(&subject)) orelse return Value.null;
            if (locs.len == 1) return encode.location(a, locs[0]);
            return encode.locations(a, locs);
        },
        .references => {
            const reference_context = json_util.field(params, "context") orelse Value.null;
            const include_declaration = json_util.boolean(reference_context, "includeDeclaration") orelse false;
            const locs = (try query.references(&subject, include_declaration)) orelse return Value.null;
            return encode.locations(a, locs);
        },
        .hover => return encode.hover(a, try query.hover(&subject)),
    }
}

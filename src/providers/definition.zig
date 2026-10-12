//! Protocol adapters for semantic navigation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const navigation = @import("../queries/navigation.zig");

pub const Result = navigation.Definition;

pub fn definition(self: *Server, a: Allocator, params: Value) !Result {
    const loc = util.cursorAt(self, params) orelse return .none;
    var query = navigation.Query.init(self, a);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = loc.doc.uri, .offset = loc.offset }) orelse return .none;
    defer subject.deinit();
    return query.definition(&subject);
}

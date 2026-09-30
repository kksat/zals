//! Task-file and vars-file navigation (ADR-0032): go-to-definition opens the
//! referenced file; find-references lists every site that names it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const types = @import("../lsp/types.zig");
const Server = @import("../lsp/server.zig").Server;
const util = @import("util.zig");
const yaml = @import("../yaml/root.zig");
const paths = @import("../paths.zig");
const file_refs = @import("../workspace/file_refs.zig");
const wv = @import("workspace_view.zig");

pub const At = struct {
    ref: file_refs.FileRef,
    uri: []const u8,
    range: types.Range,
};

/// The file reference under the cursor, or null.
pub fn refAt(self: *Server, a: Allocator, params: Value) !?At {
    const loc = util.cursorAt(self, params) orelse return null;
    const path = try paths.uriToPath(a, loc.doc.uri);
    var forest = yaml.parse(a, loc.doc.bytes()) catch return null;
    defer forest.deinit();
    const refs = try file_refs.collect(a, &forest, path, self.workspaceRootFor(a, path));
    for (refs) |r| {
        if (r.start <= loc.offset and loc.offset <= r.end) {
            return .{ .ref = r, .uri = loc.doc.uri, .range = loc.doc.rangeFromOffsets(r.start, r.end) };
        }
    }
    return null;
}

pub const Definition = union(enum) {
    /// Not on a file reference.
    skip,
    /// On a file reference whose target does not exist.
    none,
    location: types.Location,
};

pub fn definition(self: *Server, a: Allocator, params: Value) !Definition {
    const at = (try refAt(self, a, params)) orelse return .skip;
    const f = std.fs.cwd().openFile(at.ref.target, .{}) catch return .none;
    f.close();
    return .{ .location = try util.fileLocation(a, at.ref.target) };
}

/// Every site in the Workspace that names the same resolved file.
pub fn references(self: *Server, a: Allocator, params: Value) !?[]const types.Location {
    const at = (try refAt(self, a, params)) orelse return null;
    var v = (try wv.View.forUri(self, a, at.uri)) orelse {
        const one = try a.alloc(types.Location, 1);
        one[0] = .{ .uri = at.uri, .range = at.range };
        return one;
    };
    var locs = std.array_list.Managed(types.Location).init(a);
    for (v.files) |f| {
        for (f.facts.file_refs) |r| {
            if (r.kind != at.ref.kind or !std.mem.eql(u8, r.target, at.ref.target)) continue;
            try locs.append(try v.location(f.uri, r.start, r.end));
        }
    }
    return try locs.toOwnedSlice();
}

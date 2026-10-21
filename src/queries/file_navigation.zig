//! Task-file and vars-file navigation (ADR-0032): go-to-definition opens the
//! referenced file; find-references lists every site that names it.

const std = @import("std");
const types = @import("../lsp/types.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
const file_refs = @import("../workspace/file_refs.zig");
const Subject = @import("navigation_subject.zig").Subject;

pub const At = struct {
    ref: file_refs.FileRef,
    uri: []const u8,
    range: types.Range,
};

/// The file reference under the cursor, or null.
pub fn refAt(context: *Context, subject: *Subject) !?At {
    const a = context.allocator;
    const path = try context.pathOf(subject.doc.uri);
    const forest = subject.parse(a) orelse return null;
    const refs = try file_refs.collect(a, forest, path, context.workspaceRoot(path));
    for (refs) |r| {
        if (r.start <= subject.offset and subject.offset <= r.end) {
            return .{ .ref = r, .uri = subject.doc.uri, .range = subject.doc.rangeFromOffsets(r.start, r.end) };
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

pub fn definition(context: *Context, subject: *Subject) !Definition {
    const at = (try refAt(context, subject)) orelse return .skip;
    const f = std.fs.cwd().openFile(at.ref.target, .{}) catch return .none;
    f.close();
    return .{ .location = try context_mod.fileLocation(context.allocator, at.ref.target) };
}

/// Every site in the Workspace that names the same resolved file.
pub fn references(context: *Context, subject: *Subject) !?[]const types.Location {
    const a = context.allocator;
    const at = (try refAt(context, subject)) orelse return null;
    const v = (try context.workspaceOf(subject.doc.uri)) orelse {
        const one = try a.alloc(types.Location, 1);
        one[0] = .{ .uri = at.uri, .range = at.range };
        return one;
    };
    var locs = std.array_list.Managed(types.Location).init(a);
    for (v.files) |f| {
        for (f.facts.file_refs) |r| {
            if (r.kind != at.ref.kind or !std.mem.eql(u8, r.target, at.ref.target)) continue;
            try locs.append(try context.location(f.uri, r.start, r.end));
        }
    }
    return try locs.toOwnedSlice();
}

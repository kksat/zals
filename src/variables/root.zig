//! Variable layer: Jinja scanning, definition-site detection, role/playbook
//! scope, and the shared `Index` seam (ADR-0024, ADR-0025).

const std = @import("std");

pub const jinja = @import("jinja.zig");
pub const definitions = @import("definitions.zig");
pub const fields = @import("fields.zig");
pub const bindings = @import("bindings.zig");
pub const scope = @import("scope.zig");
pub const source = @import("source.zig");
pub const index = @import("index.zig");

pub const Index = index.Index;
pub const FileSource = source.FileSource;
pub const DirEntry = source.DirEntry;
pub const Occurrence = index.Occurrence;
pub const OccurrenceKind = index.OccurrenceKind;
pub const Cursor = index.Cursor;
pub const Site = definitions.Site;

test {
    std.testing.refAllDecls(@This());
}

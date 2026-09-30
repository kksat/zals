//! Resolve test-side <marked snippets> into LSP UTF-16 locations. Fixture
//! files contain ordinary Ansible/Jinja, never test anchors or line numbers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

pub const Position = struct { line: u32, character: u32 };
pub const Range = struct { start: Position, end: Position };
pub const Location = struct { uri: []const u8, range: Range };
pub const Cursor = struct { uri: []const u8, position: Position };

pub const Resolver = struct {
    allocator: Allocator,
    fixture: []const u8,
    deps: []const u8,

    pub fn readText(self: Resolver, relative: []const u8) ![]u8 {
        const absolute = try self.path(relative);
        const file = try std.fs.openFileAbsolute(absolute, .{});
        defer file.close();
        return file.readToEndAlloc(self.allocator, 1024 * 1024);
    }

    pub fn cursor(self: Resolver, anchor: model.Anchor) !Cursor {
        const found = try self.marked(anchor);
        var last = found.end - 1;
        while (last > found.start and found.text[last] & 0xc0 == 0x80) : (last -= 1) {}
        return .{
            .uri = try self.uri(anchor.path),
            .position = try positionAt(found.text, last),
        };
    }

    pub fn location(self: Resolver, expectation: model.ExpectedLocation) !Location {
        return switch (expectation) {
            .marked => |anchor| blk: {
                const found = try self.marked(anchor);
                break :blk .{
                    .uri = try self.uri(anchor.path),
                    .range = .{
                        .start = try positionAt(found.text, found.start),
                        .end = try positionAt(found.text, found.end),
                    },
                };
            },
            .file_start => |relative| blk: {
                const absolute = try self.path(relative);
                const file = try std.fs.openFileAbsolute(absolute, .{});
                file.close();
                break :blk .{
                    .uri = try self.uri(relative),
                    .range = .{
                        .start = .{ .line = 0, .character = 0 },
                        .end = .{ .line = 0, .character = 0 },
                    },
                };
            },
        };
    }

    fn marked(self: Resolver, anchor: model.Anchor) !struct { text: []const u8, start: usize, end: usize } {
        const snippet = anchor.snippet;
        const open = std.mem.indexOfScalar(u8, snippet, '<') orelse return error.MissingOpeningMarker;
        const close = std.mem.indexOfScalarPos(u8, snippet, open + 1, '>') orelse return error.MissingClosingMarker;
        if (close == open + 1 or std.mem.indexOfScalar(u8, snippet[open + 1 .. close], '<') != null) {
            return error.InvalidMarker;
        }
        const plain = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
            snippet[0..open], snippet[open + 1 .. close], snippet[close + 1 ..],
        });
        const text = try self.readText(anchor.path);
        const offset = std.mem.indexOf(u8, text, plain) orelse {
            std.debug.print("Missing fixture anchor in {s}: {s}\n", .{ anchor.path, plain });
            return error.AnchorNotFound;
        };
        if (std.mem.indexOfPos(u8, text, offset + 1, plain) != null) {
            std.debug.print("Ambiguous fixture anchor in {s}: {s}\n", .{ anchor.path, plain });
            return error.AnchorNotUnique;
        }
        const start = offset + open;
        return .{ .text = text, .start = start, .end = start + close - open - 1 };
    }

    fn path(self: Resolver, relative: []const u8) ![]const u8 {
        const prefix = "@deps/";
        const root = if (std.mem.startsWith(u8, relative, prefix)) self.deps else self.fixture;
        const tail = if (std.mem.startsWith(u8, relative, prefix)) relative[prefix.len..] else relative;
        if (std.fs.path.isAbsolute(tail) or std.mem.indexOf(u8, tail, "..") != null) return error.InvalidFixturePath;
        return std.fs.path.join(self.allocator, &.{ root, tail });
    }

    fn uri(self: Resolver, relative: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "file://{s}", .{try self.path(relative)});
    }
};

/// LSP positions count UTF-16 code units, not UTF-8 bytes or Unicode scalars.
fn positionAt(text: []const u8, byte_offset: usize) !Position {
    if (byte_offset > text.len) return error.InvalidOffset;
    var result: Position = .{ .line = 0, .character = 0 };
    var i: usize = 0;
    while (i < byte_offset) {
        const width = try std.unicode.utf8ByteSequenceLength(text[i]);
        if (i + width > byte_offset) return error.InvalidCodepointBoundary;
        const point = try std.unicode.utf8Decode(text[i .. i + width]);
        if (point == '\n') {
            result.line += 1;
            result.character = 0;
        } else {
            result.character += if (point > 0xffff) @as(u32, 2) else 1;
        }
        i += width;
    }
    return result;
}

test "UTF-16 positions count a supplementary scalar as two code units" {
    const position = try positionAt("é🚀x", "é🚀".len);
    try std.testing.expectEqual(@as(u32, 0), position.line);
    try std.testing.expectEqual(@as(u32, 3), position.character);
}

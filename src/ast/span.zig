const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,

    pub fn isEmpty(self: Span) bool {
        return self.end <= self.start;
    }

    pub fn clamp(self: Span, len: usize) Span {
        const s = @min(self.start, len);
        const e = @min(@max(self.end, s), len);
        return .{ .start = s, .end = e };
    }
};

pub const FieldSpan = struct {
    name: []const u8,
    span: Span,
};

pub fn lookupFieldSpan(fields: []const FieldSpan, name: []const u8) ?Span {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.span;
    }
    return null;
}

pub const LineCol = struct {
    line: u32,
    column: u32,
};

pub fn lineColAt(text: []const u8, offset: usize) LineCol {
    const clamped = @min(offset, text.len);
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    while (i < clamped) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .column = col };
}

test "span clamp and lineColAt" {
    const text = "line1\n  line2\n";
    const lc = lineColAt(text, 8);
    try std.testing.expectEqual(@as(u32, 2), lc.line);
    try std.testing.expectEqual(@as(u32, 3), lc.column);
    const s = (Span{ .start = 100, .end = 50 }).clamp(text.len);
    try std.testing.expectEqual(text.len, s.start);
    try std.testing.expectEqual(text.len, s.end);
}

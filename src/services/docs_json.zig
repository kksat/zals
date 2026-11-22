const std = @import("std");
const Allocator = std.mem.Allocator;
const docs = @import("docs.zig");

const Scanner = std.json.Scanner;
const Token = std.json.Token;
const TokenType = std.json.TokenType;

const NumberValue = union(enum) {
    integer: i64,
    float: f64,
    number_string: []const u8,
};

fn classifyNumber(text: []const u8) NumberValue {
    if (std.json.isNumberFormattedLikeAnInteger(text)) {
        if (std.fmt.parseInt(i64, text, 10)) |i| {
            return .{ .integer = i };
        } else |_| {
            return .{ .number_string = text };
        }
    }
    const f = std.fmt.parseFloat(f64, text) catch return .{ .number_string = text };
    if (std.math.isFinite(f)) return .{ .float = f };
    return .{ .number_string = text };
}

pub fn validate(scratch: Allocator, bytes: []const u8) bool {
    var scanner = Scanner.initCompleteInput(scratch, bytes);
    defer scanner.deinit();
    scanner.stack.ensureTotalCapacity(64) catch return false;

    const Frame = union(enum) {
        array,
        object: struct {
            keys: std.StringHashMapUnmanaged(void) = .empty,
            expect_key: bool = true,
        },
    };

    var frames = std.ArrayList(Frame).empty;
    defer {
        for (frames.items) |*f| {
            if (f.* == .object) f.object.keys.deinit(scratch);
        }
        frames.deinit(scratch);
    }
    var escaped_keys = std.heap.ArenaAllocator.init(scratch);
    defer escaped_keys.deinit();

    while (true) {
        const in_obj_key = frames.items.len > 0 and
            frames.items[frames.items.len - 1] == .object and
            frames.items[frames.items.len - 1].object.expect_key;

        if (in_obj_key) {
            const tok = scanner.nextAllocMax(escaped_keys.allocator(), .alloc_if_needed, bytes.len) catch return false;
            switch (tok) {
                .object_end => {
                    var closed = frames.pop().?;
                    closed.object.keys.deinit(scratch);
                    if (frames.items.len > 0 and frames.items[frames.items.len - 1] == .object) {
                        frames.items[frames.items.len - 1].object.expect_key = true;
                    }
                },
                .string, .allocated_string => |key| {
                    const gop = frames.items[frames.items.len - 1].object.keys.getOrPut(scratch, key) catch return false;
                    if (gop.found_existing) return false;
                    frames.items[frames.items.len - 1].object.expect_key = false;
                },
                else => return false,
            }
            continue;
        }

        const tok = scanner.next() catch return false;
        switch (tok) {
            .object_begin => {
                frames.append(scratch, .{ .object = .{} }) catch return false;
            },
            .array_begin => {
                frames.append(scratch, .array) catch return false;
            },
            .array_end => {
                if (frames.items.len == 0 or frames.items[frames.items.len - 1] != .array) return false;
                _ = frames.pop();
                if (frames.items.len > 0 and frames.items[frames.items.len - 1] == .object) {
                    frames.items[frames.items.len - 1].object.expect_key = true;
                }
            },
            .object_end => return false,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            .partial_number,
            => continue,
            .string, .number, .true, .false, .null => {
                if (frames.items.len > 0 and frames.items[frames.items.len - 1] == .object) {
                    frames.items[frames.items.len - 1].object.expect_key = true;
                }
            },
            .end_of_document => return frames.items.len == 0,
            else => return false,
        }
    }
}

pub fn topLevelVersion(scratch: Allocator, bytes: []const u8) ?i64 {
    var scanner = Scanner.initCompleteInput(scratch, bytes);
    defer scanner.deinit();
    scanner.stack.ensureTotalCapacity(64) catch return null;
    const first = scanner.nextAllocMax(scratch, .alloc_if_needed, bytes.len) catch return null;
    defer freeTokenString(scratch, first);
    if (first != .object_begin) return null;
    while (true) {
        const key = scanner.nextAllocMax(scratch, .alloc_if_needed, bytes.len) catch return null;
        if (key == .object_end) return null;
        const key_slice = switch (key) {
            .string, .allocated_string => |s| s,
            else => {
                freeTokenString(scratch, key);
                return null;
            },
        };
        const is_version = std.mem.eql(u8, key_slice, "version");
        freeTokenString(scratch, key);
        if (is_version) {
            const value = scanner.nextAllocMax(scratch, .alloc_if_needed, bytes.len) catch return null;
            defer freeTokenString(scratch, value);
            const text = switch (value) {
                .number => |t| t,
                .allocated_number => |t| t,
                else => return null,
            };
            return switch (classifyNumber(text)) {
                .integer => |i| i,
                .float => |f| blk: {
                    if (f < -9223372036854775808.0 or f >= 9223372036854775808.0) break :blk null;
                    break :blk @intFromFloat(f);
                },
                .number_string => null,
            };
        }
        scanner.skipValue() catch return null;
    }
}

pub const Parser = struct {
    arena: Allocator,
    scratch: Allocator,
    max_value_len: usize,
    scanner: Scanner,

    const KeyToken = struct {
        slice: []const u8,
        allocated: bool,

        fn deinit(self: KeyToken, scratch: Allocator) void {
            if (self.allocated) scratch.free(self.slice);
        }
    };

    const FirstArrayString = struct {
        non_empty: bool = false,
        first: ?[]const u8 = null,
    };

    pub fn init(arena: Allocator, scratch: Allocator, input: []const u8) Parser {
        return .{
            .arena = arena,
            .scratch = scratch,
            .max_value_len = input.len,
            .scanner = Scanner.initCompleteInput(scratch, input),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.scanner.deinit();
    }

    pub fn moduleMap(self: *Parser, out: *std.ArrayList(docs.Module)) !void {
        if ((try self.peek()) != .object_begin) return;
        _ = try self.tokenScratch();
        while (try self.nextKey()) |key| {
            defer key.deinit(self.scratch);
            try self.moduleEntry(key.slice, out);
        }
    }

    pub fn metadataDump(self: *Parser, out: *std.ArrayList(docs.Module)) !bool {
        if ((try self.peek()) != .object_begin) return false;
        _ = try self.tokenScratch();
        while (try self.nextKey()) |key| {
            defer key.deinit(self.scratch);
            if (!std.mem.eql(u8, key.slice, "all")) {
                try self.skip();
                continue;
            }
            if ((try self.peek()) != .object_begin) {
                try self.skip();
                continue;
            }
            _ = try self.tokenScratch();
            while (try self.nextKey()) |inner| {
                defer inner.deinit(self.scratch);
                if (std.mem.eql(u8, inner.slice, "module") and (try self.peek()) == .object_begin) {
                    try self.moduleMap(out);
                    return true;
                }
                try self.skip();
            }
        }
        return false;
    }

    pub fn catalogEntries(self: *Parser, out: *std.ArrayList(docs.CatalogEntry)) !void {
        if ((try self.peek()) != .object_begin) return;
        _ = try self.tokenScratch();
        while (try self.nextKey()) |key| {
            defer key.deinit(self.scratch);
            const desc = if ((try self.peek()) == .object_begin)
                try self.objectDescription()
            else blk: {
                try self.skip();
                break :blk "";
            };
            const name = try self.arena.dupe(u8, key.slice);
            try out.append(self.scratch, .{ .name = name, .description = desc });
        }
    }

    pub fn cacheDocument(self: *Parser, out: *CacheDocument) !void {
        if ((try self.peek()) != .object_begin) return error.UnexpectedToken;
        _ = try self.tokenScratch();
        while (try self.nextKey()) |key| {
            defer key.deinit(self.scratch);
            if (std.mem.eql(u8, key.slice, "ansible_version")) {
                if ((try self.peek()) == .string) {
                    out.ansible_version = try self.keepString();
                } else {
                    try self.skip();
                }
            } else if (std.mem.eql(u8, key.slice, "complete")) {
                out.complete = (try self.peek()) == .true;
                try self.skip();
            } else if (std.mem.eql(u8, key.slice, "catalog")) {
                if ((try self.peek()) != .object_begin) {
                    try self.skip();
                    continue;
                }
                _ = try self.tokenScratch();
                while (try self.nextKey()) |entry_key| {
                    defer entry_key.deinit(self.scratch);
                    const kept = try self.arena.dupe(u8, entry_key.slice);
                    const desc = if ((try self.peek()) == .string)
                        try self.keepString()
                    else blk: {
                        try self.skip();
                        break :blk "";
                    };
                    try out.catalog.append(self.scratch, .{ .name = kept, .description = desc });
                }
            } else if (std.mem.eql(u8, key.slice, "modules")) {
                if ((try self.peek()) != .object_begin) {
                    try self.skip();
                    continue;
                }
                _ = try self.tokenScratch();
                while (try self.nextKey()) |mod_key| {
                    defer mod_key.deinit(self.scratch);
                    const kept = try self.arena.dupe(u8, mod_key.slice);
                    try self.cacheModule(kept, out);
                }
            } else {
                try self.skip();
            }
        }
    }

    fn cacheModule(self: *Parser, name: []const u8, out: *CacheDocument) !void {
        var m = docs.Module{ .name = name, .description = "", .filename = "" };
        if ((try self.peek()) == .object_begin) {
            _ = try self.tokenScratch();
            while (try self.nextKey()) |key| {
                defer key.deinit(self.scratch);
                if (std.mem.eql(u8, key.slice, "description")) {
                    if ((try self.peek()) == .string) m.description = try self.keepString() else try self.skip();
                } else if (std.mem.eql(u8, key.slice, "long_description")) {
                    m.long_description = try self.cacheStringList();
                } else if (std.mem.eql(u8, key.slice, "requirements")) {
                    m.requirements = try self.cacheStringList();
                } else if (std.mem.eql(u8, key.slice, "notes")) {
                    m.notes = try self.cacheStringList();
                } else if (std.mem.eql(u8, key.slice, "deprecated")) {
                    m.deprecated = (try self.peek()) == .true;
                    try self.skip();
                } else if (std.mem.eql(u8, key.slice, "filename")) {
                    if ((try self.peek()) == .string) m.filename = try self.keepString() else try self.skip();
                } else if (std.mem.eql(u8, key.slice, "options")) {
                    if ((try self.peek()) == .object_begin) {
                        _ = try self.tokenScratch();
                        m.options = try self.cacheOptionList();
                    } else {
                        try self.skip();
                    }
                } else {
                    try self.skip();
                }
            }
        } else {
            try self.skip();
        }
        try out.modules.append(self.scratch, m);
    }

    fn cacheOptionList(self: *Parser) ParseError![]const docs.Option {
        var list = std.ArrayList(docs.Option).empty;
        defer list.deinit(self.scratch);
        while (try self.nextKey()) |key| {
            defer key.deinit(self.scratch);
            var opt = docs.Option{
                .name = try self.arena.dupe(u8, key.slice),
                .description = "",
                .type = "",
            };
            if ((try self.peek()) == .object_begin) {
                _ = try self.tokenScratch();
                try self.cacheOptionFields(&opt);
            } else {
                try self.skip();
            }
            try list.append(self.scratch, opt);
        }
        return try self.arena.dupe(docs.Option, list.items);
    }

    fn cacheOptionFields(self: *Parser, opt: *docs.Option) ParseError!void {
        while (try self.nextKey()) |key| {
            defer key.deinit(self.scratch);
            if (std.mem.eql(u8, key.slice, "description")) {
                if ((try self.peek()) == .string) opt.description = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key.slice, "type")) {
                if ((try self.peek()) == .string) opt.type = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key.slice, "required")) {
                opt.required = (try self.peek()) == .true;
                try self.skip();
            } else if (std.mem.eql(u8, key.slice, "elements")) {
                if ((try self.peek()) == .string) opt.elements = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key.slice, "default")) {
                if ((try self.peek()) == .string) opt.default = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key.slice, "suboptions")) {
                if ((try self.peek()) == .object_begin) {
                    _ = try self.tokenScratch();
                    opt.suboptions = try self.cacheOptionList();
                } else {
                    try self.skip();
                }
            } else {
                try self.skip();
            }
        }
    }

    fn cacheStringList(self: *Parser) ![]const []const u8 {
        if ((try self.peek()) != .array_begin) {
            try self.skip();
            return &.{};
        }
        return self.stringList(null);
    }

    fn objectDescription(self: *Parser) ![]const u8 {
        _ = try self.tokenScratch();
        var desc_string: ?[]u8 = null;
        defer if (desc_string) |s| self.scratch.free(s);
        var desc_array_non_empty = false;
        var desc_array_first: ?[]u8 = null;
        defer if (desc_array_first) |s| self.scratch.free(s);
        var short_desc: ?[]u8 = null;
        defer if (short_desc) |s| self.scratch.free(s);

        while (try self.nextKey()) |key| {
            defer key.deinit(self.scratch);
            if (std.mem.eql(u8, key.slice, "description")) {
                switch (try self.peek()) {
                    .string => {
                        if (desc_string) |old| self.scratch.free(old);
                        desc_string = try self.allocString(self.scratch);
                    },
                    .array_begin => {
                        _ = try self.tokenScratch();
                        var idx: usize = 0;
                        while ((try self.peek()) != .array_end) : (idx += 1) {
                            if (idx == 0) {
                                desc_array_non_empty = true;
                                if ((try self.peek()) == .string) {
                                    if (desc_array_first) |old| self.scratch.free(old);
                                    desc_array_first = try self.allocString(self.scratch);
                                } else {
                                    try self.skip();
                                }
                            } else {
                                try self.skip();
                            }
                        }
                        _ = try self.tokenScratch();
                    },
                    else => try self.skip(),
                }
            } else if (std.mem.eql(u8, key.slice, "short_description")) {
                if ((try self.peek()) == .string) {
                    if (short_desc) |old| self.scratch.free(old);
                    short_desc = try self.allocString(self.scratch);
                } else {
                    try self.skip();
                }
            } else {
                try self.skip();
            }
        }
        const chosen: []const u8 = if (desc_string) |s|
            s
        else if (desc_array_non_empty)
            desc_array_first orelse ""
        else
            short_desc orelse "";
        if (chosen.len == 0) return "";
        return try self.arena.dupe(u8, chosen);
    }

    fn moduleEntry(self: *Parser, name: []const u8, out: *std.ArrayList(docs.Module)) !void {
        var m = docs.Module{ .name = "", .description = "", .filename = "" };
        var have_doc = false;
        if ((try self.peek()) == .object_begin) {
            _ = try self.tokenScratch();
            while (try self.nextKey()) |key| {
                defer key.deinit(self.scratch);
                if (std.mem.eql(u8, key.slice, "doc")) {
                    have_doc = true;
                    if ((try self.peek()) == .object_begin) {
                        _ = try self.tokenScratch();
                        try self.docFields(&m);
                    } else {
                        try self.skip();
                    }
                } else {
                    try self.skip();
                }
            }
        } else {
            try self.skip();
        }
        if (have_doc) {
            m.name = try self.arena.dupe(u8, name);
            try out.append(self.scratch, m);
        }
    }

    fn docFields(self: *Parser, m: *docs.Module) !void {
        var short_desc: ?[]const u8 = null;
        var desc_string: ?[]const u8 = null;
        var desc_first: ?[]const u8 = null;
        var long_description: []const []const u8 = &.{};
        var requirements: []const []const u8 = &.{};
        var notes: []const []const u8 = &.{};
        while (try self.nextKey()) |key| {
            defer key.deinit(self.scratch);
            if (std.mem.eql(u8, key.slice, "short_description")) {
                if ((try self.peek()) == .string) short_desc = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key.slice, "description")) {
                switch (try self.peek()) {
                    .string => {
                        const s = try self.keepString();
                        desc_string = s;
                        const one = try self.arena.alloc([]const u8, 1);
                        one[0] = s;
                        long_description = one;
                    },
                    .array_begin => long_description = try self.stringList(&desc_first),
                    else => try self.skip(),
                }
            } else if (std.mem.eql(u8, key.slice, "requirements")) {
                requirements = try self.stringList(null);
            } else if (std.mem.eql(u8, key.slice, "notes")) {
                notes = try self.stringList(null);
            } else if (std.mem.eql(u8, key.slice, "deprecated")) {
                m.deprecated = true;
                try self.skip();
            } else if (std.mem.eql(u8, key.slice, "filename")) {
                if ((try self.peek()) == .string) m.filename = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key.slice, "options")) {
                if ((try self.peek()) == .object_begin) {
                    _ = try self.tokenScratch();
                    m.options = try self.optionList();
                } else {
                    try self.skip();
                }
            } else {
                try self.skip();
            }
        }
        m.description = short_desc orelse desc_string orelse desc_first orelse "";
        m.long_description = long_description;
        m.requirements = requirements;
        m.notes = notes;
    }

    const ParseError = WriteError || Scanner.SkipError || error{UnexpectedToken};

    fn optionList(self: *Parser) ParseError![]const docs.Option {
        var list = std.ArrayList(docs.Option).empty;
        defer list.deinit(self.scratch);
        while (try self.nextKey()) |key| {
            defer key.deinit(self.scratch);
            var opt = docs.Option{
                .name = try self.arena.dupe(u8, key.slice),
                .description = "",
                .type = "",
            };
            if ((try self.peek()) == .object_begin) {
                _ = try self.tokenScratch();
                try self.optionFields(&opt);
            } else {
                try self.skip();
            }
            try list.append(self.scratch, opt);
        }
        return try self.arena.dupe(docs.Option, list.items);
    }

    fn optionFields(self: *Parser, opt: *docs.Option) ParseError!void {
        var short_desc: ?[]const u8 = null;
        var desc_string: ?[]const u8 = null;
        var desc_array: FirstArrayString = .{};
        var suboptions: ?[]const docs.Option = null;
        while (try self.nextKey()) |key| {
            defer key.deinit(self.scratch);
            if (std.mem.eql(u8, key.slice, "description")) {
                switch (try self.peek()) {
                    .string => desc_string = try self.keepString(),
                    .array_begin => desc_array = try self.firstArrayString(),
                    else => try self.skip(),
                }
            } else if (std.mem.eql(u8, key.slice, "short_description")) {
                if ((try self.peek()) == .string) short_desc = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key.slice, "type")) {
                if ((try self.peek()) == .string) opt.type = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key.slice, "required")) {
                opt.required = (try self.peek()) == .true;
                try self.skip();
            } else if (std.mem.eql(u8, key.slice, "elements")) {
                if ((try self.peek()) == .string) opt.elements = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key.slice, "default")) {
                opt.default = try self.defaultValue();
            } else if (std.mem.eql(u8, key.slice, "suboptions")) {
                if ((try self.peek()) == .object_begin) {
                    _ = try self.tokenScratch();
                    suboptions = try self.optionList();
                } else {
                    try self.skip();
                }
            } else {
                try self.skip();
            }
        }
        opt.description = if (desc_string) |s|
            s
        else if (desc_array.non_empty)
            desc_array.first orelse ""
        else
            short_desc orelse "";
        opt.suboptions = suboptions orelse &.{};
    }

    fn firstArrayString(self: *Parser) !FirstArrayString {
        _ = try self.tokenScratch();
        var out = FirstArrayString{};
        var idx: usize = 0;
        while ((try self.peek()) != .array_end) : (idx += 1) {
            if (idx == 0) {
                out.non_empty = true;
                if ((try self.peek()) == .string) {
                    out.first = try self.keepString();
                } else {
                    try self.skip();
                }
            } else {
                try self.skip();
            }
        }
        _ = try self.tokenScratch();
        return out;
    }

    fn defaultValue(self: *Parser) !?[]const u8 {
        switch (try self.peek()) {
            .null => {
                _ = try self.tokenScratch();
                return null;
            },
            .true => {
                _ = try self.tokenScratch();
                return "true";
            },
            .false => {
                _ = try self.tokenScratch();
                return "false";
            },
            .number => {
                const tok = try self.tokenScratch();
                defer freeTokenString(self.scratch, tok);
                const text = switch (tok) {
                    .number => |t| t,
                    .allocated_number => |t| t,
                    else => return null,
                };
                return switch (classifyNumber(text)) {
                    .integer => |i| try std.fmt.allocPrint(self.arena, "{d}", .{i}),
                    .float => |f| try std.fmt.allocPrint(self.arena, "{d}", .{f}),
                    .number_string => |s| try self.arena.dupe(u8, s),
                };
            },
            .string => return try self.keepString(),
            .array_begin, .object_begin => return try self.jsonText(),
            else => {
                try self.skip();
                return null;
            },
        }
    }

    fn jsonText(self: *Parser) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(self.scratch);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try self.writeJson(&jw);
        return try self.arena.dupe(u8, aw.written());
    }

    const WriteError = std.Io.Writer.Error || Allocator.Error || Scanner.AllocError || Scanner.PeekError || error{UnexpectedToken};

    fn writeJson(self: *Parser, jw: *std.json.Stringify) WriteError!void {
        const tok = try self.tokenScratch();
        defer freeTokenString(self.scratch, tok);
        switch (tok) {
            .object_begin => {
                try jw.beginObject();
                while (try self.nextKey()) |key| {
                    defer key.deinit(self.scratch);
                    try jw.objectField(key.slice);
                    try self.writeJson(jw);
                }
                try jw.endObject();
            },
            .array_begin => {
                try jw.beginArray();
                while ((try self.peek()) != .array_end) {
                    try self.writeJson(jw);
                }
                const end_tok = try self.tokenScratch();
                defer freeTokenString(self.scratch, end_tok);
                if (end_tok != .array_end) return error.UnexpectedToken;
                try jw.endArray();
            },
            .array_end, .object_end, .end_of_document => return error.UnexpectedToken,
            else => try writeJsonToken(jw, tok),
        }
    }

    fn writeJsonToken(jw: *std.json.Stringify, tok: Token) (std.Io.Writer.Error || error{UnexpectedToken})!void {
        switch (tok) {
            .string, .allocated_string => |s| try jw.write(s),
            .number, .allocated_number => |text| {
                switch (classifyNumber(text)) {
                    .integer => |i| try jw.write(i),
                    .float => |f| try jw.write(f),
                    .number_string => |s| try jw.print("{s}", .{s}),
                }
            },
            .true => try jw.write(true),
            .false => try jw.write(false),
            .null => try jw.write(null),
            else => return error.UnexpectedToken,
        }
    }

    fn stringList(self: *Parser, first: ?*?[]const u8) ![]const []const u8 {
        switch (try self.peek()) {
            .string => {
                const s = try self.keepString();
                if (first) |f| f.* = s;
                const one = try self.arena.alloc([]const u8, 1);
                one[0] = s;
                return one;
            },
            .array_begin => {
                _ = try self.tokenScratch();
                var list = std.ArrayList([]const u8).empty;
                defer list.deinit(self.scratch);
                var idx: usize = 0;
                while ((try self.peek()) != .array_end) : (idx += 1) {
                    if ((try self.peek()) == .string) {
                        const s = try self.keepString();
                        if (idx == 0) {
                            if (first) |f| f.* = s;
                        }
                        try list.append(self.scratch, s);
                    } else {
                        try self.skip();
                    }
                }
                _ = try self.tokenScratch();
                return try self.arena.dupe([]const u8, list.items);
            },
            else => {
                try self.skip();
                return &.{};
            },
        }
    }

    fn nextKey(self: *Parser) !?KeyToken {
        const tok = try self.tokenScratch();
        return switch (tok) {
            .object_end => null,
            .string => |s| .{ .slice = s, .allocated = false },
            .allocated_string => |s| .{ .slice = s, .allocated = true },
            else => {
                freeTokenString(self.scratch, tok);
                return error.UnexpectedToken;
            },
        };
    }

    fn tokenScratch(self: *Parser) Scanner.AllocError!Token {
        return self.scanner.nextAllocMax(self.scratch, .alloc_if_needed, self.max_value_len);
    }

    fn peek(self: *Parser) Scanner.PeekError!TokenType {
        return self.scanner.peekNextTokenType();
    }

    fn skip(self: *Parser) Scanner.SkipError!void {
        return self.scanner.skipValue();
    }

    fn allocString(self: *Parser, allocator: Allocator) ![]u8 {
        const tok = try self.scanner.nextAllocMax(allocator, .alloc_always, self.max_value_len);
        return switch (tok) {
            .allocated_string => |s| s,
            .string => |s| try allocator.dupe(u8, s),
            else => {
                freeTokenString(allocator, tok);
                return error.UnexpectedToken;
            },
        };
    }

    fn keepString(self: *Parser) ![]const u8 {
        return self.allocString(self.arena);
    }
};

pub const CacheDocument = struct {
    ansible_version: ?[]const u8 = null,
    complete: bool = false,
    catalog: std.ArrayList(docs.CatalogEntry) = .empty,
    modules: std.ArrayList(docs.Module) = .empty,

    pub fn deinit(self: *CacheDocument, scratch: Allocator) void {
        self.catalog.deinit(scratch);
        self.modules.deinit(scratch);
    }
};

fn freeTokenString(scratch: Allocator, tok: Token) void {
    switch (tok) {
        .allocated_string => |s| scratch.free(s),
        .allocated_number => |s| scratch.free(s),
        else => {},
    }
}

test "module map ingestion matches the documented shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{
        \\  "ns.one": {"doc": {"short_description": "First", "filename": "/x/one.py",
        \\      "description": ["Long one", "Long two"],
        \\      "options": {"path": {"description": ["A path"], "type": "str", "required": true},
        \\                  "mode": {"type": "str", "default": "0600", "elements": "str"}}}},
        \\  "ns.two": {"doc": {"description": "Plain string", "filename": "/x/two.py",
        \\      "notes": "single note", "deprecated": {}, "options": {}}},
        \\  "ns.bad": "not an object",
        \\  "ns.nodoc": {"metadata": {}}
        \\}
    ;
    var parser = Parser.init(arena.allocator(), std.testing.allocator, input);
    defer parser.deinit();
    var modules = std.ArrayList(docs.Module).empty;
    defer modules.deinit(std.testing.allocator);
    try parser.moduleMap(&modules);
    try std.testing.expectEqual(@as(usize, 2), modules.items.len);

    const one = modules.items[0];
    try std.testing.expectEqualStrings("ns.one", one.name);
    try std.testing.expectEqualStrings("First", one.description);
    try std.testing.expectEqualStrings("/x/one.py", one.filename);
    try std.testing.expectEqual(@as(usize, 2), one.long_description.len);
    try std.testing.expectEqualStrings("Long one", one.long_description[0]);
    try std.testing.expect(!one.deprecated);
    try std.testing.expectEqual(@as(usize, 2), one.options.len);
    try std.testing.expectEqualStrings("path", one.options[0].name);
    try std.testing.expectEqualStrings("A path", one.options[0].description);
    try std.testing.expect(one.options[0].required);
    try std.testing.expectEqualStrings("0600", one.options[1].default.?);

    const two = modules.items[1];
    try std.testing.expectEqualStrings("Plain string", two.description);
    try std.testing.expectEqual(@as(usize, 1), two.notes.len);
    try std.testing.expectEqualStrings("single note", two.notes[0]);
    try std.testing.expect(two.deprecated);
    try std.testing.expectEqual(@as(usize, 0), two.options.len);
}

test "metadata dump requires all.module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(
        arena.allocator(),
        std.testing.allocator,
        "{\"all\": {\"module\": {\"ns.one\": {\"doc\": {\"short_description\": \"First\"}}}}}",
    );
    defer parser.deinit();
    var modules = std.ArrayList(docs.Module).empty;
    defer modules.deinit(std.testing.allocator);
    try std.testing.expect(try parser.metadataDump(&modules));
    try std.testing.expectEqual(@as(usize, 1), modules.items.len);

    var missing = Parser.init(arena.allocator(), std.testing.allocator, "{\"all\": {}}");
    defer missing.deinit();
    try std.testing.expect(!(try missing.metadataDump(&modules)));
}

test "suboptions, defaults of every kind, and cache documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"version": 3, "ansible_version": "ansible [core 2.17]", "complete": true,
        \\ "catalog": {"ns.one": "one line"},
        \\ "modules": {"ns.one": {"description": "one", "long_description": ["a", "b"],
        \\     "requirements": [], "notes": ["n"], "deprecated": false, "filename": "/x",
        \\     "options": {"path": {"description": "A path", "type": "str", "required": true,
        \\         "default": "5", "suboptions": {"inner": {"type": "int", "default": "{\"k\":[1,2]}"}}},
        \\         "flag": {"default": "true"}, "off": {"default": "false"}, "none": {"default": null}}}}}
    ;
    try std.testing.expect(validate(std.testing.allocator, input));
    try std.testing.expectEqual(@as(i64, 3), topLevelVersion(std.testing.allocator, input).?);

    var parser = Parser.init(arena.allocator(), std.testing.allocator, input);
    defer parser.deinit();
    var cache = CacheDocument{};
    defer cache.deinit(std.testing.allocator);
    try parser.cacheDocument(&cache);
    try std.testing.expectEqualStrings("ansible [core 2.17]", cache.ansible_version.?);
    try std.testing.expect(cache.complete);
    try std.testing.expectEqual(@as(usize, 1), cache.catalog.items.len);
    try std.testing.expectEqualStrings("one line", cache.catalog.items[0].description);

    const m = cache.modules.items[0];
    try std.testing.expectEqualStrings("one", m.description);
    try std.testing.expectEqual(@as(usize, 2), m.long_description.len);
    try std.testing.expectEqual(@as(usize, 0), m.requirements.len);
    try std.testing.expectEqual(@as(usize, 1), m.notes.len);
    try std.testing.expectEqualStrings("5", m.options[0].default.?);
    const inner = m.options[0].suboptions[0];
    try std.testing.expectEqualStrings("inner", inner.name);
    try std.testing.expectEqualStrings("{\"k\":[1,2]}", inner.default.?);
    try std.testing.expectEqualStrings("true", m.options[1].default.?);
    try std.testing.expectEqualStrings("false", m.options[2].default.?);
    try std.testing.expect(m.options[3].default == null);
}

test "description fallback matches element-0 and short_description rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{
        \\  "ns.non_str_first": {"doc": {
        \\    "description": [null, "later"],
        \\    "options": {
        \\      "non_str_first": {"description": [null, "later"], "short_description": "short"},
        \\      "empty_arr": {"description": [], "short_description": "short"},
        \\      "multi_para": {"description": ["first", "second", "third"]}
        \\    }
        \\  }}
        \\}
    ;
    var parser = Parser.init(arena.allocator(), std.testing.allocator, input);
    defer parser.deinit();
    var modules = std.ArrayList(docs.Module).empty;
    defer modules.deinit(std.testing.allocator);
    try parser.moduleMap(&modules);

    const m = modules.items[0];
    try std.testing.expectEqualStrings("", m.description);
    try std.testing.expectEqual(@as(usize, 1), m.long_description.len);
    try std.testing.expectEqualStrings("later", m.long_description[0]);

    try std.testing.expectEqualStrings("", m.getOption("non_str_first").?.description);
    try std.testing.expectEqualStrings("short", m.getOption("empty_arr").?.description);
    try std.testing.expectEqualStrings("first", m.getOption("multi_para").?.description);
}

test "numeric defaults preserve overflowing integers and non-finite floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{
        \\  "ns.nums": {"doc": {"options": {
        \\    "big": {"default": 18446744073709551615},
        \\    "inf": {"default": 1e400},
        \\    "arr": {"default": [18446744073709551615, 1e400, 2]},
        \\    "obj": {"default": {"k": 18446744073709551615, "f": 1e400}},
        \\    "b": {"default": true},
        \\    "n": {"default": null}
        \\  }}}
        \\}
    ;
    var parser = Parser.init(arena.allocator(), std.testing.allocator, input);
    defer parser.deinit();
    var modules = std.ArrayList(docs.Module).empty;
    defer modules.deinit(std.testing.allocator);
    try parser.moduleMap(&modules);

    const m = modules.items[0];
    try std.testing.expectEqualStrings("18446744073709551615", m.getOption("big").?.default.?);
    try std.testing.expectEqualStrings("1e400", m.getOption("inf").?.default.?);
    try std.testing.expectEqualStrings("[18446744073709551615,1e400,2]", m.getOption("arr").?.default.?);
    try std.testing.expectEqualStrings("{\"k\":18446744073709551615,\"f\":1e400}", m.getOption("obj").?.default.?);
    try std.testing.expectEqualStrings("true", m.getOption("b").?.default.?);
    try std.testing.expect(m.getOption("n").?.default == null);
}

test "catalogEntries retains object descriptions and empties plain strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"ns.str": "plain string", "ns.obj": {"description": "from object"}, "ns.arr": {"description": ["first", "second"]}}
    ;
    var parser = Parser.init(arena.allocator(), std.testing.allocator, input);
    defer parser.deinit();
    var entries = std.ArrayList(docs.CatalogEntry).empty;
    defer entries.deinit(std.testing.allocator);
    try parser.catalogEntries(&entries);
    try std.testing.expectEqual(@as(usize, 3), entries.items.len);
    try std.testing.expectEqualStrings("", entries.items[0].description);
    try std.testing.expectEqualStrings("from object", entries.items[1].description);
    try std.testing.expectEqualStrings("first", entries.items[2].description);
}

test "cache options keep string-only default and description semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"version": 3, "modules": {"ns.one": {"options": {
        \\  "o": {"short_description": "ignored", "default": 42}
        \\}}}}
    ;
    var parser = Parser.init(arena.allocator(), std.testing.allocator, input);
    defer parser.deinit();
    var cache = CacheDocument{};
    defer cache.deinit(std.testing.allocator);
    try parser.cacheDocument(&cache);
    const o = cache.modules.items[0].options[0];
    try std.testing.expectEqualStrings("", o.description);
    try std.testing.expect(o.default == null);
}

test "escaped strings round trip through retained copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\{"ns.one": {"doc": {"short_description": "quote \" and unicode é",
        \\    "options": {"na\"me": {"description": "esc", "type": "str"}}}}}
    ;
    var parser = Parser.init(arena.allocator(), std.testing.allocator, input);
    defer parser.deinit();
    var modules = std.ArrayList(docs.Module).empty;
    defer modules.deinit(std.testing.allocator);
    try parser.moduleMap(&modules);
    try std.testing.expectEqualStrings("quote \" and unicode é", modules.items[0].description);
    try std.testing.expectEqualStrings("na\"me", modules.items[0].options[0].name);
}

test "validate rejects malformed documents and duplicate keys; topLevelVersion handles edge values" {
    try std.testing.expect(!validate(std.testing.allocator, "boom"));
    try std.testing.expect(!validate(std.testing.allocator, "{\"a\":"));
    try std.testing.expect(!validate(std.testing.allocator, "{\"version\": 3, \"version\": 4}"));
    try std.testing.expect(!validate(std.testing.allocator, "{\"a\": {\"k\": 1, \"\\u006b\": 2}}"));
    try std.testing.expect(validate(std.testing.allocator, "[]"));
    try std.testing.expect(validate(std.testing.allocator, "{\"a\": {\"k\": 1}, \"b\": {\"k\": 2}}"));

    try std.testing.expect(topLevelVersion(std.testing.allocator, "[1]") == null);
    try std.testing.expect(topLevelVersion(std.testing.allocator, "{}") == null);
    try std.testing.expect(topLevelVersion(std.testing.allocator, "{\"version\": \"bad\\\"ver\"}") == null);
    try std.testing.expect(topLevelVersion(std.testing.allocator, "{\"version\": 18446744073709551615}") == null);
    try std.testing.expect(topLevelVersion(std.testing.allocator, "{\"version\": 1e400}") == null);
    try std.testing.expect(topLevelVersion(std.testing.allocator, "{\"version\": 1e20}") == null);
    try std.testing.expectEqual(@as(i64, 3), topLevelVersion(std.testing.allocator, "{\"version\": 3.0}").?);
}

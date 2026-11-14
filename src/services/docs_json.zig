const std = @import("std");
const Allocator = std.mem.Allocator;
const docs = @import("docs.zig");

const Scanner = std.json.Scanner;
const Token = std.json.Token;
const TokenType = std.json.TokenType;

pub fn validate(scratch: Allocator, bytes: []const u8) bool {
    var scanner = Scanner.initCompleteInput(scratch, bytes);
    defer scanner.deinit();
    scanner.stack.ensureTotalCapacity(64) catch return false;
    while (true) {
        const tok = scanner.next() catch return false;
        switch (tok) {
            .end_of_document => return true,
            else => continue,
        }
    }
}

pub fn topLevelVersion(scratch: Allocator, bytes: []const u8) ?i64 {
    var scanner = Scanner.initCompleteInput(scratch, bytes);
    defer scanner.deinit();
    scanner.stack.ensureTotalCapacity(64) catch return null;
    const first = scanner.nextAlloc(scratch, .alloc_if_needed) catch return null;
    freeTokenString(scratch, first);
    if (first != .object_begin) return null;
    while (true) {
        const key = scanner.nextAlloc(scratch, .alloc_if_needed) catch return null;
        if (key == .object_end) return null;
        const is_version = std.mem.eql(u8, tokenString(key), "version");
        freeTokenString(scratch, key);
        if (is_version) {
            const value = scanner.nextAlloc(scratch, .alloc_if_needed) catch return null;
            const text = switch (value) {
                .number => |t| t,
                .allocated_number => |t| t,
                else => return null,
            };
            if (std.fmt.parseInt(i64, text, 10)) |i| return i else |_| {}
            const f = std.fmt.parseFloat(f64, text) catch return null;
            return @intFromFloat(f);
        }
        scanner.skipValue() catch return null;
    }
}

pub const Parser = struct {
    arena: Allocator,
    scanner: Scanner,

    pub fn init(arena: Allocator, scratch: Allocator, input: []const u8) Parser {
        return .{
            .arena = arena,
            .scanner = Scanner.initCompleteInput(scratch, input),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.scanner.deinit();
    }

    pub fn moduleMap(self: *Parser, out: *std.ArrayList(docs.Module)) !void {
        if ((try self.peek()) != .object_begin) return;
        _ = try self.token();
        while (try self.nextKey()) |name| {
            const kept = try self.arena.dupe(u8, name);
            try self.moduleEntry(kept, out);
        }
    }

    pub fn metadataDump(self: *Parser, out: *std.ArrayList(docs.Module)) !bool {
        if ((try self.peek()) != .object_begin) return false;
        _ = try self.token();
        while (try self.nextKey()) |key| {
            if (!std.mem.eql(u8, key, "all")) {
                try self.skip();
                continue;
            }
            if ((try self.peek()) != .object_begin) {
                try self.skip();
                continue;
            }
            _ = try self.token();
            while (try self.nextKey()) |inner| {
                if (std.mem.eql(u8, inner, "module") and (try self.peek()) == .object_begin) {
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
        _ = try self.token();
        while (try self.nextKey()) |name| {
            try self.skip();
            try out.append(self.arena, .{ .name = try self.arena.dupe(u8, name), .description = "" });
        }
    }

    pub fn cacheDocument(self: *Parser, out: *CacheDocument) !void {
        if ((try self.peek()) != .object_begin) return error.UnexpectedToken;
        _ = try self.token();
        while (try self.nextKey()) |key| {
            if (std.mem.eql(u8, key, "ansible_version")) {
                if ((try self.peek()) == .string) {
                    out.ansible_version = try self.keepString();
                } else {
                    try self.skip();
                }
            } else if (std.mem.eql(u8, key, "complete")) {
                out.complete = (try self.peek()) == .true;
                try self.skip();
            } else if (std.mem.eql(u8, key, "catalog")) {
                if ((try self.peek()) != .object_begin) {
                    try self.skip();
                    continue;
                }
                _ = try self.token();
                while (try self.nextKey()) |name| {
                    const kept = try self.arena.dupe(u8, name);
                    const desc = if ((try self.peek()) == .string)
                        try self.keepString()
                    else blk: {
                        try self.skip();
                        break :blk "";
                    };
                    try out.catalog.append(self.arena, .{ .name = kept, .description = desc });
                }
            } else if (std.mem.eql(u8, key, "modules")) {
                if ((try self.peek()) != .object_begin) {
                    try self.skip();
                    continue;
                }
                _ = try self.token();
                while (try self.nextKey()) |name| {
                    const kept = try self.arena.dupe(u8, name);
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
            _ = try self.token();
            while (try self.nextKey()) |key| {
                if (std.mem.eql(u8, key, "description")) {
                    if ((try self.peek()) == .string) m.description = try self.keepString() else try self.skip();
                } else if (std.mem.eql(u8, key, "long_description")) {
                    m.long_description = try self.cacheStringList();
                } else if (std.mem.eql(u8, key, "requirements")) {
                    m.requirements = try self.cacheStringList();
                } else if (std.mem.eql(u8, key, "notes")) {
                    m.notes = try self.cacheStringList();
                } else if (std.mem.eql(u8, key, "deprecated")) {
                    m.deprecated = (try self.peek()) == .true;
                    try self.skip();
                } else if (std.mem.eql(u8, key, "filename")) {
                    if ((try self.peek()) == .string) m.filename = try self.keepString() else try self.skip();
                } else if (std.mem.eql(u8, key, "options")) {
                    if ((try self.peek()) == .object_begin) {
                        _ = try self.token();
                        m.options = try self.optionList();
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
        try out.modules.append(self.arena, m);
    }

    fn cacheStringList(self: *Parser) ![]const []const u8 {
        if ((try self.peek()) != .array_begin) {
            try self.skip();
            return &.{};
        }
        return self.stringList(null);
    }

    fn moduleEntry(self: *Parser, name: []const u8, out: *std.ArrayList(docs.Module)) !void {
        var m = docs.Module{ .name = name, .description = "", .filename = "" };
        var have_doc = false;
        if ((try self.peek()) == .object_begin) {
            _ = try self.token();
            while (try self.nextKey()) |key| {
                if (std.mem.eql(u8, key, "doc")) {
                    have_doc = true;
                    if ((try self.peek()) == .object_begin) {
                        _ = try self.token();
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
        if (have_doc) try out.append(self.arena, m);
    }

    fn docFields(self: *Parser, m: *docs.Module) !void {
        var short_desc: ?[]const u8 = null;
        var desc_string: ?[]const u8 = null;
        var desc_first: ?[]const u8 = null;
        var long_description: []const []const u8 = &.{};
        var requirements: []const []const u8 = &.{};
        var notes: []const []const u8 = &.{};
        while (try self.nextKey()) |key| {
            if (std.mem.eql(u8, key, "short_description")) {
                if ((try self.peek()) == .string) short_desc = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key, "description")) {
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
            } else if (std.mem.eql(u8, key, "requirements")) {
                requirements = try self.stringList(null);
            } else if (std.mem.eql(u8, key, "notes")) {
                notes = try self.stringList(null);
            } else if (std.mem.eql(u8, key, "deprecated")) {
                m.deprecated = true;
                try self.skip();
            } else if (std.mem.eql(u8, key, "filename")) {
                if ((try self.peek()) == .string) m.filename = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key, "options")) {
                if ((try self.peek()) == .object_begin) {
                    _ = try self.token();
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
        while (try self.nextKey()) |name| {
            var opt = docs.Option{
                .name = try self.arena.dupe(u8, name),
                .description = "",
                .type = "",
            };
            if ((try self.peek()) == .object_begin) {
                _ = try self.token();
                try self.optionFields(&opt);
            } else {
                try self.skip();
            }
            try list.append(self.arena, opt);
        }
        return try list.toOwnedSlice(self.arena);
    }

    fn optionFields(self: *Parser, opt: *docs.Option) ParseError!void {
        var short_desc: ?[]const u8 = null;
        var desc_string: ?[]const u8 = null;
        var desc_first: ?[]const u8 = null;
        var suboptions: ?[]const docs.Option = null;
        while (try self.nextKey()) |key| {
            if (std.mem.eql(u8, key, "description")) {
                switch (try self.peek()) {
                    .string => desc_string = try self.keepString(),
                    .array_begin => _ = try self.stringList(&desc_first),
                    else => try self.skip(),
                }
            } else if (std.mem.eql(u8, key, "short_description")) {
                if ((try self.peek()) == .string) short_desc = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key, "type")) {
                if ((try self.peek()) == .string) opt.type = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key, "required")) {
                opt.required = (try self.peek()) == .true;
                try self.skip();
            } else if (std.mem.eql(u8, key, "elements")) {
                if ((try self.peek()) == .string) opt.elements = try self.keepString() else try self.skip();
            } else if (std.mem.eql(u8, key, "default")) {
                opt.default = try self.defaultValue();
            } else if (std.mem.eql(u8, key, "suboptions")) {
                if ((try self.peek()) == .object_begin) {
                    _ = try self.token();
                    suboptions = try self.optionList();
                } else {
                    try self.skip();
                }
            } else {
                try self.skip();
            }
        }
        opt.description = desc_string orelse desc_first orelse short_desc orelse "";
        opt.suboptions = suboptions orelse &.{};
    }

    fn defaultValue(self: *Parser) !?[]const u8 {
        switch (try self.peek()) {
            .null => {
                _ = try self.token();
                return null;
            },
            .true => {
                _ = try self.token();
                return "true";
            },
            .false => {
                _ = try self.token();
                return "false";
            },
            .number => {
                const tok = try self.token();
                const text = switch (tok) {
                    .number => |t| t,
                    .allocated_number => |t| t,
                    else => return null,
                };
                if (std.fmt.parseInt(i64, text, 10)) |i| {
                    return try std.fmt.allocPrint(self.arena, "{d}", .{i});
                } else |_| {}
                const f = std.fmt.parseFloat(f64, text) catch return try self.arena.dupe(u8, text);
                return try std.fmt.allocPrint(self.arena, "{d}", .{f});
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
        var aw: std.Io.Writer.Allocating = .init(self.arena);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try self.writeJson(&jw);
        return aw.toOwnedSlice();
    }

    const WriteError = std.Io.Writer.Error || Scanner.AllocError || Scanner.PeekError;

    fn writeJson(self: *Parser, jw: *std.json.Stringify) WriteError!void {
        const tok = try self.token();
        switch (tok) {
            .object_begin => {
                try jw.beginObject();
                while (true) {
                    const key = try self.token();
                    if (key == .object_end) break;
                    try jw.objectField(tokenString(key));
                    try self.writeJson(jw);
                }
                try jw.endObject();
            },
            .array_begin => {
                try jw.beginArray();
                while ((try self.peek()) != .array_end) {
                    try self.writeJson(jw);
                }
                _ = try self.token();
                try jw.endArray();
            },
            .array_end, .object_end => unreachable,
            else => try writeJsonToken(jw, tok),
        }
    }

    fn writeJsonToken(jw: *std.json.Stringify, tok: Token) std.Io.Writer.Error!void {
        switch (tok) {
            .string, .allocated_string => |s| try jw.write(s),
            .number, .allocated_number => |text| {
                if (std.fmt.parseInt(i64, text, 10)) |i| {
                    try jw.write(i);
                } else |_| {
                    if (std.fmt.parseFloat(f64, text)) |f| {
                        try jw.write(f);
                    } else |_| {
                        try jw.writer.writeAll(text);
                    }
                }
            },
            .true => try jw.write(true),
            .false => try jw.write(false),
            .null => try jw.write(null),
            else => unreachable,
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
                _ = try self.token();
                var list = std.ArrayList([]const u8).empty;
                var first_seen = first == null;
                while ((try self.peek()) != .array_end) {
                    if ((try self.peek()) == .string) {
                        const s = try self.keepString();
                        if (!first_seen) {
                            first.?.* = s;
                            first_seen = true;
                        }
                        try list.append(self.arena, s);
                    } else {
                        try self.skip();
                    }
                }
                _ = try self.token();
                return try list.toOwnedSlice(self.arena);
            },
            else => {
                try self.skip();
                return &.{};
            },
        }
    }

    fn nextKey(self: *Parser) !?[]const u8 {
        const tok = try self.token();
        return switch (tok) {
            .object_end => null,
            .string, .allocated_string => tokenString(tok),
            else => return error.UnexpectedToken,
        };
    }

    fn token(self: *Parser) Scanner.AllocError!Token {
        return self.scanner.nextAlloc(self.arena, .alloc_if_needed);
    }

    fn peek(self: *Parser) Scanner.PeekError!TokenType {
        return self.scanner.peekNextTokenType();
    }

    fn skip(self: *Parser) Scanner.SkipError!void {
        return self.scanner.skipValue();
    }

    fn keepString(self: *Parser) ![]const u8 {
        const tok = try self.scanner.nextAlloc(self.arena, .alloc_always);
        return switch (tok) {
            .allocated_string => |s| s,
            .string => |s| try self.arena.dupe(u8, s),
            else => error.UnexpectedToken,
        };
    }
};

pub const CacheDocument = struct {
    ansible_version: ?[]const u8 = null,
    complete: bool = false,
    catalog: std.ArrayList(docs.CatalogEntry) = .empty,
    modules: std.ArrayList(docs.Module) = .empty,
};

fn tokenString(tok: Token) []const u8 {
    return switch (tok) {
        .string => |s| s,
        .allocated_string => |s| s,
        else => unreachable,
    };
}

fn freeTokenString(scratch: Allocator, tok: Token) void {
    switch (tok) {
        .allocated_string => |s| scratch.free(s),
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
        \\         "default": 5, "suboptions": {"inner": {"type": "int", "default": {"k": [1, 2]}}}},
        \\         "flag": {"default": true}, "off": {"default": false}, "none": {"default": null}}}}}
    ;
    try std.testing.expect(validate(std.testing.allocator, input));
    try std.testing.expectEqual(@as(i64, 3), topLevelVersion(std.testing.allocator, input).?);

    var parser = Parser.init(arena.allocator(), std.testing.allocator, input);
    defer parser.deinit();
    var cache = CacheDocument{};
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
    try parser.moduleMap(&modules);
    try std.testing.expectEqualStrings("quote \" and unicode é", modules.items[0].description);
    try std.testing.expectEqualStrings("na\"me", modules.items[0].options[0].name);
}

test "validate rejects malformed documents" {
    try std.testing.expect(!validate(std.testing.allocator, "boom"));
    try std.testing.expect(!validate(std.testing.allocator, "{\"a\":"));
    try std.testing.expect(validate(std.testing.allocator, "[]"));
    try std.testing.expect(topLevelVersion(std.testing.allocator, "[1]") == null);
    try std.testing.expect(topLevelVersion(std.testing.allocator, "{}") == null);
}

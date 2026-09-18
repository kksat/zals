//! Minimal ECMA-262-style regular expression engine for JSON Schema `pattern`.
//!
//! Supports the subset used by the bundled Ansible schemas: literals, `.`,
//! character classes (`[...]`, ranges, negation, `\d \w \s` and negations),
//! anchors (`^`, `$`), quantifiers (`*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`,
//! greedy and lazy), groups (`(...)`, `(?:...)`), and alternation (`|`).
//!
//! Matching is an unanchored search (like `RegExp.prototype.test`) implemented
//! as a backtracking bytecode VM. A step budget guards against pathological
//! patterns.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidPattern, OutOfMemory };

const Range = struct { lo: u8, hi: u8 };

const ClassItem = union(enum) {
    range: Range,
    digit,
    not_digit,
    word,
    not_word,
    space,
    not_space,
};

const Class = struct {
    negated: bool,
    items: []const ClassItem,
};

const Expr = union(enum) {
    empty,
    char: u8,
    any,
    class: Class,
    anchor_start,
    anchor_end,
    seq: []const *Expr,
    alt: []const *Expr,
    repeat: Repeat,
};

const Repeat = struct {
    expr: *Expr,
    min: usize,
    max: ?usize,
    greedy: bool,
};

const Inst = union(enum) {
    char: u8,
    any,
    class: u32,
    split: [2]u32,
    jmp: u32,
    assert_start,
    assert_end,
    match,
};

const Parser = struct {
    pat: []const u8,
    i: usize = 0,
    a: Allocator,

    fn mk(self: *Parser, e: Expr) Error!*Expr {
        const p = try self.a.create(Expr);
        p.* = e;
        return p;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.i < self.pat.len) self.pat[self.i] else null;
    }

    fn parseAlt(self: *Parser) Error!*Expr {
        var alts = std.ArrayList(*Expr).empty;
        try alts.append(self.a, try self.parseSeq());
        while (self.peek() == '|') {
            self.i += 1;
            try alts.append(self.a, try self.parseSeq());
        }
        if (alts.items.len == 1) return alts.items[0];
        return self.mk(.{ .alt = try alts.toOwnedSlice(self.a) });
    }

    fn parseSeq(self: *Parser) Error!*Expr {
        var seq = std.ArrayList(*Expr).empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try seq.append(self.a, try self.parseRepeat());
        }
        if (seq.items.len == 1) return seq.items[0];
        return self.mk(.{ .seq = try seq.toOwnedSlice(self.a) });
    }

    fn parseRepeat(self: *Parser) Error!*Expr {
        var atom = try self.parseAtom();
        while (self.peek()) |c| {
            var min: usize = 0;
            var max: ?usize = null;
            if (c == '*') {
                self.i += 1;
            } else if (c == '+') {
                min = 1;
                self.i += 1;
            } else if (c == '?') {
                max = 1;
                self.i += 1;
            } else if (c == '{') {
                const save = self.i;
                self.i += 1;
                const lo = self.parseNumber() orelse {
                    self.i = save;
                    break;
                };
                min = lo;
                if (self.peek() == ',') {
                    self.i += 1;
                    max = self.parseNumber();
                } else {
                    max = lo;
                }
                if (self.peek() != '}') {
                    self.i = save;
                    break;
                }
                self.i += 1;
            } else break;

            var greedy = true;
            if (self.peek() == '?') {
                greedy = false;
                self.i += 1;
            }
            atom = try self.mk(.{ .repeat = .{ .expr = atom, .min = min, .max = max, .greedy = greedy } });
        }
        return atom;
    }

    fn parseNumber(self: *Parser) ?usize {
        const start = self.i;
        var n: usize = 0;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            n = n * 10 + (c - '0');
            self.i += 1;
        }
        return if (self.i == start) null else n;
    }

    fn parseAtom(self: *Parser) Error!*Expr {
        const c = self.peek() orelse return error.InvalidPattern;
        switch (c) {
            '(' => {
                self.i += 1;
                if (self.i + 1 < self.pat.len and self.pat[self.i] == '?' and self.pat[self.i + 1] == ':')
                    self.i += 2;
                const inner = try self.parseAlt();
                if (self.peek() != ')') return error.InvalidPattern;
                self.i += 1;
                return inner;
            },
            '[' => return self.parseClass(),
            '.' => {
                self.i += 1;
                return self.mk(.any);
            },
            '^' => {
                self.i += 1;
                return self.mk(.anchor_start);
            },
            '$' => {
                self.i += 1;
                return self.mk(.anchor_end);
            },
            '\\' => {
                self.i += 1;
                const e = self.peek() orelse return error.InvalidPattern;
                self.i += 1;
                return self.escape(e);
            },
            else => {
                self.i += 1;
                return self.mk(.{ .char = c });
            },
        }
    }

    fn escape(self: *Parser, e: u8) Error!*Expr {
        return switch (e) {
            'd' => self.mk(.{ .class = .{ .negated = false, .items = try self.oneItem(.digit) } }),
            'D' => self.mk(.{ .class = .{ .negated = false, .items = try self.oneItem(.not_digit) } }),
            'w' => self.mk(.{ .class = .{ .negated = false, .items = try self.oneItem(.word) } }),
            'W' => self.mk(.{ .class = .{ .negated = false, .items = try self.oneItem(.not_word) } }),
            's' => self.mk(.{ .class = .{ .negated = false, .items = try self.oneItem(.space) } }),
            'S' => self.mk(.{ .class = .{ .negated = false, .items = try self.oneItem(.not_space) } }),
            'n' => self.mk(.{ .char = '\n' }),
            't' => self.mk(.{ .char = '\t' }),
            'r' => self.mk(.{ .char = '\r' }),
            'f' => self.mk(.{ .char = 12 }),
            'v' => self.mk(.{ .char = 11 }),
            '0' => self.mk(.{ .char = 0 }),
            else => self.mk(.{ .char = e }),
        };
    }

    fn oneItem(self: *Parser, item: ClassItem) Error![]const ClassItem {
        const items = try self.a.alloc(ClassItem, 1);
        items[0] = item;
        return items;
    }

    fn parseClass(self: *Parser) Error!*Expr {
        self.i += 1; // consume '['
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.i += 1;
        }
        var items = std.ArrayList(ClassItem).empty;
        while (self.peek()) |c| {
            if (c == ']') break;
            var lo: u8 = undefined;
            if (c == '\\') {
                self.i += 1;
                const e = self.peek() orelse return error.InvalidPattern;
                self.i += 1;
                switch (e) {
                    'd' => {
                        try items.append(self.a, .digit);
                        continue;
                    },
                    'D' => {
                        try items.append(self.a, .not_digit);
                        continue;
                    },
                    'w' => {
                        try items.append(self.a, .word);
                        continue;
                    },
                    'W' => {
                        try items.append(self.a, .not_word);
                        continue;
                    },
                    's' => {
                        try items.append(self.a, .space);
                        continue;
                    },
                    'S' => {
                        try items.append(self.a, .not_space);
                        continue;
                    },
                    'n' => lo = '\n',
                    't' => lo = '\t',
                    'r' => lo = '\r',
                    else => lo = e,
                }
            } else {
                lo = c;
                self.i += 1;
            }
            if (self.peek() == '-' and self.i + 1 < self.pat.len and self.pat[self.i + 1] != ']') {
                self.i += 1;
                var hi: u8 = undefined;
                if (self.peek() == '\\') {
                    self.i += 1;
                    hi = self.peek() orelse return error.InvalidPattern;
                    self.i += 1;
                } else {
                    hi = self.peek() orelse return error.InvalidPattern;
                    self.i += 1;
                }
                try items.append(self.a, .{ .range = .{ .lo = lo, .hi = hi } });
            } else {
                try items.append(self.a, .{ .range = .{ .lo = lo, .hi = lo } });
            }
        }
        if (self.peek() != ']') return error.InvalidPattern;
        self.i += 1;
        return self.mk(.{ .class = .{ .negated = negated, .items = try items.toOwnedSlice(self.a) } });
    }
};

const Compiler = struct {
    prog: std.ArrayList(Inst),
    classes: std.ArrayList(Class),
    a: Allocator,

    fn emit(self: *Compiler, inst: Inst) Error!u32 {
        const at: u32 = @intCast(self.prog.items.len);
        try self.prog.append(self.a, inst);
        return at;
    }

    fn compile(self: *Compiler, e: *const Expr) Error!void {
        switch (e.*) {
            .empty => {},
            .char => |c| _ = try self.emit(.{ .char = c }),
            .any => _ = try self.emit(.any),
            .class => |cl| {
                const idx: u32 = @intCast(self.classes.items.len);
                try self.classes.append(self.a, cl);
                _ = try self.emit(.{ .class = idx });
            },
            .anchor_start => _ = try self.emit(.assert_start),
            .anchor_end => _ = try self.emit(.assert_end),
            .seq => |items| for (items) |it| try self.compile(it),
            .alt => |alts| {
                var jmps = std.ArrayList(u32).empty;
                for (alts, 0..) |alt, idx| {
                    if (idx + 1 < alts.len) {
                        const sp = try self.emit(.{ .split = .{ 0, 0 } });
                        const a_start: u32 = @intCast(self.prog.items.len);
                        try self.compile(alt);
                        try jmps.append(self.a, try self.emit(.{ .jmp = 0 }));
                        const b_start: u32 = @intCast(self.prog.items.len);
                        self.prog.items[sp] = .{ .split = .{ a_start, b_start } };
                    } else {
                        try self.compile(alt);
                    }
                }
                const end: u32 = @intCast(self.prog.items.len);
                for (jmps.items) |j| self.prog.items[j] = .{ .jmp = end };
            },
            .repeat => |r| try self.compileRepeat(r),
        }
    }

    fn compileRepeat(self: *Compiler, r: Repeat) Error!void {
        var i: usize = 0;
        while (i < r.min) : (i += 1) try self.compile(r.expr);

        if (r.max) |max| {
            const extra = max - r.min;
            var jmps = std.ArrayList(u32).empty;
            var k: usize = 0;
            while (k < extra) : (k += 1) {
                const sp = try self.emit(.{ .split = .{ 0, 0 } });
                const body: u32 = @intCast(self.prog.items.len);
                try self.compile(r.expr);
                try jmps.append(self.a, try self.emit(.{ .jmp = 0 }));
                const after: u32 = @intCast(self.prog.items.len);
                self.prog.items[sp] = if (r.greedy)
                    .{ .split = .{ body, after } }
                else
                    .{ .split = .{ after, body } };
            }
            const end: u32 = @intCast(self.prog.items.len);
            for (jmps.items) |j| self.prog.items[j] = .{ .jmp = end };
        } else {
            const l1 = try self.emit(.{ .split = .{ 0, 0 } });
            const body: u32 = @intCast(self.prog.items.len);
            try self.compile(r.expr);
            _ = try self.emit(.{ .jmp = l1 });
            const end: u32 = @intCast(self.prog.items.len);
            self.prog.items[l1] = if (r.greedy)
                .{ .split = .{ body, end } }
            else
                .{ .split = .{ end, body } };
        }
    }
};

const State = struct { pc: u32, pos: usize };

fn isWord(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn matchesClass(cl: Class, ch: u8) bool {
    var hit = false;
    for (cl.items) |item| {
        const m = switch (item) {
            .range => |r| ch >= r.lo and ch <= r.hi,
            .digit => ch >= '0' and ch <= '9',
            .not_digit => !(ch >= '0' and ch <= '9'),
            .word => isWord(ch),
            .not_word => !isWord(ch),
            .space => ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 11 or ch == 12,
            .not_space => !(ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 11 or ch == 12),
        };
        if (m) {
            hit = true;
            break;
        }
    }
    return hit != cl.negated;
}

/// Returns true if `pattern` matches anywhere in `text` (unanchored search).
pub fn matches(allocator: Allocator, pattern: []const u8, text: []const u8) Error!bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p = Parser{ .pat = pattern, .a = a };
    const ast = try p.parseAlt();
    if (p.i != pattern.len) return error.InvalidPattern;

    var comp = Compiler{
        .prog = std.ArrayList(Inst).empty,
        .classes = std.ArrayList(Class).empty,
        .a = a,
    };
    try comp.compile(ast);
    _ = try comp.emit(.match);

    const prog = comp.prog.items;
    const classes = comp.classes.items;

    var stack = std.ArrayList(State).empty;
    var start: usize = 0;
    while (start <= text.len) : (start += 1) {
        stack.clearRetainingCapacity();
        var pc: u32 = 0;
        var pos: usize = start;
        var steps: usize = 0;
        while (true) {
            steps += 1;
            if (steps > 1_000_000) return false;
            switch (prog[pc]) {
                .char => |c| {
                    if (pos < text.len and text[pos] == c) {
                        pos += 1;
                        pc += 1;
                    } else if (stack.pop()) |s| {
                        pc = s.pc;
                        pos = s.pos;
                    } else break;
                },
                .any => {
                    if (pos < text.len and text[pos] != '\n') {
                        pos += 1;
                        pc += 1;
                    } else if (stack.pop()) |s| {
                        pc = s.pc;
                        pos = s.pos;
                    } else break;
                },
                .class => |idx| {
                    if (pos < text.len and matchesClass(classes[idx], text[pos])) {
                        pos += 1;
                        pc += 1;
                    } else if (stack.pop()) |s| {
                        pc = s.pc;
                        pos = s.pos;
                    } else break;
                },
                .split => |s| {
                    try stack.append(a, .{ .pc = s[1], .pos = pos });
                    pc = s[0];
                },
                .jmp => |t| pc = t,
                .assert_start => {
                    if (pos == 0) {
                        pc += 1;
                    } else if (stack.pop()) |s| {
                        pc = s.pc;
                        pos = s.pos;
                    } else break;
                },
                .assert_end => {
                    if (pos == text.len) {
                        pc += 1;
                    } else if (stack.pop()) |s| {
                        pc = s.pc;
                        pos = s.pos;
                    } else break;
                },
                .match => return true,
            }
        }
    }
    return false;
}

test "literals and anchors" {
    try std.testing.expect(try matches(std.testing.allocator, "^abc$", "abc"));
    try std.testing.expect(!try matches(std.testing.allocator, "^abc$", "xabc"));
    try std.testing.expect(try matches(std.testing.allocator, "abc", "xxabcyy"));
}

test "classes and shorthands" {
    try std.testing.expect(try matches(std.testing.allocator, "^[a-z0-9_]+$", "foo_bar9"));
    try std.testing.expect(!try matches(std.testing.allocator, "^[a-z0-9_]+$", "Foo"));
    try std.testing.expect(try matches(std.testing.allocator, "^\\d+$", "12345"));
    try std.testing.expect(!try matches(std.testing.allocator, "^\\d+$", "12a45"));
    try std.testing.expect(try matches(std.testing.allocator, "^[^0-9]+$", "abc"));
}

test "quantifiers and alternation" {
    try std.testing.expect(try matches(std.testing.allocator, "^a{2,4}$", "aaa"));
    try std.testing.expect(!try matches(std.testing.allocator, "^a{2,4}$", "a"));
    try std.testing.expect(try matches(std.testing.allocator, "^(cat|dog)$", "dog"));
    try std.testing.expect(!try matches(std.testing.allocator, "^(cat|dog)$", "cow"));
    try std.testing.expect(try matches(std.testing.allocator, "^ab?c$", "ac"));
    try std.testing.expect(try matches(std.testing.allocator, "^ab*c$", "abbbc"));
}

test "lazy quantifiers" {
    try std.testing.expect(try matches(std.testing.allocator, "^a.*?b$", "axxb"));
    try std.testing.expect(try matches(std.testing.allocator, "^a.*b$", "axxb"));
}

test "invalid pattern" {
    try std.testing.expectError(error.InvalidPattern, matches(std.testing.allocator, "(abc", "abc"));
    try std.testing.expectError(error.InvalidPattern, matches(std.testing.allocator, "[abc", "abc"));
}
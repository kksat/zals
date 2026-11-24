const std = @import("std");
const cel = @import("cel");
const limits = @import("limits.zig");
const schema = @import("schema.zig");
const env = @import("env.zig");

pub const TargetKind = schema.TargetKind;
pub const TargetMask = schema.TargetMask;
pub const Severity = schema.Severity;

pub const RuleOriginKind = enum(u8) {
    builtin,
    global_file,
    workspace_file,
};

pub const RuleOrigin = struct {
    kind: RuleOriginKind,
    file_path: ?[]const u8 = null,
};

pub const SourcePos = struct {
    offset: usize,
    line: u32,
    column: u32,
};

pub const LoadErrorKind = enum(u8) {
    source_too_large,
    parse_error,
    invalid_declaration,
    duplicate_field,
    unknown_field,
    missing_field,
    invalid_metadata,
    unsupported_schema_version,
    invalid_target,
    invalid_field_selector,
    unbound_identifier,
    unknown_function,
    unsupported_expression,
    type_mismatch,
    invalid_regex,
    limit_exceeded,
    compile_error,
};

pub const LoadError = struct {
    kind: LoadErrorKind,
    message: []const u8,
    pos: SourcePos,
};

pub const RuleMeta = struct {
    id: []const u8,
    targets: TargetMask,
    severity: Severity,
    field: ?[]const u8,
    schema_version: i64,
    origin: RuleOrigin,
    condition_pos: SourcePos,
    message_pos: SourcePos,
};

pub const EvalOutcome = union(enum) {
    no_match: void,
    match: []const u8,
    condition_error: []const u8,
    condition_type_error: []const u8,
    message_error: []const u8,
    message_type_error: []const u8,
    limit_error: []const u8,
    cancelled: void,
};

pub const CompiledRule = struct {
    backing: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    source: []const u8,
    meta: RuleMeta,
    tree: cel.ast.Ast,
    condition_root: cel.ast.NodeIndex,
    message_root: cel.ast.NodeIndex,
    condition_prog: *cel.vm.Program,
    message_prog: *cel.vm.Program,

    pub fn deinit(self: *CompiledRule) void {
        self.arena.deinit();
        self.backing.destroy(self.arena);
    }

    pub fn evaluate(
        self: *CompiledRule,
        eval_alloc: std.mem.Allocator,
        bindings: []const env.Binding,
        cancel: ?*cel.vm.Cancel,
    ) std.mem.Allocator.Error!EvalOutcome {
        return evalPrograms(self.condition_prog, self.message_prog, eval_alloc, bindings, cancel);
    }

    pub fn cloneForWorker(self: *const CompiledRule, backing: std.mem.Allocator) error{ Compile, OutOfMemory }!WorkerRule {
        const arena = try backing.create(std.heap.ArenaAllocator);
        errdefer backing.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();
        const cond_tree = cel.ast.Ast{
            .nodes = self.tree.nodes,
            .child_table = self.tree.child_table,
            .root = self.condition_root,
        };
        const msg_tree = cel.ast.Ast{
            .nodes = self.tree.nodes,
            .child_table = self.tree.child_table,
            .root = self.message_root,
        };
        const cond_prog = try cel.vm.Compiler.compile(a, cond_tree, .{});
        const msg_prog = try cel.vm.Compiler.compile(a, msg_tree, .{});
        return .{
            .backing = backing,
            .arena = arena,
            .meta = self.meta,
            .condition_prog = cond_prog,
            .message_prog = msg_prog,
        };
    }
};

pub const WorkerRule = struct {
    backing: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    meta: RuleMeta,
    condition_prog: *cel.vm.Program,
    message_prog: *cel.vm.Program,

    pub fn deinit(self: *WorkerRule) void {
        self.arena.deinit();
        self.backing.destroy(self.arena);
    }

    pub fn evaluate(
        self: *WorkerRule,
        eval_alloc: std.mem.Allocator,
        bindings: []const env.Binding,
        cancel: ?*cel.vm.Cancel,
    ) std.mem.Allocator.Error!EvalOutcome {
        return evalPrograms(self.condition_prog, self.message_prog, eval_alloc, bindings, cancel);
    }
};

fn evalPrograms(
    condition_prog: *cel.vm.Program,
    message_prog: *cel.vm.Program,
    eval_alloc: std.mem.Allocator,
    bindings: []const env.Binding,
    cancel: ?*cel.vm.Cancel,
) std.mem.Allocator.Error!EvalOutcome {
    const run_opts = cel.vm.RunOptions{
        .max_steps = limits.max_run_steps,
        .cancel = cancel,
    };
    const cond_res = condition_prog.run(eval_alloc, bindings, "", run_opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BudgetExceeded => return .{ .limit_error = "condition exceeded the run-step budget" },
        error.Canceled => return .cancelled,
    };
    switch (cond_res) {
        .err => |msg| return .{ .condition_error = msg },
        .value => |v| switch (v) {
            .bool_t => |matched| {
                if (!matched) return .no_match;
            },
            else => {
                const msg = try std.fmt.allocPrint(
                    eval_alloc,
                    "condition must evaluate to bool, got {s}",
                    .{v.typeOf().name()},
                );
                return .{ .condition_type_error = msg };
            },
        },
    }

    const msg_res = message_prog.run(eval_alloc, bindings, "", run_opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BudgetExceeded => return .{ .limit_error = "message exceeded the run-step budget" },
        error.Canceled => return .cancelled,
    };
    switch (msg_res) {
        .err => |msg| return .{ .message_error = msg },
        .value => |v| switch (v) {
            .string_t => |text| {
                if (text.len > limits.max_message_bytes) {
                    return .{ .limit_error = "rule message exceeds maximum allowed length" };
                }
                return .{ .match = text };
            },
            else => {
                const msg = try std.fmt.allocPrint(
                    eval_alloc,
                    "message must evaluate to string, got {s}",
                    .{v.typeOf().name()},
                );
                return .{ .message_type_error = msg };
            },
        },
    }
}

pub const LoadResult = union(enum) {
    ok: CompiledRule,
    err: struct {
        backing: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        info: LoadError,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.backing.destroy(self.arena);
        }
    },
};

fn exprStartOffset(tree: cel.ast.Ast, idx: cel.ast.NodeIndex) usize {
    const n = tree.node(idx);
    var best: usize = n.start;
    for (tree.children(idx)) |c| {
        const child_start = exprStartOffset(tree, c);
        if (child_start < best) best = child_start;
    }
    return best;
}

pub fn offsetToPos(source: []const u8, raw_offset: usize) SourcePos {
    const offset = @min(raw_offset, source.len);
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    while (i < offset) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .offset = offset, .line = line, .column = col };
}

fn failLoad(
    backing: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    source: []const u8,
    kind: LoadErrorKind,
    offset: usize,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!LoadResult {
    const msg = try std.fmt.allocPrint(arena.allocator(), fmt, args);
    return .{
        .err = .{
            .backing = backing,
            .arena = arena,
            .info = .{
                .kind = kind,
                .message = msg,
                .pos = offsetToPos(source, offset),
            },
        },
    };
}

pub fn load(
    backing: std.mem.Allocator,
    source: []const u8,
    origin: RuleOrigin,
) std.mem.Allocator.Error!LoadResult {
    const arena = try backing.create(std.heap.ArenaAllocator);
    errdefer backing.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();

    if (source.len > limits.max_rule_source_bytes) {
        return failLoad(
            backing,
            arena,
            source,
            .source_too_large,
            0,
            "rule source exceeds {d} bytes",
            .{limits.max_rule_source_bytes},
        );
    }

    const owned_source = try a.dupe(u8, source);
    const owned_origin = RuleOrigin{
        .kind = origin.kind,
        .file_path = if (origin.file_path) |p| try a.dupe(u8, p) else null,
    };

    const parsed = try cel.parser.parseSrc(a, owned_source, .{});
    const tree = switch (parsed) {
        .ok => |t| t,
        .err => |e| return failLoad(backing, arena, owned_source, .parse_error, e.pos, "{s}", .{e.msg}),
    };

    if (tree.nodes.len > limits.max_ast_nodes) {
        return failLoad(
            backing,
            arena,
            owned_source,
            .limit_exceeded,
            0,
            "rule AST exceeds maximum node limit ({d})",
            .{limits.max_ast_nodes},
        );
    }

    const root_node = tree.node(tree.root);
    if (root_node.kind != .struct_ or root_node.payload != .str or !std.mem.eql(u8, root_node.payload.str, "zals.Rule")) {
        return failLoad(
            backing,
            arena,
            owned_source,
            .invalid_declaration,
            root_node.start,
            "top-level rule declaration must be zals.Rule{{ ... }}",
            .{},
        );
    }

    const pairs = tree.children(tree.root);
    if (pairs.len % 2 != 0) {
        return failLoad(backing, arena, owned_source, .invalid_declaration, root_node.start, "malformed zals.Rule field list", .{});
    }

    var id_opt: ?[]const u8 = null;
    var targets_seen = false;
    var targets: TargetMask = .{};
    var severity_opt: ?Severity = null;
    var field_opt: ?[]const u8 = null;
    var field_pos: usize = 0;
    var schema_ver_seen = false;
    var schema_ver: i64 = schema.schema_version;
    var condition_root: ?cel.ast.NodeIndex = null;
    var message_root: ?cel.ast.NodeIndex = null;

    var idx: usize = 0;
    while (idx < pairs.len) : (idx += 2) {
        const key_node = tree.node(pairs[idx]);
        const val_idx = pairs[idx + 1];
        const val_node = tree.node(val_idx);

        if (key_node.kind != .string or key_node.payload != .str) {
            return failLoad(backing, arena, owned_source, .invalid_declaration, key_node.start, "expected field name identifier", .{});
        }
        const field_name = key_node.payload.str;

        if (std.mem.eql(u8, field_name, "id")) {
            if (id_opt != null) return failLoad(backing, arena, owned_source, .duplicate_field, key_node.start, "duplicate field 'id'", .{});
            if (val_node.kind != .string or val_node.payload != .str) {
                return failLoad(backing, arena, owned_source, .invalid_metadata, val_node.start, "'id' must be a string literal", .{});
            }
            if (!schema.isValidRuleId(val_node.payload.str)) {
                return failLoad(backing, arena, owned_source, .invalid_metadata, val_node.start, "invalid rule id '{s}'", .{val_node.payload.str});
            }
            id_opt = val_node.payload.str;
        } else if (std.mem.eql(u8, field_name, "target")) {
            if (targets_seen) return failLoad(backing, arena, owned_source, .duplicate_field, key_node.start, "duplicate field 'target'", .{});
            targets_seen = true;
            switch (val_node.kind) {
                .string => {
                    const kind = TargetKind.parse(val_node.payload.str) orelse {
                        return failLoad(backing, arena, owned_source, .invalid_target, val_node.start, "unknown target '{s}'", .{val_node.payload.str});
                    };
                    targets.add(kind);
                },
                .list => {
                    const elems = tree.children(val_idx);
                    if (elems.len == 0) {
                        return failLoad(backing, arena, owned_source, .invalid_target, val_node.start, "'target' list must not be empty", .{});
                    }
                    for (elems) |elem_idx| {
                        const elem = tree.node(elem_idx);
                        if (elem.kind != .string or elem.payload != .str) {
                            return failLoad(backing, arena, owned_source, .invalid_target, elem.start, "'target' list entries must be string literals", .{});
                        }
                        const kind = TargetKind.parse(elem.payload.str) orelse {
                            return failLoad(backing, arena, owned_source, .invalid_target, elem.start, "unknown target '{s}'", .{elem.payload.str});
                        };
                        if (targets.contains(kind)) {
                            return failLoad(backing, arena, owned_source, .invalid_target, elem.start, "duplicate target '{s}'", .{elem.payload.str});
                        }
                        targets.add(kind);
                    }
                },
                else => {
                    return failLoad(backing, arena, owned_source, .invalid_metadata, val_node.start, "'target' must be a string literal or list of string literals", .{});
                },
            }
        } else if (std.mem.eql(u8, field_name, "severity")) {
            if (severity_opt != null) return failLoad(backing, arena, owned_source, .duplicate_field, key_node.start, "duplicate field 'severity'", .{});
            if (val_node.kind != .string or val_node.payload != .str) {
                return failLoad(backing, arena, owned_source, .invalid_metadata, val_node.start, "'severity' must be a string literal", .{});
            }
            severity_opt = Severity.parse(val_node.payload.str) orelse {
                return failLoad(backing, arena, owned_source, .invalid_metadata, val_node.start, "invalid severity '{s}'", .{val_node.payload.str});
            };
        } else if (std.mem.eql(u8, field_name, "field")) {
            if (field_opt != null) return failLoad(backing, arena, owned_source, .duplicate_field, key_node.start, "duplicate field 'field'", .{});
            if (val_node.kind != .string or val_node.payload != .str) {
                return failLoad(backing, arena, owned_source, .invalid_metadata, val_node.start, "'field' must be a string literal", .{});
            }
            field_opt = val_node.payload.str;
            field_pos = val_node.start;
        } else if (std.mem.eql(u8, field_name, "schema_version")) {
            if (schema_ver_seen) return failLoad(backing, arena, owned_source, .duplicate_field, key_node.start, "duplicate field 'schema_version'", .{});
            schema_ver_seen = true;
            if (val_node.kind != .int or val_node.payload != .int) {
                return failLoad(backing, arena, owned_source, .invalid_metadata, val_node.start, "'schema_version' must be an int literal", .{});
            }
            if (val_node.payload.int != schema.schema_version) {
                return failLoad(
                    backing,
                    arena,
                    owned_source,
                    .unsupported_schema_version,
                    val_node.start,
                    "unsupported schema_version {d}; expected {d}",
                    .{ val_node.payload.int, schema.schema_version },
                );
            }
            schema_ver = val_node.payload.int;
        } else if (std.mem.eql(u8, field_name, "condition")) {
            if (condition_root != null) return failLoad(backing, arena, owned_source, .duplicate_field, key_node.start, "duplicate field 'condition'", .{});
            condition_root = val_idx;
        } else if (std.mem.eql(u8, field_name, "message")) {
            if (message_root != null) return failLoad(backing, arena, owned_source, .duplicate_field, key_node.start, "duplicate field 'message'", .{});
            message_root = val_idx;
        } else {
            return failLoad(backing, arena, owned_source, .unknown_field, key_node.start, "unknown zals.Rule field '{s}'", .{field_name});
        }
    }

    const id = id_opt orelse return failLoad(backing, arena, owned_source, .missing_field, root_node.start, "missing required field 'id'", .{});
    if (!targets_seen or targets.isEmpty()) return failLoad(backing, arena, owned_source, .missing_field, root_node.start, "missing required field 'target'", .{});
    const severity = severity_opt orelse return failLoad(backing, arena, owned_source, .missing_field, root_node.start, "missing required field 'severity'", .{});
    const cond_idx = condition_root orelse return failLoad(backing, arena, owned_source, .missing_field, root_node.start, "missing required field 'condition'", .{});
    const msg_idx = message_root orelse return failLoad(backing, arena, owned_source, .missing_field, root_node.start, "missing required field 'message'", .{});

    if (field_opt) |field_sel| {
        inline for (std.meta.fields(TargetKind)) |f| {
            const tk: TargetKind = @enumFromInt(f.value);
            if (targets.contains(tk) and !tk.isValidField(field_sel)) {
                return failLoad(
                    backing,
                    arena,
                    owned_source,
                    .invalid_field_selector,
                    field_pos,
                    "invalid field selector '{s}' for target '{s}'",
                    .{ field_sel, tk.name() },
                );
            }
        }
    }

    if (lintStaticRootType(tree, cond_idx, .bool_)) |err_info| {
        return failLoad(backing, arena, owned_source, err_info.kind, err_info.offset, "{s}", .{err_info.message});
    }
    if (lintStaticRootType(tree, msg_idx, .string_)) |err_info| {
        return failLoad(backing, arena, owned_source, err_info.kind, err_info.offset, "{s}", .{err_info.message});
    }

    var scopes = std.ArrayList([]const u8).empty;
    defer scopes.deinit(a);

    var linter = AstLinter{
        .alloc = a,
        .tree = tree,
        .scopes = &scopes,
    };
    if (try linter.checkExpr(cond_idx, 0, 0)) |err_info| {
        return failLoad(backing, arena, owned_source, err_info.kind, err_info.offset, "{s}", .{err_info.message});
    }
    if (try linter.checkExpr(msg_idx, 0, 0)) |err_info| {
        return failLoad(backing, arena, owned_source, err_info.kind, err_info.offset, "{s}", .{err_info.message});
    }

    const cond_tree = cel.ast.Ast{
        .nodes = tree.nodes,
        .child_table = tree.child_table,
        .root = cond_idx,
    };
    const msg_tree = cel.ast.Ast{
        .nodes = tree.nodes,
        .child_table = tree.child_table,
        .root = msg_idx,
    };

    const cond_prog = cel.vm.Compiler.compile(a, cond_tree, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Compile => return failLoad(backing, arena, owned_source, .compile_error, exprStartOffset(tree, cond_idx), "failed to compile condition expression", .{}),
    };
    const msg_prog = cel.vm.Compiler.compile(a, msg_tree, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Compile => return failLoad(backing, arena, owned_source, .compile_error, exprStartOffset(tree, msg_idx), "failed to compile message expression", .{}),
    };

    return .{
        .ok = .{
            .backing = backing,
            .arena = arena,
            .source = owned_source,
            .meta = .{
                .id = id,
                .targets = targets,
                .severity = severity,
                .field = field_opt,
                .schema_version = schema_ver,
                .origin = owned_origin,
                .condition_pos = offsetToPos(owned_source, exprStartOffset(tree, cond_idx)),
                .message_pos = offsetToPos(owned_source, exprStartOffset(tree, msg_idx)),
            },
            .tree = tree,
            .condition_root = cond_idx,
            .message_root = msg_idx,
            .condition_prog = cond_prog,
            .message_prog = msg_prog,
        },
    };
}

const LintErr = struct {
    kind: LoadErrorKind,
    offset: usize,
    message: []const u8,
};

const ExpectedRootType = enum { bool_, string_ };

fn lintStaticRootType(tree: cel.ast.Ast, idx: cel.ast.NodeIndex, expected: ExpectedRootType) ?LintErr {
    const n = tree.node(idx);
    const is_literal = switch (n.kind) {
        .int, .uint, .double, .string, .bytes, .bool_, .null_, .list, .map => true,
        else => false,
    };
    if (!is_literal) return null;
    switch (expected) {
        .bool_ => if (n.kind != .bool_) {
            return .{
                .kind = .type_mismatch,
                .offset = n.start,
                .message = "condition literal must be a bool",
            };
        },
        .string_ => if (n.kind != .string) {
            return .{
                .kind = .type_mismatch,
                .offset = n.start,
                .message = "message literal must be a string",
            };
        },
    }
    return null;
}

const AstLinter = struct {
    alloc: std.mem.Allocator,
    tree: cel.ast.Ast,
    scopes: *std.ArrayList([]const u8),

    fn inScope(self: *const AstLinter, name: []const u8) bool {
        for (self.scopes.items) |v| {
            if (std.mem.eql(u8, v, name)) return true;
        }
        return false;
    }

    fn checkExpr(
        self: *AstLinter,
        idx: cel.ast.NodeIndex,
        depth: usize,
        comp_depth: usize,
    ) std.mem.Allocator.Error!?LintErr {
        const n = self.tree.node(idx);
        if (depth > limits.max_ast_depth) {
            return .{
                .kind = .limit_exceeded,
                .offset = n.start,
                .message = "expression nesting exceeds maximum allowed depth",
            };
        }

        switch (n.kind) {
            .int, .uint, .double, .string, .bytes, .bool_, .null_ => return null,
            .struct_ => {
                return .{
                    .kind = .unsupported_expression,
                    .offset = n.start,
                    .message = "message/struct construction is not supported inside rule expressions",
                };
            },
            .ident => {
                const name = n.payload.str;
                if (!n.flags.abs and self.inScope(name)) return null;
                if (schema.isDeclaredBinding(name)) return null;
                if (cel.stdlib.bareTypeDenotation(name) != null) return null;
                const msg = try std.fmt.allocPrint(self.alloc, "unbound identifier '{s}'", .{name});
                return .{
                    .kind = .unbound_identifier,
                    .offset = n.start,
                    .message = msg,
                };
            },
            .select => {
                const children = self.tree.children(idx);
                for (children) |c| {
                    if (try self.checkExpr(c, depth + 1, comp_depth)) |e| return e;
                }
                return null;
            },
            .call => {
                const fn_name = n.payload.str;
                const fn_id = cel.stdlib.fnIdFromName(fn_name);
                if (fn_id == .unknown) {
                    const msg = try std.fmt.allocPrint(self.alloc, "unknown function '{s}'", .{fn_name});
                    return .{
                        .kind = .unknown_function,
                        .offset = n.start,
                        .message = msg,
                    };
                }
                const children = self.tree.children(idx);
                if (fn_id == .matches and children.len == 2) {
                    const pat_node = self.tree.node(children[1]);
                    if (pat_node.kind == .string and pat_node.payload == .str) {
                        const pat = pat_node.payload.str;
                        if (pat.len > limits.max_regex_pattern_bytes) {
                            return .{
                                .kind = .limit_exceeded,
                                .offset = pat_node.start,
                                .message = "regex pattern exceeds maximum allowed length",
                            };
                        }
                        var re = cel.regex.Regex.compile(self.alloc, pat) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.InvalidPattern => return .{
                                .kind = .invalid_regex,
                                .offset = pat_node.start,
                                .message = "invalid regular expression pattern",
                            },
                            error.TooComplex => return .{
                                .kind = .limit_exceeded,
                                .offset = pat_node.start,
                                .message = "regular expression exceeds complexity limit",
                            },
                        };
                        re.deinit(self.alloc);
                    }
                }
                for (children) |c| {
                    if (try self.checkExpr(c, depth + 1, comp_depth)) |e| return e;
                }
                return null;
            },
            .not, .neg, .and_, .or_, .ternary, .list, .map => {
                const children = self.tree.children(idx);
                for (children) |c| {
                    if (try self.checkExpr(c, depth + 1, comp_depth)) |e| return e;
                }
                return null;
            },
            .macro => {
                if (comp_depth + 1 > limits.max_comprehension_depth) {
                    return .{
                        .kind = .limit_exceeded,
                        .offset = n.start,
                        .message = "comprehension nesting exceeds maximum allowed depth",
                    };
                }
                const children = self.tree.children(idx);
                if (children.len < 3) {
                    return .{
                        .kind = .unsupported_expression,
                        .offset = n.start,
                        .message = "malformed comprehension macro",
                    };
                }
                const iter_node = self.tree.node(children[0]);
                const range_idx = children[1];
                if (try self.checkExpr(range_idx, depth + 1, comp_depth)) |e| return e;

                try self.scopes.append(self.alloc, iter_node.payload.str);
                defer _ = self.scopes.pop();

                for (children[2..]) |body_idx| {
                    if (try self.checkExpr(body_idx, depth + 1, comp_depth + 1)) |e| return e;
                }
                return null;
            },
        }
    }
};

test "load and evaluate typed parse-issue rule with dynamic message" {
    const src =
        \\zals.Rule{
        \\  id: "custom/parse-error",
        \\  target: "parse_issue",
        \\  severity: "error",
        \\  condition: true,
        \\  message:
        \\    "Cannot parse " + location.path +
        \\    " on line " + string(location.line) +
        \\    ", column " + string(location.column) +
        \\    ": " + node.message
        \\}
    ;
    var loaded = try load(std.testing.allocator, src, .{ .kind = .global_file, .file_path = "parse.cel" });
    switch (loaded) {
        .err => |*e| {
            defer e.deinit();
            std.debug.print("unexpected load error: {s}\n", .{e.info.message});
            return error.TestUnexpectedResult;
        },
        .ok => |*rule| {
            defer rule.deinit();
            try std.testing.expectEqualStrings("custom/parse-error", rule.meta.id);
            try std.testing.expect(rule.meta.targets.contains(.parse_issue));
            try std.testing.expectEqual(Severity.@"error", rule.meta.severity);
            try std.testing.expectEqual(@as(u32, 5), rule.meta.condition_pos.line);
            try std.testing.expectEqual(@as(u32, 7), rule.meta.message_pos.line);

            var eval_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer eval_arena.deinit();
            const a = eval_arena.allocator();

            var node_b = env.MapBuilder.init();
            try node_b.putString(a, "message", "unexpected indentation");
            const node_val = try node_b.finish(a);
            const loc_val = try (env.LocationValue{ .path = "playbooks/site.yml", .line = 14, .column = 3 }).toCel(a);
            const bindings = env.makeBindings(node_val, loc_val, env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue());

            const out = try rule.evaluate(a, &bindings, null);
            try std.testing.expectEqualStrings(
                "Cannot parse playbooks/site.yml on line 14, column 3: unexpected indentation",
                out.match,
            );
        },
    }
}

test "false condition skips message evaluation even if message would error" {
    const src =
        \\zals.Rule{
        \\  id: "test/short-circuit",
        \\  target: "task",
        \\  severity: "warning",
        \\  field: "action",
        \\  condition: node.action == "shell",
        \\  message: node.missing_field
        \\}
    ;
    var loaded = try load(std.testing.allocator, src, .{ .kind = .builtin });
    var rule = switch (loaded) {
        .ok => |r| r,
        .err => |*e| {
            defer e.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer rule.deinit();

    var eval_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer eval_arena.deinit();
    const a = eval_arena.allocator();

    var node_b = env.MapBuilder.init();
    try node_b.putString(a, "action", "debug");
    const bindings = env.makeBindings(try node_b.finish(a), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue());

    const out = try rule.evaluate(a, &bindings, null);
    try std.testing.expect(out == .no_match);
}

test "load rejects unbound identifier with accurate cel line and column" {
    const src =
        \\zals.Rule{
        \\  id: "test/unbound",
        \\  target: "task",
        \\  severity: "warning",
        \\  condition: bogus_var == "x",
        \\  message: "msg"
        \\}
    ;
    var loaded = try load(std.testing.allocator, src, .{ .kind = .global_file, .file_path = "bad.cel" });
    switch (loaded) {
        .ok => |*r| {
            r.deinit();
            return error.TestUnexpectedResult;
        },
        .err => |*e| {
            defer e.deinit();
            try std.testing.expectEqual(LoadErrorKind.unbound_identifier, e.info.kind);
            try std.testing.expectEqual(@as(u32, 5), e.info.pos.line);
            try std.testing.expectEqual(@as(u32, 14), e.info.pos.column);
        },
    }
}

test "load allows comprehension variables and rejects invalid field selector" {
    const ok_src =
        \\zals.Rule{
        \\  id: "test/comp",
        \\  target: ["task", "role_ref"],
        \\  severity: "warning",
        \\  field: "when",
        \\  condition: node.items.exists(x, x.matches("^foo")),
        \\  message: "matched"
        \\}
    ;
    var ok_loaded = try load(std.testing.allocator, ok_src, .{ .kind = .builtin });
    switch (ok_loaded) {
        .ok => |*r| {
            defer r.deinit();
            try std.testing.expect(r.meta.targets.contains(.task));
            try std.testing.expect(r.meta.targets.contains(.role_ref));
        },
        .err => |*e| {
            defer e.deinit();
            return error.TestUnexpectedResult;
        },
    }

    const bad_field_src =
        \\zals.Rule{
        \\  id: "test/bad-field",
        \\  target: ["task", "role_ref"],
        \\  severity: "warning",
        \\  field: "local_action",
        \\  condition: true,
        \\  message: "bad"
        \\}
    ;
    var bad_loaded = try load(std.testing.allocator, bad_field_src, .{ .kind = .builtin });
    switch (bad_loaded) {
        .ok => |*r| {
            r.deinit();
            return error.TestUnexpectedResult;
        },
        .err => |*e| {
            defer e.deinit();
            try std.testing.expectEqual(LoadErrorKind.invalid_field_selector, e.info.kind);
        },
    }
}

test "runtime type mismatch returns error outcome instead of violation" {
    const src =
        \\zals.Rule{
        \\  id: "test/runtime-type",
        \\  target: "task",
        \\  severity: "warning",
        \\  condition: node.value,
        \\  message: "msg"
        \\}
    ;
    var loaded = try load(std.testing.allocator, src, .{ .kind = .builtin });
    var rule = switch (loaded) {
        .ok => |r| r,
        .err => |*e| {
            defer e.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer rule.deinit();

    var eval_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer eval_arena.deinit();
    const a = eval_arena.allocator();

    var node_b = env.MapBuilder.init();
    try node_b.putString(a, "value", "not-a-bool");
    const bindings = env.makeBindings(try node_b.finish(a), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue());

    const out = try rule.evaluate(a, &bindings, null);
    try std.testing.expect(out == .condition_type_error);
}

test "worker clone evaluates independently from main rule" {
    const src =
        \\zals.Rule{
        \\  id: "test/worker-clone",
        \\  target: "task",
        \\  severity: "info",
        \\  condition: node.count > 2,
        \\  message: "count=" + string(node.count)
        \\}
    ;
    var loaded = try load(std.testing.allocator, src, .{ .kind = .builtin });
    var rule = switch (loaded) {
        .ok => |r| r,
        .err => |*e| {
            defer e.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer rule.deinit();

    var worker = try rule.cloneForWorker(std.testing.allocator);
    defer worker.deinit();

    var eval_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer eval_arena.deinit();
    const a = eval_arena.allocator();

    var node_b = env.MapBuilder.init();
    try node_b.putInt(a, "count", 5);
    const bindings = env.makeBindings(try node_b.finish(a), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue());

    const out = try worker.evaluate(a, &bindings, null);
    try std.testing.expectEqualStrings("count=5", out.match);
}

test "load enforces schema version, unknown function, regex, literal type, and nesting limits" {
    const cases = [_]struct { src: []const u8, kind: LoadErrorKind }{
        .{
            .src =
            \\zals.Rule{ id: "t/1", target: "task", severity: "error", schema_version: 2, condition: true, message: "m" }
            ,
            .kind = .unsupported_schema_version,
        },
        .{
            .src =
            \\zals.Rule{ id: "t/2", target: "task", severity: "error", condition: bogusFn(node), message: "m" }
            ,
            .kind = .unknown_function,
        },
        .{
            .src =
            \\zals.Rule{ id: "t/3", target: "task", severity: "error", condition: node.name.matches("[unclosed"), message: "m" }
            ,
            .kind = .invalid_regex,
        },
        .{
            .src =
            \\zals.Rule{ id: "t/4", target: "task", severity: "error", condition: "not-a-bool", message: "m" }
            ,
            .kind = .type_mismatch,
        },
        .{
            .src =
            \\zals.Rule{ id: "t/5", target: "task", severity: "error", condition: true, message: 42 }
            ,
            .kind = .type_mismatch,
        },
        .{
            .src =
            \\zals.Rule{ id: "t/6", target: "task", severity: "error", condition: [1].exists(a, [1].exists(b, [1].exists(c, [1].exists(d, [1].exists(e, true))))), message: "m" }
            ,
            .kind = .limit_exceeded,
        },
        .{
            .src =
            \\zals.Rule{ id: "t/7", target: "task", severity: "error", extra: 1, condition: true, message: "m" }
            ,
            .kind = .unknown_field,
        },
        .{
            .src =
            \\zals.Rule{ id: "t/8", id: "t/8b", target: "task", severity: "error", condition: true, message: "m" }
            ,
            .kind = .duplicate_field,
        },
    };
    for (cases) |c| {
        var res = try load(std.testing.allocator, c.src, .{ .kind = .global_file, .file_path = "x.cel" });
        switch (res) {
            .ok => |*r| {
                r.deinit();
                return error.TestUnexpectedResult;
            },
            .err => |*e| {
                defer e.deinit();
                try std.testing.expectEqual(c.kind, e.info.kind);
            },
        }
    }
}

test "load rejects constant-foldable metadata as non-literal" {
    const src =
        \\zals.Rule{
        \\  id: "custom/" + "x",
        \\  target: "task",
        \\  severity: "warning",
        \\  condition: true,
        \\  message: "m"
        \\}
    ;
    var res = try load(std.testing.allocator, src, .{ .kind = .global_file, .file_path = "fold.cel" });
    switch (res) {
        .ok => |*r| {
            r.deinit();
            return error.TestUnexpectedResult;
        },
        .err => |*e| {
            defer e.deinit();
            try std.testing.expectEqual(LoadErrorKind.invalid_metadata, e.info.kind);
        },
    }
}

test "run-step budget caps runaway comprehension work" {
    const src =
        \\zals.Rule{
        \\  id: "test/budget",
        \\  target: "task",
        \\  severity: "warning",
        \\  condition: node.items.all(a, node.items.all(b, a >= b)),
        \\  message: "m"
        \\}
    ;
    var loaded = try load(std.testing.allocator, src, .{ .kind = .builtin });
    var rule = switch (loaded) {
        .ok => |r| r,
        .err => |*e| {
            defer e.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer rule.deinit();

    var eval_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer eval_arena.deinit();
    const a = eval_arena.allocator();

    const n: usize = 600;
    const items = try a.alloc(env.Value, n);
    for (items) |*v| v.* = .{ .int_t = 7 };
    var node_b = env.MapBuilder.init();
    try node_b.put(a, "items", .{ .list_t = items });
    const bindings = env.makeBindings(try node_b.finish(a), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue());

    const out = try rule.evaluate(a, &bindings, null);
    try std.testing.expect(out == .limit_error);
}

test "requested cancellation aborts evaluation as cancelled outcome" {
    const src =
        \\zals.Rule{
        \\  id: "test/cancel",
        \\  target: "task",
        \\  severity: "warning",
        \\  condition: node.items.all(a, node.items.all(b, a >= b)),
        \\  message: "m"
        \\}
    ;
    var loaded = try load(std.testing.allocator, src, .{ .kind = .builtin });
    var rule = switch (loaded) {
        .ok => |r| r,
        .err => |*e| {
            defer e.deinit();
            return error.TestUnexpectedResult;
        },
    };
    defer rule.deinit();

    var eval_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer eval_arena.deinit();
    const a = eval_arena.allocator();

    const n: usize = 600;
    const items = try a.alloc(env.Value, n);
    for (items) |*v| v.* = .{ .int_t = 7 };
    var node_b = env.MapBuilder.init();
    try node_b.put(a, "items", .{ .list_t = items });
    const bindings = env.makeBindings(try node_b.finish(a), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue(), env.emptyMapValue());

    var cancel = cel.vm.Cancel{};
    cancel.request();
    const out = try rule.evaluate(a, &bindings, &cancel);
    try std.testing.expect(out == .cancelled);
}

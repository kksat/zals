const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/root.zig");
const lsp_types = @import("../lsp/types.zig");
const doc_mod = @import("../workspace/document.zig");
const env = @import("env.zig");
const limits = @import("limits.zig");
const rule_mod = @import("rule.zig");
const registry = @import("registry.zig");
const schema = @import("schema.zig");

pub const RuntimeError = struct {
    rule_id: []const u8,
    message: []const u8,
};

pub const EvalResult = struct {
    diagnostics: []const lsp_types.Diagnostic,
    runtime_errors: []const RuntimeError,
    cancelled: bool = false,
};

pub fn evaluateDocument(
    out_alloc: Allocator,
    doc: *const ast.DocumentAst,
    ruleset: *registry.WorkerRuleSet,
    metadata: ast.MetadataSnapshot,
    encoding: doc_mod.PositionEncoding,
    cancel: ?*const std.atomic.Value(bool),
) !EvalResult {
    var line_index = try doc_mod.LineIndex.init(out_alloc, doc.source, encoding);
    defer line_index.deinit(out_alloc);

    var diags = std.ArrayList(lsp_types.Diagnostic).empty;
    var runtime_errors = std.ArrayList(RuntimeError).empty;

    var scratch_arena = std.heap.ArenaAllocator.init(out_alloc);
    defer scratch_arena.deinit();
    const sa = scratch_arena.allocator();

    const doc_cel = try doc.documentToCel(sa);
    const meta_cel = try metadata.toCel(sa);

    for (ruleset.rules) |*entry| {
        if (isCancelled(cancel)) {
            return .{
                .diagnostics = &.{},
                .runtime_errors = &.{},
                .cancelled = true,
            };
        }
        if (diags.items.len >= limits.max_diagnostics_per_document) break;

        var eval_arena = std.heap.ArenaAllocator.init(out_alloc);
        defer eval_arena.deinit();
        const ea = eval_arena.allocator();
        const opts_cel = try entry.optionsToCel(ea);
        var per_rule_count: usize = 0;

        const targets = entry.rule.meta.targets;
        if (targets.contains(.document)) {
            const sp = ast.Span{ .start = 0, .end = @min(doc.source.len, 1) };
            const cancelled = try evalSingleTarget(
                out_alloc,
                ea,
                doc,
                line_index,
                entry,
                doc_cel,
                doc_cel,
                env.emptyMapValue(),
                meta_cel,
                opts_cel,
                sp,
                &.{},
                &diags,
                &runtime_errors,
                &per_rule_count,
                cancel,
            );
            if (cancelled) return .{ .diagnostics = &.{}, .runtime_errors = &.{}, .cancelled = true };
        }

        if (targets.contains(.play)) {
            for (doc.plays) |*play| {
                const node_cel = try play.toCel(ea);
                const cancelled = try evalSingleTarget(
                    out_alloc,
                    ea,
                    doc,
                    line_index,
                    entry,
                    node_cel,
                    doc_cel,
                    env.emptyMapValue(),
                    meta_cel,
                    opts_cel,
                    play.span,
                    play.field_spans,
                    &diags,
                    &runtime_errors,
                    &per_rule_count,
                    cancel,
                );
                if (cancelled) return .{ .diagnostics = &.{}, .runtime_errors = &.{}, .cancelled = true };
            }
        }

        if (targets.contains(.task)) {
            for (doc.tasks) |*task| {
                const node_cel = try task.toCel(ea);
                const cancelled = try evalSingleTarget(
                    out_alloc,
                    ea,
                    doc,
                    line_index,
                    entry,
                    node_cel,
                    doc_cel,
                    env.emptyMapValue(),
                    meta_cel,
                    opts_cel,
                    task.span,
                    task.field_spans,
                    &diags,
                    &runtime_errors,
                    &per_rule_count,
                    cancel,
                );
                if (cancelled) return .{ .diagnostics = &.{}, .runtime_errors = &.{}, .cancelled = true };
            }
        }

        if (targets.contains(.role_ref)) {
            for (doc.role_refs) |*rr| {
                const node_cel = try rr.toCel(ea);
                const cancelled = try evalSingleTarget(
                    out_alloc,
                    ea,
                    doc,
                    line_index,
                    entry,
                    node_cel,
                    doc_cel,
                    env.emptyMapValue(),
                    meta_cel,
                    opts_cel,
                    rr.span,
                    rr.field_spans,
                    &diags,
                    &runtime_errors,
                    &per_rule_count,
                    cancel,
                );
                if (cancelled) return .{ .diagnostics = &.{}, .runtime_errors = &.{}, .cancelled = true };
            }
        }

        if (targets.contains(.var_def)) {
            for (doc.var_defs) |*vd| {
                const node_cel = try vd.toCel(ea);
                const cancelled = try evalSingleTarget(
                    out_alloc,
                    ea,
                    doc,
                    line_index,
                    entry,
                    node_cel,
                    doc_cel,
                    env.emptyMapValue(),
                    meta_cel,
                    opts_cel,
                    vd.span,
                    vd.field_spans,
                    &diags,
                    &runtime_errors,
                    &per_rule_count,
                    cancel,
                );
                if (cancelled) return .{ .diagnostics = &.{}, .runtime_errors = &.{}, .cancelled = true };
            }
        }

        if (targets.contains(.role_meta)) {
            if (doc.role_meta) |*rm| {
                const node_cel = try rm.toCel(ea);
                const cancelled = try evalSingleTarget(
                    out_alloc,
                    ea,
                    doc,
                    line_index,
                    entry,
                    node_cel,
                    doc_cel,
                    env.emptyMapValue(),
                    meta_cel,
                    opts_cel,
                    rm.span,
                    rm.field_spans,
                    &diags,
                    &runtime_errors,
                    &per_rule_count,
                    cancel,
                );
                if (cancelled) return .{ .diagnostics = &.{}, .runtime_errors = &.{}, .cancelled = true };
            }
        }

        if (targets.contains(.galaxy_meta)) {
            if (doc.galaxy_meta) |*gm| {
                const node_cel = try gm.toCel(ea);
                const cancelled = try evalSingleTarget(
                    out_alloc,
                    ea,
                    doc,
                    line_index,
                    entry,
                    node_cel,
                    doc_cel,
                    env.emptyMapValue(),
                    meta_cel,
                    opts_cel,
                    gm.span,
                    gm.field_spans,
                    &diags,
                    &runtime_errors,
                    &per_rule_count,
                    cancel,
                );
                if (cancelled) return .{ .diagnostics = &.{}, .runtime_errors = &.{}, .cancelled = true };
            }
        }

        if (targets.contains(.argument_spec_entry)) {
            for (doc.argument_spec_entries) |*spec_entry| {
                const node_cel = try spec_entry.toCel(ea);
                const cancelled = try evalSingleTarget(
                    out_alloc,
                    ea,
                    doc,
                    line_index,
                    entry,
                    node_cel,
                    doc_cel,
                    env.emptyMapValue(),
                    meta_cel,
                    opts_cel,
                    spec_entry.span,
                    spec_entry.field_spans,
                    &diags,
                    &runtime_errors,
                    &per_rule_count,
                    cancel,
                );
                if (cancelled) return .{ .diagnostics = &.{}, .runtime_errors = &.{}, .cancelled = true };
            }
        }

        if (targets.contains(.argument_spec)) {
            for (doc.argument_specs) |*spec| {
                const node_cel = try spec.toCel(ea);
                const cancelled = try evalSingleTarget(
                    out_alloc,
                    ea,
                    doc,
                    line_index,
                    entry,
                    node_cel,
                    doc_cel,
                    env.emptyMapValue(),
                    meta_cel,
                    opts_cel,
                    spec.span,
                    spec.field_spans,
                    &diags,
                    &runtime_errors,
                    &per_rule_count,
                    cancel,
                );
                if (cancelled) return .{ .diagnostics = &.{}, .runtime_errors = &.{}, .cancelled = true };
            }
        }

        if (targets.contains(.parse_issue)) {
            for (doc.parse_issues) |*iss| {
                const node_cel = try iss.toCel(ea);
                const cancelled = try evalSingleTarget(
                    out_alloc,
                    ea,
                    doc,
                    line_index,
                    entry,
                    node_cel,
                    doc_cel,
                    env.emptyMapValue(),
                    meta_cel,
                    opts_cel,
                    iss.span,
                    &.{},
                    &diags,
                    &runtime_errors,
                    &per_rule_count,
                    cancel,
                );
                if (cancelled) return .{ .diagnostics = &.{}, .runtime_errors = &.{}, .cancelled = true };
            }
        }
    }

    return .{
        .diagnostics = try diags.toOwnedSlice(out_alloc),
        .runtime_errors = try runtime_errors.toOwnedSlice(out_alloc),
        .cancelled = false,
    };
}

fn evalSingleTarget(
    out_alloc: Allocator,
    eval_alloc: Allocator,
    doc: *const ast.DocumentAst,
    line_index: doc_mod.LineIndex,
    entry: *registry.WorkerRuleEntry,
    node_cel: env.Value,
    doc_cel: env.Value,
    ctx_cel: env.Value,
    meta_cel: env.Value,
    opts_cel: env.Value,
    node_span: ast.Span,
    field_spans: []const ast.span.FieldSpan,
    diags: *std.ArrayList(lsp_types.Diagnostic),
    runtime_errors: *std.ArrayList(RuntimeError),
    per_rule_count: *usize,
    cancel: ?*const std.atomic.Value(bool),
) !bool {
    if (isCancelled(cancel)) return true;
    if (diags.items.len >= limits.max_diagnostics_per_document) return false;
    if (per_rule_count.* >= limits.max_diagnostics_per_rule_per_document) return false;

    const resolved_span = resolveSpan(node_span, field_spans, entry.rule.meta.field).clamp(doc.source.len);
    const field_lc = ast.span.lineColAt(doc.source, resolved_span.start);
    const node_lc = ast.span.lineColAt(doc.source, @min(node_span.start, doc.source.len));

    const loc_cel = try (env.LocationValue{
        .path = doc.display_path,
        .line = @intCast(field_lc.line),
        .column = @intCast(field_lc.column),
    }).toCel(eval_alloc);

    const bindings = env.makeBindings(node_cel, loc_cel, doc_cel, ctx_cel, meta_cel, opts_cel);
    const outcome = try entry.rule.evaluate(eval_alloc, &bindings);
    switch (outcome) {
        .no_match => {},
        .match => |msg| {
            if (ast.noqa.isSuppressed(doc.noqa_directives, entry.rule.meta.id, node_lc.line, field_lc.line)) {
                return false;
            }
            const range = line_index.rangeFromOffsets(resolved_span.start, resolved_span.end);
            try diags.append(out_alloc, .{
                .range = range,
                .severity = toLspSeverity(entry.effective_severity),
                .code = try out_alloc.dupe(u8, entry.rule.meta.id),
                .source = "zals-cel",
                .message = try out_alloc.dupe(u8, msg),
            });
            per_rule_count.* += 1;
        },
        .condition_error, .condition_type_error, .message_error, .message_type_error, .limit_error => |err_msg| {
            if (runtime_errors.items.len < 32) {
                try runtime_errors.append(out_alloc, .{
                    .rule_id = try out_alloc.dupe(u8, entry.rule.meta.id),
                    .message = try out_alloc.dupe(u8, err_msg),
                });
            }
        },
    }
    return false;
}

fn resolveSpan(node_span: ast.Span, field_spans: []const ast.span.FieldSpan, selector: ?[]const u8) ast.Span {
    const sel = selector orelse return node_span;
    if (std.mem.eql(u8, sel, "self") or std.mem.eql(u8, sel, "root")) return node_span;
    return ast.span.lookupFieldSpan(field_spans, sel) orelse node_span;
}

fn toLspSeverity(sev: schema.Severity) lsp_types.DiagnosticSeverity {
    return switch (sev) {
        .@"error" => .err,
        .warning => .warning,
        .info => .information,
        .hint => .hint,
    };
}

fn isCancelled(cancel: ?*const std.atomic.Value(bool)) bool {
    const flag = cancel orelse return false;
    return flag.load(.acquire);
}

test "vertical slice evaluates parse issues, tasks, plays, field selectors, and noqa" {
    const src =
        \\- hosts: all
        \\  tasks:
        \\    - ansible.builtin.shell: echo hi
        \\      become_user: root
        \\    - name: suppressed shell # noqa: no-changed-when
        \\      ansible.builtin.shell: echo ok
        \\    - name: tag does not suppress
        \\      ansible.builtin.shell: echo tag
        \\      tags:
        \\        - skip_ansible_lint
        \\    - name: only name task
        \\
    ;
    var doc = try ast.build(std.testing.allocator, "/ws/site.yml", "site.yml", src);
    defer doc.deinit();

    var rs = try registry.buildRuleSet(std.testing.allocator, 1, .{});
    defer rs.deinit();
    var worker_rs = try rs.cloneForWorker(std.testing.allocator);
    defer worker_rs.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = try evaluateDocument(arena.allocator(), &doc, &worker_rs, .{}, .utf16, null);

    var saw_play_name = false;
    var saw_task_missing = false;
    var saw_partial_become = false;
    var saw_parse_issue = false;
    var no_changed_when_count: usize = 0;

    for (res.diagnostics) |d| {
        try std.testing.expectEqualStrings("zals-cel", d.source.?);
        const code = d.code.?;
        if (std.mem.eql(u8, code, "name[play]")) saw_play_name = true;
        if (std.mem.eql(u8, code, "name[missing]")) saw_task_missing = true;
        if (std.mem.eql(u8, code, "partial-become[task]")) saw_partial_become = true;
        if (std.mem.eql(u8, code, "zals/parse-issue")) saw_parse_issue = true;
        if (std.mem.eql(u8, code, "no-changed-when")) no_changed_when_count += 1;
    }

    try std.testing.expect(saw_play_name);
    try std.testing.expect(saw_task_missing);
    try std.testing.expect(saw_partial_become);
    try std.testing.expect(saw_parse_issue);
    try std.testing.expectEqual(@as(usize, 2), no_changed_when_count);
}

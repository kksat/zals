pub const BuiltinSource = struct {
    name: []const u8,
    source: []const u8,
};

pub const all = [_]BuiltinSource{
    .{ .name = "parse_issue.cel", .source = @embedFile("builtins/parse_issue.cel") },
    .{ .name = "name_play.cel", .source = @embedFile("builtins/name_play.cel") },
    .{ .name = "name_missing.cel", .source = @embedFile("builtins/name_missing.cel") },
    .{ .name = "deprecated_local_action.cel", .source = @embedFile("builtins/deprecated_local_action.cel") },
    .{ .name = "partial_become_task.cel", .source = @embedFile("builtins/partial_become_task.cel") },
    .{ .name = "no_changed_when.cel", .source = @embedFile("builtins/no_changed_when.cel") },
};

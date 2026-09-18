//! Server capabilities and the semantic-token legend.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");

/// Legend order defines the token type indices used on the wire.
pub const token_types = [_][]const u8{ "method", "class", "keyword", "property" };
pub const token_modifiers = [_][]const u8{"definition"};

pub const TokenType = enum(u32) {
    method = 0,
    class = 1,
    keyword = 2,
    property = 3,
};

pub const Modifier = struct {
    pub const definition: u32 = 1 << 0;
};

pub fn build(a: Allocator, encoding: []const u8, workspace_folders: bool) !Value {
    var caps = json_util.obj(a);

    try caps.put("positionEncoding", json_util.str(encoding));

    var sync = json_util.obj(a);
    try sync.put("openClose", json_util.booleanValue(true));
    try sync.put("change", json_util.num(2)); // Incremental
    var save = json_util.obj(a);
    try save.put("includeText", json_util.booleanValue(false));
    try sync.put("save", .{ .object = save });
    try caps.put("textDocumentSync", .{ .object = sync });

    var legend = json_util.obj(a);
    try legend.put("tokenTypes", try stringArray(a, &token_types));
    try legend.put("tokenModifiers", try stringArray(a, &token_modifiers));
    var sem = json_util.obj(a);
    try sem.put("full", json_util.booleanValue(true));
    try sem.put("legend", .{ .object = legend });
    try caps.put("semanticTokensProvider", .{ .object = sem });

    try caps.put("hoverProvider", json_util.booleanValue(true));

    var completion = json_util.obj(a);
    try completion.put("resolveProvider", json_util.booleanValue(true));
    try caps.put("completionProvider", .{ .object = completion });

    try caps.put("definitionProvider", json_util.booleanValue(true));

    var workspace = json_util.obj(a);
    if (workspace_folders) {
        var wf = json_util.obj(a);
        try wf.put("supported", json_util.booleanValue(true));
        try wf.put("changeNotifications", json_util.booleanValue(true));
        try workspace.put("workspaceFolders", .{ .object = wf });
    }
    try caps.put("workspace", .{ .object = workspace });

    return .{ .object = caps };
}

fn stringArray(a: Allocator, items: []const []const u8) !Value {
    var arr = std.json.Array.init(a);
    for (items) |s| try arr.append(json_util.str(s));
    return .{ .array = arr };
}

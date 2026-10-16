//! Core LSP data types used by the server.
//!
//! Only the subset needed for Tier 1 is defined. Types are plain structs so
//! `std.json` can serialize them directly; enums that must be integers on the
//! wire provide a `jsonStringify` method.

const std = @import("std");

pub const Position = struct {
    line: u32,
    character: u32,

    pub fn eql(a: Position, b: Position) bool {
        return a.line == b.line and a.character == b.character;
    }
};

pub const Range = struct {
    start: Position,
    end: Position,

    pub fn eql(a: Range, b: Range) bool {
        return a.start.eql(b.start) and a.end.eql(b.end);
    }
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const DiagnosticSeverity = enum(u8) {
    err = 1,
    warning = 2,
    information = 3,
    hint = 4,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.write(@intFromEnum(self));
    }
};

pub const Diagnostic = struct {
    range: Range,
    severity: ?DiagnosticSeverity = null,
    code: ?[]const u8 = null,
    source: ?[]const u8 = null,
    message: []const u8,
};

pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8,
    version: i64,
    text: []const u8,
};

pub const TextDocumentContentChangeEvent = struct {
    range: ?Range = null,
    rangeLength: ?u32 = null,
    text: []const u8,
};

pub const MarkupKind = enum {
    plaintext,
    markdown,
};

pub const MarkupContent = struct {
    kind: MarkupKind,
    value: []const u8,
};

pub const Hover = struct {
    contents: MarkupContent,
    range: ?Range = null,
};

pub const CompletionItemKind = enum(u8) {
    text = 1,
    method = 2,
    function = 3,
    constructor = 4,
    field = 5,
    variable = 6,
    class = 7,
    interface = 8,
    module = 9,
    property = 10,
    unit = 11,
    value = 12,
    enum_member = 20,
    keyword = 14,
    snippet = 15,
    file = 17,
    reference = 18,
    folder = 19,
    constant = 21,
    @"struct" = 22,
    event = 23,
    operator = 24,
    type_parameter = 25,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.write(@intFromEnum(self));
    }
};

pub const InsertTextFormat = enum(u8) {
    plain_text = 1,
    snippet = 2,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.write(@intFromEnum(self));
    }
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: ?CompletionItemKind = null,
    detail: ?[]const u8 = null,
    documentation: ?MarkupContent = null,
    insertText: ?[]const u8 = null,
    insertTextFormat: ?InsertTextFormat = null,
    sortText: ?[]const u8 = null,
    filterText: ?[]const u8 = null,
    /// Opaque data echoed back on `completionItem/resolve`.
    data: ?std.json.Value = null,
};

pub const CompletionList = struct {
    isIncomplete: bool = false,
    items: []const CompletionItem,
};

pub const SemanticToken = struct {
    deltaLine: u32,
    deltaStart: u32,
    length: u32,
    tokenType: u32,
    tokenModifiers: u32,
};

pub const SemanticTokens = struct {
    resultId: ?[]const u8 = null,
    data: []const u32,
};

/// One semantic token before delta encoding. `kind` and `mods` are legend indices.
pub const AbsoluteToken = struct {
    line: u32,
    start: u32,
    length: u32,
    kind: u32,
    mods: u32 = 0,
};

pub const TextEdit = struct {
    range: Range,
    newText: []const u8,
};

pub const PrepareRename = struct {
    range: Range,
    placeholder: []const u8,
};

pub const WorkspaceEdit = struct {
    changes: ?std.json.Value = null,
    documentChanges: ?std.json.Value = null,
};

/// LSP `SymbolKind`. Values are fixed by the protocol.
pub const SymbolKind = enum(u8) {
    file = 1,
    module = 2,
    namespace = 3,
    package = 4,
    class = 5,
    method = 6,
    property = 7,
    field = 8,
    constructor = 9,
    @"enum" = 10,
    interface = 11,
    function = 12,
    variable = 13,
    constant = 14,
    string = 15,
    number = 16,
    boolean = 17,
    array = 18,
    object = 19,
    key = 20,
    null = 21,
    enum_member = 22,
    @"struct" = 23,
    event = 24,
    operator = 25,
    type_parameter = 26,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.write(@intFromEnum(self));
    }
};

/// LSP `DocumentSymbol`: a hierarchical outline entry for one document.
pub const DocumentSymbol = struct {
    name: []const u8,
    detail: ?[]const u8 = null,
    kind: SymbolKind,
    range: Range,
    selectionRange: Range,
    children: ?[]const DocumentSymbol = null,
};

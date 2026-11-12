//! Shared types and kind constants for code actions (ADR-0028, ADR-0030).

/// The code-action kind the debug actions use.
pub const kind = "refactor";

/// The code-action kind the extract actions use.
pub const extract_kind = "refactor.extract";

/// A resolved action: a title, a kind, and a byte-range edit.
pub const Action = struct {
    title: []const u8,
    kind: []const u8,
    /// Inclusive start byte offset of the edit range.
    start: usize,
    /// Exclusive end byte offset of the edit range.
    end: usize,
    new_text: []const u8,
    /// A file to create alongside the edit, for extract actions.
    create: ?CreateFile = null,
};

/// A file to create as part of an action's `WorkspaceEdit`.
pub const CreateFile = struct {
    /// Absolute filesystem path of the new file.
    path: []const u8,
    /// The new file's contents.
    text: []const u8,
};

/// The cursor or selection, as byte offsets into the document.
pub const Selection = struct {
    start: usize,
    end: usize,
};

/// Everything the extract actions need from the filesystem.
pub const ExtractEnv = struct {
    /// Directory the new file is created in (the current file's directory).
    dir: []const u8,
    /// Extension for the new file, including the dot.
    ext: []const u8,
    /// True when `path` already exists.
    exists: *const fn ([]const u8) bool,
};

/// A source snippet with one <marked span>. The markers exist only in tests,
/// never in the Ansible Workspace. Matching zero or multiple snippets is an
/// error, not a request to pick an arbitrary occurrence.
pub const Anchor = struct {
    path: []const u8,
    snippet: []const u8,
};

/// Navigation targets are either a marked source span or the beginning of a
/// file. Paths are relative to the fixture Workspace, except for the explicit
/// `@deps/` prefix, which names the configured Installed-collection path.
pub const ExpectedLocation = union(enum) {
    marked: Anchor,
    file_start: []const u8,
};

pub const Method = enum { references, definition, implementation, hover, prepare_rename, rename };

pub const Case = struct {
    name: []const u8,
    method: Method,
    from: Anchor,
    /// Meaningful only for references. Both values are stated explicitly for
    /// variable cases; expected locations are never derived from this flag.
    include_declaration: bool = true,
    expected: []const ExpectedLocation,
    /// Hover cases also assert independently specified documentation excerpts.
    markdown_contains: []const []const u8 = &.{},
    markdown_excludes: []const []const u8 = &.{},
    /// Used by prepare_rename (expected placeholder) and rename (newName).
    placeholder: []const u8 = "",
    new_name: []const u8 = "renamed_var",
};

pub fn cursor(path: []const u8, snippet: []const u8) Anchor {
    return .{ .path = path, .snippet = snippet };
}

pub fn span(path: []const u8, snippet: []const u8) ExpectedLocation {
    return .{ .marked = .{ .path = path, .snippet = snippet } };
}

pub fn fileStart(path: []const u8) ExpectedLocation {
    return .{ .file_start = path };
}

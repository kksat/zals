pub const kind = "refactor";

pub const extract_kind = "refactor.extract";

pub const Action = struct {
    title: []const u8,
    kind: []const u8,
    start: usize,
    end: usize,
    new_text: []const u8,
    create: ?CreateFile = null,
};

pub const CreateFile = struct {
    path: []const u8,
    text: []const u8,
};

pub const Selection = struct {
    start: usize,
    end: usize,
};

pub const ExtractEnv = struct {
    dir: []const u8,
    ext: []const u8,
    exists: *const fn ([]const u8) bool,
};

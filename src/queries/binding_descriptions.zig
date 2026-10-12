//! Request-local interpretation of binding values. Ranked search and Markdown
//! display policy stay with callers; source capture, revision checks and YAML
//! key/value association live here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Server = @import("../lsp/server.zig").Server;
const server_source = @import("../providers/variable_source.zig");
const variables = @import("../variables/root.zig");
const facts_mod = @import("../workspace/facts.zig");
const yaml = @import("../yaml/root.zig");

/// A byte offset either discovered through this cache's FileSource, or tied to
/// an indexed source revision. Unknown indexed revisions fail closed, not as
/// offsets into whatever text happens to be on disk now.
pub const Binding = struct {
    uri: []const u8,
    start: usize,
    revision: ?Revision = null,

    pub const Revision = struct {
        fingerprint: ?facts_mod.SourceFingerprint,
        line: usize,
    };

    pub fn indexed(uri: []const u8, start: usize, facts: facts_mod.Facts) Binding {
        var line: usize = 1;
        for (facts.binding_lines) |binding| {
            if (binding.start == start) {
                line = binding.line;
                break;
            }
        }
        return .{ .uri = uri, .start = start, .revision = .{ .fingerprint = facts.source_fingerprint, .line = line } };
    }
};

pub const Description = struct {
    line: usize,
    /// Raw source value, borrowing the cache's captured bytes. Presentation
    /// owns whitespace normalization, dedenting, truncation and Markdown.
    value: ?[]const u8 = null,
};

/// The real open-buffer/filesystem adapter with immutable request-local text
/// capture and lazy parsing. Use source() for fallback discovery so its offsets
/// and subsequent descriptions refer to the same bytes. Indexed bindings carry
/// their own revision proof. This cache only borrows the handler's query lease;
/// it never acquires a nested lease or retains storage past the request.
pub const Cache = struct {
    allocator: Allocator,
    files: server_source.ServerSource,
    interpretations: std.StringHashMap(*Interpretation),

    const Interpretation = struct {
        text: []const u8,
        fingerprint: facts_mod.SourceFingerprint,
        exists: bool,
        parsed: bool = false,
        forest: ?yaml.Forest = null,
    };

    pub fn init(server: *Server, a: Allocator) Cache {
        return .{ .allocator = a, .files = .{ .server = server }, .interpretations = std.StringHashMap(*Interpretation).init(a) };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.interpretations.iterator();
        while (it.next()) |item| {
            const file = item.value_ptr.*;
            if (file.forest) |*forest| forest.deinit();
            if (file.exists) self.allocator.free(file.text);
            self.allocator.destroy(file);
            self.allocator.free(item.key_ptr.*);
        }
        self.interpretations.deinit();
    }

    pub fn source(self: *Cache) variables.FileSource {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Interpret only bindings selected for display. A mismatched source keeps
    /// its indexed line but has no value; even a same-named key at the old byte
    /// offset is not evidence of revision identity. Never parse mismatched text.
    pub fn describe(self: *Cache, binding: Binding) !Description {
        if (binding.revision) |revision| if (revision.fingerprint == null) return .{ .line = revision.line };
        const file = try self.capture(binding.uri);
        if (binding.revision) |revision| {
            if (!file.exists or !std.mem.eql(u8, &revision.fingerprint.?, &file.fingerprint)) return .{ .line = revision.line };
        }
        const line = std.mem.count(u8, file.text[0..@min(binding.start, file.text.len)], "\n") + 1;
        if (!file.parsed) {
            file.parsed = true;
            // Parser storage is explicitly released, not backed by the request
            // arena. Source bytes remain captured for the whole request.
            file.forest = yaml.parse(std.heap.page_allocator, file.text) catch null;
        }
        if (file.forest) |*forest| {
            for (forest.roots) |root| {
                const pair = pairWithKeyAt(root, binding.start) orelse continue;
                const value = pair.val orelse break;
                if (value.start < value.end and value.end <= file.text.len) return .{ .line = line, .value = file.text[value.start..value.end] };
                break;
            }
        }
        return .{ .line = line };
    }

    fn capture(self: *Cache, uri: []const u8) !*Interpretation {
        if (self.interpretations.get(uri)) |file| return file;
        const body = try self.files.source().read(self.allocator, uri);
        errdefer if (body) |text| self.allocator.free(text);
        const file = try self.allocator.create(Interpretation);
        errdefer self.allocator.destroy(file);
        file.* = .{ .text = body orelse "", .fingerprint = facts_mod.sourceFingerprint(body orelse ""), .exists = body != null };
        const key = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(key);
        try self.interpretations.put(key, file);
        return file;
    }

    fn read(ptr: *anyopaque, a: Allocator, uri: []const u8) anyerror!?[]const u8 {
        const self: *Cache = @ptrCast(@alignCast(ptr));
        const file = try self.capture(uri);
        // FileSource callers may free returned bytes (notably role metadata
        // probes), so preserve that ownership contract while reusing the read.
        return if (file.exists) try a.dupe(u8, file.text) else null;
    }

    fn listDir(ptr: *anyopaque, a: Allocator, path: []const u8) anyerror![]const variables.DirEntry {
        const self: *Cache = @ptrCast(@alignCast(ptr));
        return self.files.source().listDir(a, path);
    }

    const vtable = variables.FileSource.VTable{ .read = read, .listDir = listDir };
};

fn pairWithKeyAt(node: *const yaml.Node, start: usize) ?*const yaml.Node {
    switch (node.kind) {
        .map => for (node.items) |pair| {
            // Definition ranges may begin inside the YAML key's quotes.
            if (pair.key) |key| if (key.start <= start and start < key.end) return pair;
            if (pair.val) |value| if (pairWithKeyAt(value, start)) |found| return found;
        },
        .seq => for (node.items) |item| {
            if (pairWithKeyAt(item, start)) |found| return found;
        },
        else => {},
    }
    return null;
}

//! Request-local interpretation of binding values. Ranked search and Markdown
//! display policy stay with callers, and text capture with the navigation
//! context; revision checks and YAML key/value association live here.

const std = @import("std");
const Context = @import("context.zig").Context;
const facts_mod = @import("../workspace/facts.zig");
const yaml = @import("../yaml/root.zig");

/// A byte offset either discovered through the context's FileSource, or tied to
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

/// Lazy interpretation over the navigation context's request-local text
/// capture. Offsets discovered through `Context.source()` and descriptions
/// refer to the same bytes by construction; indexed bindings carry their own
/// revision proof. The cache never retains storage past the request.
pub const Cache = struct {
    context: *Context,
    interpretations: std.StringHashMap(*Interpretation),

    const Interpretation = struct {
        text: []const u8,
        fingerprint: facts_mod.SourceFingerprint,
        exists: bool,
        parsed: bool = false,
        forest: ?yaml.Forest = null,
    };

    pub fn init(context: *Context) Cache {
        return .{ .context = context, .interpretations = std.StringHashMap(*Interpretation).init(context.allocator) };
    }

    pub fn deinit(self: *Cache) void {
        const a = self.context.allocator;
        var it = self.interpretations.iterator();
        while (it.next()) |item| {
            const file = item.value_ptr.*;
            if (file.forest) |*forest| forest.deinit();
            a.destroy(file);
            a.free(item.key_ptr.*);
        }
        self.interpretations.deinit();
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
            // Parser storage is explicitly released on cache teardown via
            // forest.deinit(), avoiding page_allocator mmap churn.
            file.forest = yaml.parse(self.context.allocator, file.text) catch null;
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
        const a = self.context.allocator;
        const body = try self.context.text(uri);
        const file = try a.create(Interpretation);
        errdefer a.destroy(file);
        file.* = .{ .text = body orelse "", .fingerprint = facts_mod.sourceFingerprint(body orelse ""), .exists = body != null };
        const key = try a.dupe(u8, uri);
        errdefer a.free(key);
        try self.interpretations.put(key, file);
        return file;
    }
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

//! In-process navigation fixtures for query tests: a temporary directory
//! (optionally a Workspace), a Workspace index filled by `scanNow`, a
//! document store, and a docs adapter that is never expected to run. No
//! `Server`, thread pool or transport.

const std = @import("std");
const Allocator = std.mem.Allocator;
const WorkspaceIndex = @import("../workspace/index.zig").WorkspaceIndex;
const DocumentStore = @import("../workspace/store.zig").DocumentStore;
const DocsLibrary = @import("../services/docs.zig").DocsLibrary;
const paths = @import("../paths.zig");
const context_mod = @import("context.zig");

pub const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: *std.heap.ArenaAllocator,
    /// Real path of the temporary directory.
    root: []const u8,
    workspace: bool,
    index: *WorkspaceIndex,
    documents: DocumentStore,
    lease: ?WorkspaceIndex.QueryLease = null,

    /// A temporary directory; a session Workspace (with a `.git` marker)
    /// when `workspace` is true. Do not move the fixture after `context`.
    pub fn init(workspace: bool) !Fixture {
        const gpa = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        if (workspace) try tmp.dir.makePath(".git");
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        return .{
            .tmp = tmp,
            .arena = arena,
            .root = try tmp.dir.realpathAlloc(arena.allocator(), "."),
            .workspace = workspace,
            .index = try WorkspaceIndex.create(gpa),
            .documents = DocumentStore.init(gpa, .utf16),
        };
    }

    pub fn deinit(self: *Fixture) void {
        if (self.lease) |*lease| lease.release();
        self.index.destroy();
        self.documents.deinit();
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
        self.tmp.cleanup();
    }

    pub fn allocator(self: *Fixture) Allocator {
        return self.arena.allocator();
    }

    pub fn path(self: *Fixture, relative: []const u8) ![]const u8 {
        return std.fs.path.join(self.allocator(), &.{ self.root, relative });
    }

    pub fn uri(self: *Fixture, relative: []const u8) ![]const u8 {
        return paths.pathToUri(self.allocator(), try self.path(relative));
    }

    /// Write a file on disk, creating its directories.
    pub fn write(self: *Fixture, relative: []const u8, text: []const u8) !void {
        if (std.fs.path.dirname(relative)) |dir| try self.tmp.dir.makePath(dir);
        try self.tmp.dir.writeFile(.{ .sub_path = relative, .data = text });
    }

    /// Open a document with unsaved `text`; returns its URI.
    pub fn open(self: *Fixture, relative: []const u8, text: []const u8) ![]const u8 {
        const doc_uri = try self.uri(relative);
        _ = try self.documents.open(doc_uri, "ansible", 1, text);
        return doc_uri;
    }

    /// Scan the Workspace (when there is one), acquire a request lease and
    /// build the navigation context over it.
    pub fn context(self: *Fixture) !context_mod.Context {
        std.debug.assert(self.lease == null);
        const a = self.allocator();
        if (self.workspace) try self.index.scanNow(self.root, ".git");
        self.lease = self.index.acquireQuery(false);
        const roots: []const []const u8 = if (self.workspace) try a.dupe([]const u8, &.{self.root}) else &.{};
        return context_mod.Context.init(a, &self.lease.?, .{
            .documents = &self.documents,
            .workspaces = .{ .roots = roots, .marker = ".git", .venv = "" },
            .docs = .{ .ptr = self, .forPathsFn = noDocs },
            .encoding = .utf16,
        });
    }

    /// Byte offset of the first `needle` in `text`, plus `skip`.
    pub fn offsetOf(text: []const u8, needle: []const u8, skip: usize) usize {
        return (std.mem.indexOf(u8, text, needle) orelse unreachable) + skip;
    }

    fn noDocs(_: *anyopaque, _: []const []const u8) anyerror!*DocsLibrary {
        return error.DocsUnavailableInTests;
    }
};

//! The request-scoped navigation context (ADR-0031, ADR-0032).
//!
//! One value answers what navigation asks of the session during a request:
//! the files of the Workspace that owns a path, with open documents winning
//! over their indexed copies; the text of a URI; the LSP `Location` of a span
//! under the client's position encoding; the search paths and Role resolver
//! for a referencing file; the Workspace collections; and the module docs
//! library for a file. Each answer is computed at most once per request, so
//! every query in the request sees the same bytes, offsets and files.
//!
//! Lifetime. Holding a Context is holding the request's index lease. Build it
//! after `WorkspaceIndex.acquireQuery` and drop it before `release`; index
//! reads happen only through it. It borrows the document store and session
//! inputs, which notifications alone mutate, so they stay stable while a
//! request runs on the main thread (ADR-0011). All storage lives in the
//! request allocator (ADR-0013); nothing it returns may outlive the request.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../lsp/types.zig");
const document_mod = @import("../workspace/document.zig");
const Document = document_mod.Document;
const LineIndex = document_mod.LineIndex;
const DocumentStore = @import("../workspace/store.zig").DocumentStore;
const workspace_index = @import("../workspace/index.zig");
const WorkspaceIndex = workspace_index.WorkspaceIndex;
const facts_mod = @import("../workspace/facts.zig");
const discover = @import("../workspace/discover.zig");
const roots_mod = @import("../workspace/roots.zig");
const yaml = @import("../yaml/root.zig");
const variables = @import("../variables/root.zig");
const roles = @import("../roles/root.zig");
const paths = @import("../paths.zig");
const project_config = @import("../services/project_config.zig");
const AnsibleConfig = @import("../services/ansible_config.zig").AnsibleConfig;
const DocsLibrary = @import("../services/docs.zig").DocsLibrary;
const ContextLibraries = @import("../services/docs_service.zig").ContextLibraries;
pub const view = @import("../workspace/view.zig");

pub const File = view.File;
pub const WorkspaceCollection = roles.resolve.WorkspaceCollection;

/// The session's Workspaces as one request sees them (ADR-0014, ADR-0032).
pub const Workspaces = struct {
    /// Session Workspace roots, as paths.
    roots: []const []const u8 = &.{},
    marker: []const u8 = roots_mod.default_marker,
    /// The selected virtual environment (ADR-0037).
    venv: []const u8 = ".venv",
    /// Lazily dumped `ansible-config` fallback paths.
    ansible_config: ?*AnsibleConfig = null,
};

/// The module docs library for a list of effective collections paths
/// (ADR-0037). Getting a cold library may shell out to `ansible-doc`.
pub const Docs = struct {
    ptr: *anyopaque,
    forPathsFn: *const fn (ptr: *anyopaque, paths: []const []const u8) anyerror!*DocsLibrary,

    pub fn contextual(libraries: *ContextLibraries) Docs {
        return .{ .ptr = libraries, .forPathsFn = contextualForPaths };
    }

    fn contextualForPaths(ptr: *anyopaque, collections_paths: []const []const u8) anyerror!*DocsLibrary {
        const libraries: *ContextLibraries = @ptrCast(@alignCast(ptr));
        return libraries.forPaths(collections_paths);
    }
};

/// What the server knows about its session, borrowed for one request.
pub const Session = struct {
    /// Open documents.
    documents: *DocumentStore,
    workspaces: Workspaces = .{},
    docs: Docs,
    /// The client's position encoding.
    encoding: document_mod.PositionEncoding = .utf16,
};

/// One Workspace's files in this request. Open documents replace their
/// indexed copy, so unsaved edits win. A file that some vars load in the
/// Workspace targets binds its load-only keys (ADR-0045).
pub const Workspace = struct {
    root: []const u8,
    files: []const File,
    /// Targets of every vars load in the Workspace.
    loaded: std.StringHashMap(void),
    collections: ?[]const WorkspaceCollection = null,

    pub fn isLoaded(self: *const Workspace, path: []const u8) bool {
        return self.loaded.contains(path);
    }
};

pub const Context = struct {
    allocator: Allocator,
    lease: *const WorkspaceIndex.QueryLease,
    session: Session,
    /// File directory → owning session Workspace root.
    owners: std.StringHashMap(?[]const u8),
    roles_paths: std.StringHashMap([]const []const u8),
    collections_paths: std.StringHashMap([]const []const u8),
    /// Disk text by URI; open documents are read directly.
    texts: std.StringHashMap(?[]const u8),
    line_indices: std.StringHashMap(LineIndex),
    /// Per root: open documents that belong to it, by path.
    open: std.StringHashMap(*std.StringHashMap(*Document)),
    /// Facts of open documents, by path.
    open_facts: std.StringHashMap(OpenFacts),
    workspaces: std.StringHashMap(*Workspace),

    const OpenFacts = struct { root: []const u8, facts: facts_mod.Facts };

    pub fn init(a: Allocator, lease: *const WorkspaceIndex.QueryLease, session: Session) Context {
        std.debug.assert(lease.index != null);
        return .{
            .allocator = a,
            .lease = lease,
            .session = session,
            .owners = std.StringHashMap(?[]const u8).init(a),
            .roles_paths = std.StringHashMap([]const []const u8).init(a),
            .collections_paths = std.StringHashMap([]const []const u8).init(a),
            .texts = std.StringHashMap(?[]const u8).init(a),
            .line_indices = std.StringHashMap(LineIndex).init(a),
            .open = std.StringHashMap(*std.StringHashMap(*Document)).init(a),
            .open_facts = std.StringHashMap(OpenFacts).init(a),
            .workspaces = std.StringHashMap(*Workspace).init(a),
        };
    }

    fn index(self: *const Context) *WorkspaceIndex {
        return self.lease.index orelse unreachable;
    }

    /// The filesystem path of `uri`. Every URI-to-path conversion in a
    /// navigation request goes through here, so path-form rules (for
    /// example symlinked roots) apply in one place.
    pub fn pathOf(self: *const Context, uri: []const u8) ![]const u8 {
        return paths.uriToPath(self.allocator, uri);
    }

    /// The open document at `uri`, or null.
    pub fn document(self: *const Context, uri: []const u8) ?*Document {
        return self.session.documents.get(uri);
    }

    /// Session Workspace roots, as paths.
    pub fn roots(self: *const Context) []const []const u8 {
        return self.session.workspaces.roots;
    }

    /// The session Workspace root that owns the file at `path`, or null.
    /// Memoised per directory: a file's owner is its directory's owner.
    pub fn workspaceRoot(self: *Context, path: []const u8) ?[]const u8 {
        const dir = std.fs.path.dirname(path) orelse path;
        if (self.owners.get(dir)) |owner| return owner;
        const owned = roots_mod.owning(self.allocator, path, self.session.workspaces.roots, self.session.workspaces.marker) catch return null;
        const owner = if (owned) |o| o[0] else null;
        self.owners.put(dir, owner) catch {};
        return owner;
    }

    /// The Workspace that owns the file at `uri`, or null without a session
    /// Workspace.
    pub fn workspaceOf(self: *Context, uri: []const u8) !?*Workspace {
        const root = self.workspaceRoot(try self.pathOf(uri)) orelse return null;
        return try self.workspace(root);
    }

    /// The Workspace rooted at `root`, from the leased index and the open
    /// documents.
    pub fn workspace(self: *Context, root: []const u8) !*Workspace {
        if (self.workspaces.get(root)) |found| return found;
        const a = self.allocator;
        const files = try self.overlay(root, null);
        var loaded = std.StringHashMap(void).init(a);
        for (files) |f| {
            for (f.facts.var_loads) |load| try loaded.put(load.path, {});
        }
        for (files) |*f| {
            if (loaded.contains(f.path)) f.facts = try f.facts.loaded(a);
        }
        const found = try a.create(Workspace);
        found.* = .{ .root = root, .files = files, .loaded = loaded };
        try self.workspaces.put(root, found);
        return found;
    }

    /// The Workspace's files below `directory`, ordered like `workspace`, with
    /// the same open-document overlay but without load-target promotion.
    pub fn filesWithin(self: *Context, root: []const u8, directory: []const u8) ![]File {
        return self.overlay(root, directory);
    }

    /// One Workspace file: its open document, else its indexed entry, else
    /// null when neither belongs to `root`.
    pub fn workspaceFile(self: *Context, root: []const u8, path: []const u8) !?File {
        if ((try self.openIn(root)).get(path)) |doc| return try self.openFile(root, path, doc);
        const entry = self.index().get(path) orelse return null;
        if (!std.mem.eql(u8, entry.root, root)) return null;
        return .{ .path = entry.path, .uri = try paths.pathToUri(self.allocator, entry.path), .facts = entry.facts };
    }

    /// Indexed entries in path order, each replaced by its open document;
    /// then open documents the index does not know yet.
    fn overlay(self: *Context, root: []const u8, within: ?[]const u8) ![]File {
        const a = self.allocator;
        const open = try self.openIn(root);
        const entries = if (within) |dir| try self.index().entriesWithin(a, root, dir) else try self.index().entriesOf(a, root);
        var files = std.array_list.Managed(File).init(a);
        var replaced = std.StringHashMap(void).init(a);
        for (entries) |entry| {
            if (open.get(entry.path)) |doc| {
                try files.append(try self.openFile(root, entry.path, doc));
                try replaced.put(entry.path, {});
            } else {
                try files.append(.{ .path = entry.path, .uri = try paths.pathToUri(a, entry.path), .facts = entry.facts });
            }
        }
        var rest = open.iterator();
        while (rest.next()) |item| {
            const path = item.key_ptr.*;
            if (replaced.contains(path)) continue;
            if (within) |dir| if (!isBelow(path, dir)) continue;
            try files.append(try self.openFile(root, path, item.value_ptr.*));
        }
        return files.toOwnedSlice();
    }

    /// Open documents that belong to the Workspace at `root`, by path.
    fn openIn(self: *Context, root: []const u8) !*const std.StringHashMap(*Document) {
        if (self.open.get(root)) |found| return found;
        const a = self.allocator;
        const found = try a.create(std.StringHashMap(*Document));
        found.* = std.StringHashMap(*Document).init(a);
        var it = self.session.documents.docs.valueIterator();
        while (it.next()) |doc| {
            const path = self.pathOf(doc.*.uri) catch continue;
            if (!discover.belongsToWorkspace(root, path, self.session.workspaces.marker)) continue;
            if (!discover.isWorkspaceFile(path)) continue;
            try found.put(path, doc.*);
        }
        try self.open.put(root, found);
        return found;
    }

    /// An open document's facts, extracted once per request.
    fn openFile(self: *Context, root: []const u8, path: []const u8, doc: *Document) !File {
        if (self.open_facts.get(path)) |cached| {
            if (std.mem.eql(u8, cached.root, root)) return .{ .path = path, .uri = doc.uri, .facts = cached.facts };
        }
        const extracted = try facts_mod.extractIn(self.allocator, root, path, doc.bytes());
        try self.open_facts.put(path, .{ .root = root, .facts = extracted });
        return .{ .path = path, .uri = doc.uri, .facts = extracted };
    }

    /// Paths whose definitions can apply in the file at `path` (Reachable
    /// definitions): its role scope and that Role's invokers, resolved by
    /// directory with each invoking file's search paths, or the task file's
    /// includers; plus one level of their vars loads.
    pub fn reachableFiles(self: *Context, ws: *Workspace, path: []const u8) !view.Reachability {
        const a = self.allocator;
        const role_dir = roles.resolve.enclosingRole(path);
        var invokers = std.array_list.Managed([]const u8).init(a);
        if (role_dir) |target| {
            for (ws.files) |f| {
                if (f.facts.role_refs.len == 0) continue;
                const base = self.roleResolver(f.path, &.{});
                for (f.facts.role_refs) |ref| {
                    if (!roleRefResolvesTo(base, f.path, ref, target)) continue;
                    try invokers.append(f.path);
                    break;
                }
            }
        }
        return view.reachableFiles(a, ws.files, path, role_dir, invokers.items);
    }

    /// Metadata-defined collections: the Workspace root, or any directory below
    /// `ansible_collections/` within the Workspace's file set (ADR-0038).
    pub fn workspaceCollections(self: *Context, ws: *Workspace) ![]const WorkspaceCollection {
        if (ws.collections) |colls| return colls;
        const a = self.allocator;
        var out = std.array_list.Managed(WorkspaceCollection).init(a);
        for (ws.files) |f| {
            const base = std.fs.path.basename(f.path);
            if (!std.mem.eql(u8, base, "galaxy.yml") and !std.mem.eql(u8, base, "galaxy.yaml")) continue;
            const dir = std.fs.path.dirname(f.path) orelse continue;
            if (!isWorkspaceCollectionRoot(ws.root, dir)) continue;
            const body = (try self.text(f.uri)) orelse "";
            const name = galaxyName(a, body) orelse continue;
            try out.append(.{ .name = name, .dir = dir, .metadata_uri = f.uri });
        }
        const colls = try out.toOwnedSlice();
        ws.collections = colls;
        return colls;
    }

    /// The Role resolver for references in the file at `path`: that file's
    /// search paths (ADR-0032) and its Workspace's collections and `roles/`
    /// directories, with the reference site's declared collections.
    pub fn roleResolver(self: *Context, path: []const u8, declared_collections: []const []const u8) roles.Resolver {
        const root = self.workspaceRoot(path);
        const collections: []const WorkspaceCollection = if (root) |r| blk: {
            const ws = self.workspace(r) catch break :blk &.{};
            break :blk self.workspaceCollections(ws) catch &.{};
        } else &.{};
        return .{
            .allocator = self.allocator,
            .roles_paths = self.rolesPaths(path) catch &.{},
            .collections_paths = self.collectionsPaths(path) catch &.{},
            .workspace_collections = collections,
            .workspace_root = root,
            .workspace_roles_dirs = if (root) |r| if (self.index().info(r)) |info| info.roles_dirs else &.{} else &.{},
            .declared_collections = declared_collections,
        };
    }

    /// Every candidate directory for a role name referenced from `path`: the
    /// one Ansible would use, or all Workspace fallback matches.
    pub fn resolveRoles(self: *Context, name: []const u8, path: []const u8, declared_collections: []const []const u8) []const []const u8 {
        return self.roleResolver(path, declared_collections).resolveAll(name, path);
    }

    /// Role search paths for the file at `path`, memoised per directory.
    pub fn rolesPaths(self: *Context, path: []const u8) ![]const []const u8 {
        const dir = std.fs.path.dirname(path) orelse path;
        if (self.roles_paths.get(dir)) |found| return found;
        const found = try project_config.rolesPaths(self.allocator, self.projectContext(path), path);
        try self.roles_paths.put(dir, found);
        return found;
    }

    /// Collections paths for the file at `path`, memoised per directory.
    pub fn collectionsPaths(self: *Context, path: []const u8) ![]const []const u8 {
        const dir = std.fs.path.dirname(path) orelse path;
        if (self.collections_paths.get(dir)) |found| return found;
        const found = try project_config.collectionsPaths(self.allocator, self.projectContext(path), path);
        try self.collections_paths.put(dir, found);
        return found;
    }

    fn projectContext(self: *Context, path: []const u8) project_config.Context {
        const root = self.workspaceRoot(path);
        return .{
            .workspace_root = root,
            .venv = self.session.workspaces.venv,
            .config = self.session.workspaces.ansible_config,
            .workspace_collections = if (root) |r| if (self.index().info(r)) |info| info.collection_paths else &.{} else &.{},
        };
    }

    /// Module docs for the file at `uri`, under its effective collections
    /// paths. A cold library may shell out to `ansible-doc`.
    pub fn docsFor(self: *Context, uri: []const u8) !*DocsLibrary {
        const docs = self.session.docs;
        return docs.forPathsFn(docs.ptr, try self.collectionsPaths(try self.pathOf(uri)));
    }

    /// Text of `uri`: the open document, else the file on disk, read once per
    /// request. Null when neither exists. Every byte offset a query reports
    /// refers to this text.
    pub fn text(self: *Context, uri: []const u8) !?[]const u8 {
        if (self.document(uri)) |doc| return doc.bytes();
        if (self.texts.get(uri)) |cached| return cached;
        const body = readFile(self.allocator, try self.pathOf(uri));
        try self.texts.put(uri, body);
        return body;
    }

    /// The `Location` of `start..end` in `uri` under the client's encoding.
    pub fn location(self: *Context, uri: []const u8, start: usize, end: usize) !types.Location {
        if (self.document(uri)) |doc| return .{ .uri = uri, .range = doc.rangeFromOffsets(start, end) };
        const idx = if (self.line_indices.get(uri)) |cached| cached else blk: {
            const body = (try self.text(uri)) orelse "";
            const built = try LineIndex.init(self.allocator, body, self.session.encoding);
            try self.line_indices.put(uri, built);
            break :blk built;
        };
        return .{ .uri = uri, .range = idx.rangeFromOffsets(start, end) };
    }

    /// A `FileSource` over `text`, so per-request scans read the same bytes,
    /// and over the real directory listing.
    pub fn source(self: *Context) variables.FileSource {
        return .{ .ptr = self, .vtable = &source_vtable };
    }

    fn sourceRead(ptr: *anyopaque, a: Allocator, uri: []const u8) anyerror!?[]const u8 {
        const self: *Context = @ptrCast(@alignCast(ptr));
        // FileSource callers may free the returned bytes.
        const body = (try self.text(uri)) orelse return null;
        return try a.dupe(u8, body);
    }

    fn sourceListDir(_: *anyopaque, a: Allocator, path: []const u8) anyerror![]const variables.DirEntry {
        var out = std.array_list.Managed(variables.DirEntry).init(a);
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return out.toOwnedSlice();
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            try out.append(.{ .name = try a.dupe(u8, entry.name), .is_dir = entry.kind == .directory });
        }
        return out.toOwnedSlice();
    }

    const source_vtable = variables.FileSource.VTable{ .read = sourceRead, .listDir = sourceListDir };
};

/// A `Location` at the start of the file at `path` (ADR-0009).
pub fn fileLocation(a: Allocator, path: []const u8) !types.Location {
    return .{
        .uri = try paths.pathToUri(a, path),
        .range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } },
    };
}

/// `namespace.name` from `galaxy.yml` text.
pub fn galaxyName(a: Allocator, body: []const u8) ?[]const u8 {
    var forest = yaml.parse(a, body) catch return null;
    defer forest.deinit();
    for (forest.roots) |root| {
        if (!root.isMap()) continue;
        const ns = scalarField(root, "namespace") orelse continue;
        const n = scalarField(root, "name") orelse continue;
        return std.fmt.allocPrint(a, "{s}.{s}", .{ ns, n }) catch null;
    }
    return null;
}

fn scalarField(map: *yaml.Node, key: []const u8) ?[]const u8 {
    const p = yaml.dom.findPair(map, key) orelse return null;
    const v = p.val orelse return null;
    return v.stringValue();
}

fn isWorkspaceCollectionRoot(root: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, root, dir)) return true;
    if (dir.len <= root.len or !std.mem.startsWith(u8, dir, root) or dir[root.len] != std.fs.path.sep) return false;
    var parts = std.mem.splitScalar(u8, dir[root.len + 1 ..], std.fs.path.sep);
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "ansible_collections")) return parts.next() != null;
    }
    return false;
}

fn roleRefResolvesTo(base: roles.Resolver, file_path: []const u8, ref: facts_mod.RoleRef, target: []const u8) bool {
    var resolver = base;
    resolver.declared_collections = ref.declared_collections;
    for (resolver.resolveAll(ref.name, file_path)) |dir| {
        if (std.mem.eql(u8, dir, target)) return true;
    }
    return false;
}

fn isBelow(path: []const u8, dir: []const u8) bool {
    if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir)) return false;
    if (dir.len > 0 and (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\')) return true;
    return path[dir.len] == '/' or path[dir.len] == '\\';
}

fn readFile(a: Allocator, path: []const u8) ?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(a, 16 * 1024 * 1024) catch null;
}

const testing = std.testing;

test "galaxy name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("acme.web", galaxyName(arena.allocator(), "namespace: acme\nname: web\nversion: 1.0.0\n").?);
}

test "variable reachability joins short and FQCN role aliases, not colliding basenames" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("ansible_collections/ns/first/roles/notify/tasks");
    try tmp.dir.makePath("ansible_collections/ns/second/roles/notify/tasks");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const first = try std.fs.path.join(a, &.{ root, "ansible_collections/ns/first/roles/notify" });
    const second = try std.fs.path.join(a, &.{ root, "ansible_collections/ns/second/roles/notify" });
    const play_first = try std.fs.path.join(a, &.{ root, "first.yml" });
    const play_second = try std.fs.path.join(a, &.{ root, "second.yml" });
    const play_alias = try std.fs.path.join(a, &.{ root, "alias.yml" });
    const first_ref = (try facts_mod.extract(a, play_first, "- hosts: all\n  collections: [ns.first]\n  roles: [notify]\n")).role_refs[0];
    const second_ref = (try facts_mod.extract(a, play_second, "- hosts: all\n  collections: [ns.second]\n  roles: [notify]\n")).role_refs[0];
    const alias_ref = (try facts_mod.extract(a, play_alias, "- hosts: all\n  roles: [ns.first.notify]\n")).role_refs[0];
    const resolver = roles.Resolver{ .allocator = a, .collections_paths = &.{root}, .workspace_root = root };
    try testing.expect(roleRefResolvesTo(resolver, play_first, first_ref, first));
    try testing.expect(!roleRefResolvesTo(resolver, play_first, first_ref, second));
    try testing.expect(roleRefResolvesTo(resolver, play_second, second_ref, second));
    try testing.expect(!roleRefResolvesTo(resolver, play_second, second_ref, first));
    try testing.expect(roleRefResolvesTo(resolver, play_alias, alias_ref, first));
}

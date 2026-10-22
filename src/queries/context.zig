//! The request-scoped navigation context (ADR-0031, ADR-0032).
//!
//! One value answers what navigation asks of the session during a request:
//! the file set a search runs over (the Workspace that owns a path, or
//! without one its Role or Playbook scope), as Facts with open documents
//! winning over indexed or disk copies; the text of a URI; the LSP `Location` of a span
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
const workspace_session = @import("../workspace/session.zig");
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
    workspaces: workspace_session.Snapshot = .{},
    /// Lazily dumped `ansible-config` fallback paths (not Workspace lifecycle).
    ansible_config: ?*AnsibleConfig = null,
    docs: Docs,
    /// The client's position encoding.
    encoding: document_mod.PositionEncoding = .utf16,
};

/// Which files a search runs over (ADR-0032).
pub const Scope = union(enum) {
    /// Every file of the session Workspace rooted here.
    workspace: []const u8,
    /// A Role's conventional sources and one level of their vars loads: the
    /// Role scope of a file without a session Workspace, or a called Role.
    role: []const u8,
    /// One playbook or task file and one level of its vars loads: the
    /// Playbook scope of a file without a session Workspace.
    file: []const u8,
};

/// The files of one scope in this request, as Facts. Open documents replace
/// their indexed or disk copy, so unsaved edits win. A file that a vars load
/// in the set targets binds its load-only keys (ADR-0045): any load in a
/// Workspace, the base files' loads in a Role or file scope.
pub const FileSet = struct {
    scope: Scope,
    /// The session Workspace root that owns the files, or null.
    root: ?[]const u8,
    files: []const File,
    /// Targets of the loads that admit load-only bindings.
    loaded: std.StringHashMap(void),
    /// Role and file scopes: the base files plus one level of their loads,
    /// all reachable. Null for a Workspace, whose Reachable definitions
    /// depend on the referencing file.
    reach: ?view.Reachability = null,
    collections: ?[]const WorkspaceCollection = null,

    pub fn isLoaded(self: *const FileSet, path: []const u8) bool {
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
    /// Facts extracted in this request, by path.
    facts_memo: std.StringHashMap(Extracted),
    /// Built file sets, by scope.
    sets: std.StringHashMap(*FileSet),

    const Extracted = struct { root: ?[]const u8, facts: facts_mod.Facts };

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
            .facts_memo = std.StringHashMap(Extracted).init(a),
            .sets = std.StringHashMap(*FileSet).init(a),
        };
    }

    fn index(self: *const Context) *WorkspaceIndex {
        return self.lease.index orelse unreachable;
    }

    /// The filesystem path of `uri`. Every URI-to-path conversion in a
    /// navigation request goes through here, so path-form rules (for
    /// example symlinked roots) apply in one place.
    pub fn pathOf(self: *const Context, uri: []const u8) ![]const u8 {
        const path = try paths.uriToPath(self.allocator, uri);
        defer self.allocator.free(path);
        return workspace_session.resolvedPath(self.allocator, path);
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
        const owner = self.session.workspaces.owner(self.allocator, path);
        self.owners.put(dir, owner) catch {};
        return owner;
    }

    /// The Workspace that owns the file at `uri`, or null without a session
    /// Workspace.
    pub fn workspaceOf(self: *Context, uri: []const u8) !?*FileSet {
        const root = self.workspaceRoot(try self.pathOf(uri)) orelse return null;
        return try self.files(.{ .workspace = root });
    }

    /// The files a variable search from `uri` runs over: its session
    /// Workspace, else its Role scope, else its Playbook scope (ADR-0032).
    pub fn searchFiles(self: *Context, uri: []const u8) !*FileSet {
        const path = try self.pathOf(uri);
        if (self.workspaceRoot(path)) |root| return self.files(.{ .workspace = root });
        if (roles.resolve.enclosingRole(path)) |dir| return self.files(.{ .role = dir });
        return self.files(.{ .file = path });
    }

    /// The file set of `scope`, built once per request.
    pub fn files(self: *Context, scope: Scope) !*FileSet {
        const a = self.allocator;
        const key = switch (scope) {
            .workspace => |root| try std.fmt.allocPrint(a, "w:{s}", .{root}),
            .role => |dir| try std.fmt.allocPrint(a, "r:{s}", .{dir}),
            .file => |path| try std.fmt.allocPrint(a, "f:{s}", .{path}),
        };
        if (self.sets.get(key)) |found| return found;
        const found = try a.create(FileSet);
        found.* = switch (scope) {
            .workspace => |root| try self.workspaceSet(root),
            .role => |dir| try self.roleSet(dir),
            .file => |path| try self.fileSet(path),
        };
        try self.sets.put(key, found);
        return found;
    }

    /// Every file of the Workspace, with every load target promoted.
    fn workspaceSet(self: *Context, root: []const u8) !FileSet {
        const a = self.allocator;
        const all = try self.overlay(root, null);
        var loaded = std.StringHashMap(void).init(a);
        for (all) |f| {
            for (f.facts.var_loads) |load| try loaded.put(load.path, {});
        }
        for (all) |*f| {
            if (loaded.contains(f.path)) f.facts = try f.facts.loaded(a);
        }
        return .{ .scope = .{ .workspace = root }, .root = root, .files = all, .loaded = loaded };
    }

    /// A Role's conventional sources: the Workspace's, when it has indexed or
    /// opened any, else those on disk.
    fn roleSet(self: *Context, dir: []const u8) !FileSet {
        const a = self.allocator;
        const root = self.workspaceRoot(try std.fs.path.join(a, &.{ dir, "tasks", "main.yml" }));
        var base = std.array_list.Managed(File).init(a);
        if (root) |r| for (try self.overlay(r, dir)) |f| {
            if (view.isCalleeSource(f.path, dir)) try base.append(f);
        };
        if (base.items.len == 0) {
            for (try variables.scope.enumerateFiles(a, self.source(), dir)) |path| {
                if (try self.extracted(root, path, try paths.pathToUri(a, path))) |f| try base.append(f);
            }
            std.mem.sort(File, base.items, {}, lessPath);
        }
        return self.withLoads(.{ .role = dir }, root, &base);
    }

    /// One file, its open document winning.
    fn fileSet(self: *Context, path: []const u8) !FileSet {
        const a = self.allocator;
        const root = self.workspaceRoot(path);
        var base = std.array_list.Managed(File).init(a);
        if (try self.extracted(root, path, try paths.pathToUri(a, path))) |f| try base.append(f);
        return self.withLoads(.{ .file = path }, root, &base);
    }

    /// Add one level of the base files' vars-load targets. Provenance is
    /// frozen first: a target's own loads never extend the set.
    fn withLoads(self: *Context, scope: Scope, root: ?[]const u8, list: *std.array_list.Managed(File)) !FileSet {
        const a = self.allocator;
        var reach_paths = std.array_list.Managed([]const u8).init(a);
        var loads = std.array_list.Managed(variables.scope.VarFileLoad).init(a);
        for (list.items) |f| try appendUnique(&reach_paths, f.path);
        for (list.items) |f| for (f.facts.var_loads) |load| {
            try loads.append(load);
            try appendUnique(&reach_paths, load.path);
        };
        var loaded = std.StringHashMap(void).init(a);
        for (loads.items) |load| {
            if (loaded.contains(load.path)) continue;
            try loaded.put(load.path, {});
            try self.addLoadTarget(root, list, load.path);
        }
        return .{
            .scope = scope,
            .root = root,
            .files = try list.toOwnedSlice(),
            .loaded = loaded,
            .reach = .{ .paths = try reach_paths.toOwnedSlice(), .loads = try loads.toOwnedSlice() },
        };
    }

    /// A load target joins with its load-only bindings (ADR-0045): from the
    /// set, else its open document or indexed entry in the Workspace, else
    /// its text. Explicit loads are Ansible data whatever their extension.
    fn addLoadTarget(self: *Context, root: ?[]const u8, list: *std.array_list.Managed(File), path: []const u8) !void {
        const a = self.allocator;
        var existing: ?*File = null;
        for (list.items) |*f| if (std.mem.eql(u8, f.path, path)) {
            existing = f;
        };
        if (discover.isAnsibleFile(std.fs.path.basename(path))) {
            if (existing) |f| {
                f.facts = try f.facts.loaded(a);
                return;
            }
            if (root) |r| if (try self.workspaceFile(r, path)) |found| {
                var file = found;
                file.facts = try file.facts.loaded(a);
                try list.append(file);
                return;
            };
        }
        const uri = try paths.pathToUri(a, path);
        const body = (try self.text(uri)) orelse return;
        const dependency = try facts_mod.extractDependencyIn(a, root, path, body);
        // Normal non-Ansible source-candidate facts are deliberately empty.
        // Only an explicit load authorizes their hydration.
        if (existing) |f| f.facts = dependency else try list.append(.{ .path = path, .uri = uri, .facts = dependency });
    }

    /// One Workspace file: its open document, else its indexed entry, else
    /// null when neither belongs to `root`.
    fn workspaceFile(self: *Context, root: []const u8, path: []const u8) !?File {
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
        var out = std.array_list.Managed(File).init(a);
        var replaced = std.StringHashMap(void).init(a);
        for (entries) |entry| {
            if (open.get(entry.path)) |doc| {
                try out.append(try self.openFile(root, entry.path, doc));
                try replaced.put(entry.path, {});
            } else {
                try out.append(.{ .path = entry.path, .uri = try paths.pathToUri(a, entry.path), .facts = entry.facts });
            }
        }
        var rest = open.iterator();
        while (rest.next()) |item| {
            const path = item.key_ptr.*;
            if (replaced.contains(path)) continue;
            if (within) |dir| if (!isBelow(path, dir)) continue;
            try out.append(try self.openFile(root, path, item.value_ptr.*));
        }
        return out.toOwnedSlice();
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
            const member = self.session.workspaces.member(path) orelse continue;
            if (!std.mem.eql(u8, root, member)) continue;
            try found.put(path, doc.*);
        }
        try self.open.put(root, found);
        return found;
    }

    /// An open document's facts, extracted once per request.
    fn openFile(self: *Context, root: []const u8, path: []const u8, doc: *Document) !File {
        return (try self.extracted(root, path, doc.uri)) orelse unreachable;
    }

    /// The facts of the file at `path` under `root`, from `text(uri)` and
    /// extracted at most once per request. Null when the file has no text.
    fn extracted(self: *Context, root: ?[]const u8, path: []const u8, uri: []const u8) !?File {
        if (self.facts_memo.get(path)) |cached| {
            if (sameRoot(cached.root, root)) return .{ .path = path, .uri = uri, .facts = cached.facts };
        }
        const body = (try self.text(uri)) orelse return null;
        const found = try facts_mod.extractIn(self.allocator, root, path, body);
        try self.facts_memo.put(path, .{ .root = root, .facts = found });
        return .{ .path = path, .uri = uri, .facts = found };
    }

    /// Facts of the open document at `uri`, as the index would record them:
    /// load-only bindings stay separate. Shared with the Workspace overlay.
    pub fn documentFacts(self: *Context, uri: []const u8) !?facts_mod.Facts {
        const doc = self.document(uri) orelse return null;
        const path = try self.pathOf(uri);
        const root = self.workspaceRoot(path);
        if (discover.isAnsibleFile(std.fs.path.basename(path))) {
            return ((try self.extracted(root, path, uri)) orelse return null).facts;
        }
        return try facts_mod.extractDocumentIn(self.allocator, root, path, doc.bytes());
    }

    /// Paths whose definitions can apply in the file at `path` (Reachable
    /// definitions). A Role or file scope is reachable as a whole. In a
    /// Workspace: the file's role scope and that Role's invokers, resolved by
    /// directory with each invoking file's search paths, or the task file's
    /// includers; plus one level of their vars loads.
    pub fn reachableFiles(self: *Context, ws: *FileSet, path: []const u8) !view.Reachability {
        if (ws.reach) |reach| return reach;
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
    pub fn workspaceCollections(self: *Context, ws: *FileSet) ![]const WorkspaceCollection {
        if (ws.collections) |colls| return colls;
        const ws_root = ws.root orelse return &.{};
        if (ws.scope != .workspace) return &.{};
        const a = self.allocator;
        var out = std.array_list.Managed(WorkspaceCollection).init(a);
        for (ws.files) |f| {
            const base = std.fs.path.basename(f.path);
            if (!std.mem.eql(u8, base, "galaxy.yml") and !std.mem.eql(u8, base, "galaxy.yaml")) continue;
            const dir = std.fs.path.dirname(f.path) orelse continue;
            if (!isWorkspaceCollectionRoot(ws_root, dir)) continue;
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
            const ws = self.files(.{ .workspace = r }) catch break :blk &.{};
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
    fn rolesPaths(self: *Context, path: []const u8) ![]const []const u8 {
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
            .config = self.session.ansible_config,
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

fn lessPath(_: void, x: File, y: File) bool {
    return std.mem.order(u8, x.path, y.path) == .lt;
}

fn appendUnique(list: *std.array_list.Managed([]const u8), item: []const u8) !void {
    for (list.items) |x| if (std.mem.eql(u8, x, item)) return;
    try list.append(item);
}

fn sameRoot(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
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

test "symlinked opened folders overlay unsaved documents with resolved paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("workspace/.git");
    try tmp.dir.writeFile(.{ .sub_path = "workspace/site.yml", .data = "- hosts: all\n  vars: {disk_only: true}\n" });
    try tmp.dir.symLink("workspace", "linked", .{ .is_directory = true });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realpathAlloc(a, ".");
    const root = try tmp.dir.realpathAlloc(a, "workspace");
    const linked = try std.fs.path.join(a, &.{ base, "linked/site.yml" });
    const uri = try paths.pathToUri(a, linked);
    var session = try workspace_session.Session.init(testing.allocator, null);
    defer session.deinit();
    _ = try session.apply(a, .{ .initialize = .{ .folders = &.{try paths.pathToUri(a, try std.fs.path.join(a, &.{ base, "linked" }))}, .config = .{} } });
    var documents = DocumentStore.init(testing.allocator, .utf16);
    defer documents.deinit();
    _ = try documents.open(uri, "ansible", 1, "- hosts: all\n  vars: {unsaved: true}\n");
    const fresh = try paths.pathToUri(a, try std.fs.path.join(a, &.{ base, "linked/new/tasks.yml" }));
    _ = try documents.open(fresh, "ansible", 1, "- debug: {msg: '{{ unsaved }}'}\n");
    const idx = try WorkspaceIndex.create(testing.allocator);
    defer idx.destroy();
    try idx.scanNow(root, ".git");
    var lease = idx.acquireQuery(false);
    defer lease.release();
    var context = Context.init(a, &lease, .{
        .documents = &documents,
        .workspaces = session.snapshot(),
        .docs = undefined, // This test never requests module documentation.
    });
    const ws = (try context.workspaceOf(uri)).?;
    try testing.expectEqual(@as(usize, 2), ws.files.len);
    const path = try context.pathOf(uri);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "site.yml" }), path);
    var found = false;
    for (ws.files) |file| {
        if (!std.mem.eql(u8, file.path, path)) continue;
        found = true;
        try testing.expectEqualStrings(uri, file.uri);
        try testing.expectEqual(@as(usize, 1), file.facts.var_defs.len);
        try testing.expectEqualStrings("unsaved", file.facts.var_defs[0].name);
    }
    try testing.expect(found);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "new/tasks.yml" }), try context.pathOf(fresh));
}

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

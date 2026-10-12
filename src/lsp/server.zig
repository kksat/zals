//! The LSP server: message loop, lifecycle, and dispatch.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_util = @import("json_util.zig");
const out = @import("outgoing.zig");
const Transport = @import("transport.zig").Transport;
const DocumentStore = @import("../workspace/store.zig").DocumentStore;
const PositionEncoding = @import("../workspace/document.zig").PositionEncoding;
const Settings = @import("../workspace/settings.zig").Settings;
const roots = @import("../workspace/roots.zig");
const paths = @import("../paths.zig");
const project_config = @import("../services/project_config.zig");
const workspace_index = @import("../workspace/index.zig");
const WorkspaceIndex = workspace_index.WorkspaceIndex;
const handlers = @import("handlers.zig");
const exec = @import("../exec/root.zig");
const DocsLibrary = @import("../services/docs.zig").DocsLibrary;
const SchemaCatalog = @import("../services/schema_service.zig").Catalog;
const AnsibleConfig = @import("../services/ansible_config.zig").AnsibleConfig;
const concurrency = @import("../concurrency/root.zig");
const docs_service = @import("../services/docs_service.zig");
const DocsService = docs_service.DocsService;
const Writer = @import("writer.zig").Writer;

pub const Server = struct {
    allocator: Allocator,
    transport: Transport,
    writer: *Writer,
    documents: DocumentStore,
    settings: Settings,
    runner: exec.Runner,
    docs: DocsLibrary,
    schemas: SchemaCatalog,
    ansible_config: AnsibleConfig,
    pool: *concurrency.ThreadPool,
    docs_service: DocsService,
    contextual_docs: docs_service.ContextLibraries,
    encoding: PositionEncoding = .utf16,
    initialized: bool = false,
    shutdown_requested: bool = false,
    running: bool = true,
    /// True when the client advertises `workspace.workspaceEdit.resourceOperations`
    /// containing `create` (needed by the extract code actions).
    supports_create_file: bool = false,
    /// Folders the client opened, before Workspace resolution.
    opened_uris: std.array_list.Managed([]const u8),
    /// Resolved Workspace URIs, one per distinct `.git`.
    root_uris: std.array_list.Managed([]const u8),
    /// True when at least one opened folder has no Workspace.
    missing_workspace: bool = false,
    warned_missing_workspace: bool = false,
    /// `--venv <path>`; wins over `ansible.python.venvPath`. Borrowed from argv.
    venv_override: ?[]const u8 = null,
    /// Workspace index (ADR-0031).
    index: *WorkspaceIndex,
    /// The client supports dynamic registration of watched files.
    can_watch_files: bool = false,
    /// Watched-file events keep the index current; otherwise it re-stats.
    watching_files: bool = false,

    pub fn init(allocator: Allocator, transport: Transport) !Server {
        const runner = exec.Posix.posixRunner();
        // Leave room for file parsing alongside blocking docs bootstrap, but
        // bound the pool on both large and single-core machines.
        const workers = @min(4, @max(2, std.Thread.getCpuCount() catch 2));
        const pool = try concurrency.ThreadPool.init(allocator, workers);
        errdefer pool.deinit();
        const writer = try Writer.init(allocator, transport.out_file);
        errdefer writer.deinit();
        const index = try WorkspaceIndex.create(allocator);
        errdefer index.destroy();

        return Server{
            .allocator = allocator,
            .transport = transport,
            .writer = writer,
            .documents = DocumentStore.init(allocator, .utf16),
            .settings = Settings.init(allocator),
            .runner = runner,
            .docs = DocsLibrary.init(allocator, runner, "ansible-doc"),
            .schemas = SchemaCatalog.init(allocator),
            .ansible_config = AnsibleConfig.init(allocator, runner),
            .pool = pool,
            .docs_service = DocsService.init(allocator),
            .contextual_docs = docs_service.ContextLibraries.init(allocator, runner),
            .opened_uris = std.array_list.Managed([]const u8).init(allocator),
            .root_uris = std.array_list.Managed([]const u8).init(allocator),
            .index = index,
        };
    }

    pub fn deinit(self: *Server) void {
        // Ask background work to stop, then join workers so no task touches the
        // docs library afterwards.
        self.docs_service.shutdown.store(true, .release);
        self.index.shutdown.store(true, .release);
        self.pool.deinit();
        self.index.destroy();
        self.documents.deinit();
        self.settings.deinit();
        self.docs.deinit();
        self.contextual_docs.deinit();
        self.schemas.deinit();
        self.ansible_config.deinit();
        self.docs_service.deinit();
        for (self.opened_uris.items) |u| self.allocator.free(u);
        self.opened_uris.deinit();
        for (self.root_uris.items) |u| self.allocator.free(u);
        self.root_uris.deinit();
        // Flush any queued outgoing messages before tearing down the writer.
        self.writer.deinit();
    }

    pub fn run(self: *Server) !void {
        while (self.running) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            try self.drainBackground(a);
            // While bootstrap/scanning is active, wake periodically to apply
            // results and publish readiness even if the client sends nothing.
            // Once ready, return to a blocking read (no idle polling).
            if (self.index.isScanning() or self.docs_service.hasPendingBootstrap()) {
                if (!try self.transport.waitForInput(25)) continue;
            }
            const body = (try self.transport.readMessage(self.allocator)) orelse break;
            defer self.allocator.free(body);

            const msg = std.json.parseFromSliceLeaky(Value, a, body, .{}) catch continue;
            self.dispatch(a, msg) catch |err| {
                std.log.err("dispatch failed: {s}", .{@errorName(err)});
            };
        }
    }

    fn dispatch(self: *Server, a: Allocator, msg: Value) !void {
        const method = json_util.string(msg, "method") orelse return;
        const id = json_util.field(msg, "id");
        const params = json_util.field(msg, "params") orelse Value.null;

        try self.drainBackground(a);

        if (id) |req_id| {
            handlers.handleRequest(self, a, req_id, method, params) catch |err| {
                try self.sendError(a, req_id, -32603, @errorName(err));
            };
        } else {
            try handlers.handleNotification(self, a, method, params);
        }
    }

    fn drainBackground(self: *Server, a: Allocator) !void {
        self.index.drain();
        if (self.index.takeReadyEvent()) {
            var ready = json_util.obj(a);
            try ready.put("filesCount", json_util.num(@as(i64, @intCast(self.index.count()))));
            try self.notify(a, "ansible/workspaceIndexReady", .{ .object = ready });
        }
        if (self.docs_service.takeReadyEvent()) {
            var ready = json_util.obj(a);
            try ready.put("modulesCount", json_util.num(self.docs.catalogCount()));
            try self.notify(a, "ansible/docsLibraryReady", .{ .object = ready });
        }
    }

    pub fn sendResult(self: *Server, a: Allocator, id: Value, result: Value) !void {
        try out.sendResult(self.writer, a, id, result);
    }

    pub fn sendError(self: *Server, a: Allocator, id: Value, code: i64, message: []const u8) !void {
        try out.sendError(self.writer, a, id, code, message);
    }

    pub fn notify(self: *Server, a: Allocator, method: []const u8, params: Value) !void {
        try out.sendNotification(self.writer, a, method, params);
    }

    /// Replace the opened folders and recompute Workspace roots from `.git`.
    pub fn setOpenedFolders(self: *Server, uris: []const []const u8) !void {
        for (self.opened_uris.items) |u| self.allocator.free(u);
        self.opened_uris.clearRetainingCapacity();
        for (uris) |uri| try self.opened_uris.append(try self.allocator.dupe(u8, uri));
        try self.rebuildWorkspaces();
    }

    /// Apply a `workspace/didChangeWorkspaceFolders` event to the opened set.
    pub fn applyOpenedChange(self: *Server, removed: []const []const u8, added: []const []const u8) !void {
        for (removed) |uri| {
            var i: usize = 0;
            while (i < self.opened_uris.items.len) : (i += 1) {
                if (std.mem.eql(u8, self.opened_uris.items[i], uri)) {
                    self.allocator.free(self.opened_uris.items[i]);
                    _ = self.opened_uris.orderedRemove(i);
                    break;
                }
            }
        }
        for (added) |uri| {
            var exists = false;
            for (self.opened_uris.items) |existing| {
                if (std.mem.eql(u8, existing, uri)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) try self.opened_uris.append(try self.allocator.dupe(u8, uri));
        }
        try self.rebuildWorkspaces();
    }

    pub fn rebuildWorkspaces(self: *Server) !void {
        for (self.root_uris.items) |u| self.allocator.free(u);
        self.root_uris.clearRetainingCapacity();
        self.missing_workspace = false;
        for (self.opened_uris.items) |uri| {
            const path = try paths.uriToPath(self.allocator, uri);
            defer self.allocator.free(path);
            const found = try roots.find(self.allocator, path, self.settings.root_marker);
            if (found) |root| {
                defer self.allocator.free(root);
                const root_uri = try paths.pathToUri(self.allocator, root);
                errdefer self.allocator.free(root_uri);
                if (containsUri(self.root_uris.items, root_uri)) {
                    self.allocator.free(root_uri);
                } else {
                    try self.root_uris.append(root_uri);
                }
            } else {
                self.missing_workspace = true;
            }
        }
        try self.syncIndex(false);
    }

    /// Scan new Workspaces and drop removed ones. `rescan` re-scans every
    /// Workspace (the root marker changed). No-op before `initialized`.
    pub fn syncIndex(self: *Server, rescan: bool) !void {
        if (!self.initialized) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const session = try self.workspacePaths(arena.allocator());
        try self.index.syncRoots(self.pool, session, self.settings.root_marker, rescan);
    }

    /// Ask the client to watch navigation and collection source files
    /// (ADR-0031, ADR-0038), plus configuration and collection metadata.
    pub fn registerFileWatchers(self: *Server, a: Allocator) !void {
        if (!self.can_watch_files) return;
        var watchers = std.json.Array.init(a);
        for ([_][]const u8{ "**/*.{yml,yaml,j2}", "**/plugins/**/*.{py,ps1}", "**/ansible.cfg", "**/galaxy.{yml,yaml}" }) |glob| {
            var w = json_util.obj(a);
            try w.put("globPattern", json_util.str(glob));
            try watchers.append(.{ .object = w });
        }
        var opts = json_util.obj(a);
        try opts.put("watchers", .{ .array = watchers });
        var reg = json_util.obj(a);
        try reg.put("id", json_util.str("zals-watched-files"));
        try reg.put("method", json_util.str("workspace/didChangeWatchedFiles"));
        try reg.put("registerOptions", .{ .object = opts });
        var regs = std.json.Array.init(a);
        try regs.append(.{ .object = reg });
        var params = json_util.obj(a);
        try params.put("registrations", .{ .array = regs });
        try out.sendRequest(self.writer, a, "zals-register-watchers", "client/registerCapability", .{ .object = params });
        self.watching_files = true;
    }

    /// Re-index one file on disk if it belongs to a session Workspace.
    pub fn reindexPath(self: *Server, a: Allocator, path: []const u8) void {
        const root = self.workspaceRootFor(a, path) orelse {
            self.index.remove(path);
            return;
        };
        const discovery = @import("../workspace/discover.zig");
        if (!discovery.isWorkspaceFile(path) or !discovery.belongsToWorkspace(root, path, self.settings.root_marker)) return;
        self.index.reindex(root, path);
    }

    /// Entries from the request's leased revision, borrowed through release.
    /// Index-owned preparation lets nested Workspace views share one revision.
    pub fn indexEntries(self: *Server, a: Allocator, root: []const u8) ![]const *const workspace_index.Entry {
        return self.index.entriesOf(a, root);
    }

    /// Session Workspace roots as filesystem paths.
    pub fn workspacePaths(self: *Server, a: Allocator) ![]const []const u8 {
        var list = std.array_list.Managed([]const u8).init(a);
        for (self.root_uris.items) |u| try list.append(try paths.uriToPath(a, u));
        return list.toOwnedSlice();
    }

    /// The session Workspace root that owns `file_path`, or null.
    pub fn workspaceRootFor(self: *Server, a: Allocator, file_path: []const u8) ?[]const u8 {
        const session = self.workspacePaths(a) catch return null;
        const owned = roots.owning(a, file_path, session, self.settings.root_marker) catch return null;
        return if (owned) |o| o[0] else null;
    }

    /// The virtual environment whose collections are searched.
    pub fn venvPath(self: *Server) []const u8 {
        return self.venv_override orelse self.settings.venv_path;
    }

    /// Every `roles/` directory in the request's leased Workspace revision.
    pub fn workspaceRolesDirs(self: *Server, root: ?[]const u8) []const []const u8 {
        const r = root orelse return &.{};
        const info = self.index.info(r) orelse return &.{};
        return info.roles_dirs;
    }

    /// Directories in the request's leased Workspace revision that hold
    /// `ansible_collections/`. Discovery arenas live as long as entry arenas.
    pub fn workspaceCollectionPaths(self: *Server, root: ?[]const u8) []const []const u8 {
        const r = root orelse return &.{};
        const info = self.index.info(r) orelse return &.{};
        return info.collection_paths;
    }

    /// Module lookup shares navigation's effective per-file collection paths,
    /// without mutating the process environment or sharing FQCN-only caches.
    pub fn docsForUri(self: *Server, a: Allocator, uri: []const u8) !*DocsLibrary {
        const path = try paths.uriToPath(a, uri);
        const collection_paths = try project_config.collectionsPaths(a, self.projectContext(a, path), path);
        // Navigation interprets relative environment/dump entries against the
        // server cwd. Keep that meaning when the child runs beside the file.
        const server_cwd = try std.process.getCwdAlloc(a);
        const absolute_paths = try a.alloc([]const u8, collection_paths.len);
        for (collection_paths, 0..) |p, i| {
            absolute_paths[i] = if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(a, &.{ server_cwd, p });
        }
        return self.contextual_docs.forPaths(absolute_paths, std.fs.path.dirname(path) orelse ".");
    }

    /// Search-path inputs for `file_path` (ADR-0032).
    pub fn projectContext(self: *Server, a: Allocator, file_path: []const u8) project_config.Context {
        const root = self.workspaceRootFor(a, file_path);
        return .{
            .workspace_root = root,
            .venv = self.venvPath(),
            .config = &self.ansible_config,
            .workspace_collections = self.workspaceCollectionPaths(root),
        };
    }

    /// One session warning when an opened folder has no Workspace.
    pub fn warnMissingWorkspace(self: *Server, a: Allocator) !void {
        if (!roots.warnDue(
            self.settings.missing_git_warning,
            self.missing_workspace,
            self.warned_missing_workspace,
            self.initialized,
        )) return;
        const message = try roots.missingMessage(a, self.settings.root_marker);
        try out.showMessage(self.writer, a, 2, message);
        try out.logMessage(self.writer, a, 2, message);
        self.warned_missing_workspace = true;
    }
};

fn containsUri(uris: []const []const u8, uri: []const u8) bool {
    for (uris) |existing| {
        if (std.mem.eql(u8, existing, uri)) return true;
    }
    return false;
}

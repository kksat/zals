const std = @import("std");
const fsio = @import("../fsio.zig");
const Allocator = std.mem.Allocator;
const cel_env = @import("../cel/env.zig");
const paths = @import("../paths.zig");
const role_resolve = @import("../roles/resolve.zig");
const yaml_recover = @import("yaml_recover.zig");
const value_mod = @import("value.zig");
const ansible = @import("ansible.zig");

const TypedValue = value_mod.TypedValue;

const max_context_read_bytes: usize = 2 * 1024 * 1024;
const max_dir_walk_depth: usize = 16;
const max_dir_walk_files: usize = 256;

pub const SourceOverlay = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const RoleSpecOptionContext = struct {
    name: []const u8,
    has_default: bool = false,
    default_val: ?TypedValue = null,
    has_required: bool = false,
    required: bool = false,
};

pub const RoleSpecEntryContext = struct {
    entry_point: []const u8,
    options: []const RoleSpecOptionContext = &.{},
};

pub const RoleDefaultsVar = struct {
    name: []const u8,
    value: TypedValue,
};

pub const RoleDefaultsEntryContext = struct {
    entry_point: []const u8,
    has_files: bool = false,
    vars: []const RoleDefaultsVar = &.{},
};

pub const RoleContext = struct {
    present: bool = false,
    name: []const u8 = "",
    path: []const u8 = "",
    entry_point: []const u8 = "",
    has_argument_specs_file: bool = false,
    has_argument_specs: bool = false,
    has_meta: bool = false,
    has_defaults: bool = false,
    has_tasks: bool = false,
    has_handlers: bool = false,
    argument_specs: []const RoleSpecEntryContext = &.{},
    defaults: []const RoleDefaultsEntryContext = &.{},

    pub fn toCel(self: RoleContext, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putBool(alloc, "present", self.present);
        try b.putString(alloc, "name", self.name);
        try b.putString(alloc, "path", self.path);
        try b.putString(alloc, "entry_point", self.entry_point);
        try b.putBool(alloc, "has_argument_specs_file", self.has_argument_specs_file);
        try b.putBool(alloc, "has_argument_specs", self.has_argument_specs);
        try b.putBool(alloc, "has_meta", self.has_meta);
        try b.putBool(alloc, "has_defaults", self.has_defaults);
        try b.putBool(alloc, "has_tasks", self.has_tasks);
        try b.putBool(alloc, "has_handlers", self.has_handlers);

        var specs_map = cel_env.MapBuilder.init();
        errdefer specs_map.deinit(alloc);
        for (self.argument_specs) |entry| {
            var eb = cel_env.MapBuilder.init();
            errdefer eb.deinit(alloc);
            var opts_map = cel_env.MapBuilder.init();
            errdefer opts_map.deinit(alloc);
            for (entry.options) |opt| {
                var ob = cel_env.MapBuilder.init();
                errdefer ob.deinit(alloc);
                try ob.putBool(alloc, "has_default", opt.has_default);
                if (opt.default_val) |dv| {
                    try ob.put(alloc, "default", try dv.toCelTyped(alloc));
                } else {
                    try ob.putNull(alloc, "default");
                }
                try ob.putBool(alloc, "has_required", opt.has_required);
                try ob.putBool(alloc, "required", opt.required);
                try opts_map.put(alloc, opt.name, try finishMapSafe(&ob, alloc));
            }
            try eb.put(alloc, "options", try finishMapSafe(&opts_map, alloc));
            try specs_map.put(alloc, entry.entry_point, try finishMapSafe(&eb, alloc));
        }
        try b.put(alloc, "argument_specs", try finishMapSafe(&specs_map, alloc));

        var defs_map = cel_env.MapBuilder.init();
        errdefer defs_map.deinit(alloc);
        for (self.defaults) |entry| {
            var db = cel_env.MapBuilder.init();
            errdefer db.deinit(alloc);
            try db.putBool(alloc, "has_files", entry.has_files);
            var vars_map = cel_env.MapBuilder.init();
            errdefer vars_map.deinit(alloc);
            for (entry.vars) |v| {
                try vars_map.put(alloc, v.name, try v.value.toCelTyped(alloc));
            }
            try db.put(alloc, "vars", try finishMapSafe(&vars_map, alloc));
            try defs_map.put(alloc, entry.entry_point, try finishMapSafe(&db, alloc));
        }
        try b.put(alloc, "defaults", try finishMapSafe(&defs_map, alloc));

        return finishMapSafe(&b, alloc);
    }
};

pub const CollectionContext = struct {
    present: bool = false,
    namespace: []const u8 = "",
    name: []const u8 = "",
    fqcn: []const u8 = "",
    path: []const u8 = "",
    has_meta_runtime: bool = false,
    has_changelog: bool = false,

    pub fn toCel(self: CollectionContext, alloc: Allocator) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.putBool(alloc, "present", self.present);
        try b.putString(alloc, "namespace", self.namespace);
        try b.putString(alloc, "name", self.name);
        try b.putString(alloc, "fqcn", self.fqcn);
        try b.putString(alloc, "path", self.path);
        try b.putBool(alloc, "has_meta_runtime", self.has_meta_runtime);
        try b.putBool(alloc, "has_changelog", self.has_changelog);
        return finishMapSafe(&b, alloc);
    }
};

pub const DocumentContext = struct {
    role: RoleContext = .{},
    collection: CollectionContext = .{},

    pub fn makeTargetContextCel(
        alloc: Allocator,
        role_cel: cel_env.Value,
        collection_cel: cel_env.Value,
        enclosing_play: ?*const ansible.Play,
        block_ctx: ansible.BlockContextData,
    ) !cel_env.Value {
        var b = cel_env.MapBuilder.init();
        errdefer b.deinit(alloc);
        try b.put(alloc, "role", role_cel);
        try b.put(alloc, "collection", collection_cel);
        try b.put(alloc, "play", try ansible.Play.toPlayContextCel(enclosing_play, alloc));
        try b.put(alloc, "block", try block_ctx.toCel(alloc));
        return finishMapSafe(&b, alloc);
    }
};

fn finishMapSafe(b: *cel_env.MapBuilder, alloc: Allocator) Allocator.Error!cel_env.Value {
    return b.finish(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RepeatedKey => cel_env.emptyMapValue(),
    };
}

pub fn build(
    alloc: Allocator,
    doc_path: []const u8,
    workspace_root: ?[]const u8,
    overlays: []const SourceOverlay,
) !DocumentContext {
    const role_ctx = try buildRoleContext(alloc, doc_path, workspace_root, overlays);
    const coll_ctx = try buildCollectionContext(alloc, doc_path, workspace_root, overlays);
    return .{
        .role = role_ctx,
        .collection = coll_ctx,
    };
}

pub fn findEnclosingRole(doc_path: []const u8, overlays: []const SourceOverlay) ?[]const u8 {
    if (role_resolve.enclosingRole(doc_path)) |r| return r;
    var dir = std.fs.path.dirname(doc_path) orelse return null;
    while (true) {
        const base = std.fs.path.basename(dir);
        for (role_resolve.role_subdirs) |sub| {
            if (!std.mem.eql(u8, base, sub)) continue;
            const role_dir = std.fs.path.dirname(dir) orelse return null;
            if (hasRoleMetaInOverlays(role_dir, overlays)) return role_dir;
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == 0 or std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
}

pub fn findEnclosingCollection(
    alloc: Allocator,
    doc_path: []const u8,
    workspace_root: ?[]const u8,
    overlays: []const SourceOverlay,
) !?[]const u8 {
    var dir = std.fs.path.dirname(doc_path) orelse return null;
    var depth: usize = 0;
    while (depth < 32) : (depth += 1) {
        if (try hasGalaxyMeta(alloc, dir, overlays)) return dir;
        if (workspace_root) |ws| {
            if (std.mem.eql(u8, dir, ws)) return null;
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == 0 or std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
    return null;
}

fn hasRoleMetaInOverlays(role_dir: []const u8, overlays: []const SourceOverlay) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "main.yml", "main.yaml", "argument_specs.yml", "argument_specs.yaml" }) |name| {
        const meta = std.fmt.bufPrint(&buf, "{s}/meta/{s}", .{ role_dir, name }) catch continue;
        if (findOverlay(meta, overlays) != null) return true;
    }
    return false;
}

fn hasGalaxyMeta(alloc: Allocator, dir: []const u8, overlays: []const SourceOverlay) !bool {
    for ([_][]const u8{ "galaxy.yml", "galaxy.yaml" }) |name| {
        const p = try std.fs.path.join(alloc, &.{ dir, name });
        if (fileExistsOrOverlay(p, overlays)) return true;
    }
    return false;
}

fn buildRoleContext(
    alloc: Allocator,
    doc_path: []const u8,
    workspace_root: ?[]const u8,
    overlays: []const SourceOverlay,
) !RoleContext {
    const role_dir = findEnclosingRole(doc_path, overlays) orelse return .{};

    var ctx = RoleContext{
        .present = true,
        .name = try alloc.dupe(u8, std.fs.path.basename(role_dir)),
        .path = try relativeDisplayPath(alloc, role_dir, workspace_root),
        .entry_point = try extractRoleEntryPoint(alloc, doc_path, role_dir),
    };

    for ([_][]const u8{ "main.yml", "main.yaml" }) |name| {
        const p = try std.fs.path.join(alloc, &.{ role_dir, "meta", name });
        if (fileExistsOrOverlay(p, overlays)) {
            ctx.has_meta = true;
            break;
        }
    }

    var spec_bytes: ?[]const u8 = null;
    for ([_][]const u8{ "argument_specs.yml", "argument_specs.yaml" }) |name| {
        const p = try std.fs.path.join(alloc, &.{ role_dir, "meta", name });
        if (fileExistsOrOverlay(p, overlays)) {
            ctx.has_argument_specs_file = true;
            spec_bytes = readFileOrOverlay(alloc, p, overlays);
            break;
        }
    }

    if (spec_bytes) |bytes| {
        ctx.argument_specs = try parseArgumentSpecsContext(alloc, bytes);
        ctx.has_argument_specs = ctx.argument_specs.len > 0;
    }

    const defaults_dir = try std.fs.path.join(alloc, &.{ role_dir, "defaults" });
    const defaults_files = try collectYamlFilesUnder(alloc, defaults_dir, overlays);
    ctx.has_defaults = defaults_files.len > 0;
    if (defaults_files.len > 0) {
        ctx.defaults = try loadRoleDefaults(alloc, defaults_dir, defaults_files, overlays);
    }

    const tasks_dir = try std.fs.path.join(alloc, &.{ role_dir, "tasks" });
    ctx.has_tasks = try hasAnyYamlUnder(alloc, tasks_dir, overlays);

    const handlers_dir = try std.fs.path.join(alloc, &.{ role_dir, "handlers" });
    ctx.has_handlers = try hasAnyYamlUnder(alloc, handlers_dir, overlays);

    return ctx;
}

fn buildCollectionContext(
    alloc: Allocator,
    doc_path: []const u8,
    workspace_root: ?[]const u8,
    overlays: []const SourceOverlay,
) !CollectionContext {
    const coll_dir = (try findEnclosingCollection(alloc, doc_path, workspace_root, overlays)) orelse return .{};

    var ctx = CollectionContext{
        .present = true,
        .path = try relativeDisplayPath(alloc, coll_dir, workspace_root),
    };

    for ([_][]const u8{ "galaxy.yml", "galaxy.yaml" }) |name| {
        const p = try std.fs.path.join(alloc, &.{ coll_dir, name });
        if (readFileOrOverlay(alloc, p, overlays)) |bytes| {
            const recovered = yaml_recover.parse(alloc, bytes) catch break;
            for (recovered.documents) |doc| {
                const root = doc.root orelse continue;
                if (root.kind != .map) continue;
                if (root.findPair("namespace")) |np| {
                    const tv = try value_mod.fromYaml(alloc, np.val);
                    if (tv.kind == .string_val and tv.str_v.len > 0) ctx.namespace = tv.str_v;
                }
                if (root.findPair("name")) |np| {
                    const tv = try value_mod.fromYaml(alloc, np.val);
                    if (tv.kind == .string_val and tv.str_v.len > 0) ctx.name = tv.str_v;
                }
                break;
            }
            break;
        }
    }

    if (ctx.namespace.len > 0 and ctx.name.len > 0) {
        ctx.fqcn = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ ctx.namespace, ctx.name });
    }

    for ([_][]const u8{ "runtime.yml", "runtime.yaml" }) |name| {
        const p = try std.fs.path.join(alloc, &.{ coll_dir, "meta", name });
        if (fileExistsOrOverlay(p, overlays)) {
            ctx.has_meta_runtime = true;
            break;
        }
    }

    const changelog_rel = [_][]const []const u8{
        &.{"CHANGELOG.rst"},
        &.{"CHANGELOG.md"},
        &.{ "changelogs", "changelog.yaml" },
        &.{ "changelogs", "changelog.yml" },
    };
    for (changelog_rel) |parts| {
        var full_parts = std.ArrayList([]const u8).empty;
        try full_parts.append(alloc, coll_dir);
        try full_parts.appendSlice(alloc, parts);
        const p = try std.fs.path.join(alloc, full_parts.items);
        if (fileExistsOrOverlay(p, overlays)) {
            ctx.has_changelog = true;
            break;
        }
    }

    return ctx;
}

fn parseArgumentSpecsContext(alloc: Allocator, bytes: []const u8) ![]const RoleSpecEntryContext {
    const recovered = yaml_recover.parse(alloc, bytes) catch return &.{};
    var entries = std.ArrayList(RoleSpecEntryContext).empty;
    var entry_idx = std.StringHashMapUnmanaged(usize).empty;

    for (recovered.documents) |doc| {
        const root = doc.root orelse continue;
        if (root.kind != .map) continue;
        const specs_pair = root.findPair("argument_specs") orelse continue;
        const specs = specs_pair.val orelse continue;
        if (specs.kind != .map) continue;

        for (specs.items) |pair| {
            const k = pair.key orelse continue;
            const ep_name = k.value orelse k.raw;
            if (ep_name.len == 0) continue;

            var opts = std.ArrayList(RoleSpecOptionContext).empty;
            var opt_idx = std.StringHashMapUnmanaged(usize).empty;

            if (pair.val) |ev| {
                if (ev.kind == .map) {
                    if (ev.findPair("options")) |op| {
                        if (op.val) |ov| {
                            if (ov.kind == .map) {
                                for (ov.items) |opt_pair| {
                                    const ok = opt_pair.key orelse continue;
                                    const opt_name = ok.value orelse ok.raw;
                                    if (opt_name.len == 0) continue;

                                    var opt_ctx = RoleSpecOptionContext{ .name = opt_name };
                                    if (opt_pair.val) |opt_val| {
                                        if (opt_val.kind == .map) {
                                            if (opt_val.findPair("default")) |dp| {
                                                opt_ctx.has_default = true;
                                                opt_ctx.default_val = try value_mod.fromYaml(alloc, dp.val);
                                            }
                                            if (opt_val.findPair("required")) |rp| {
                                                opt_ctx.has_required = true;
                                                const rtv = try value_mod.fromYaml(alloc, rp.val);
                                                opt_ctx.required = (rtv.kind == .bool_val and rtv.bool_v);
                                            }
                                        }
                                    }

                                    if (opt_idx.get(opt_name)) |existing| {
                                        opts.items[existing] = opt_ctx;
                                    } else {
                                        try opt_idx.put(alloc, opt_name, opts.items.len);
                                        try opts.append(alloc, opt_ctx);
                                    }
                                }
                            }
                        }
                    }
                }
            }

            const entry_ctx = RoleSpecEntryContext{
                .entry_point = ep_name,
                .options = try opts.toOwnedSlice(alloc),
            };
            if (entry_idx.get(ep_name)) |existing| {
                entries.items[existing] = entry_ctx;
            } else {
                try entry_idx.put(alloc, ep_name, entries.items.len);
                try entries.append(alloc, entry_ctx);
            }
        }
        break;
    }

    return entries.toOwnedSlice(alloc);
}

const DefaultsFileItem = struct {
    path: []const u8,
    rel: []const u8,
    entry_point: []const u8,
    rank: u8,
};

fn loadRoleDefaults(
    alloc: Allocator,
    defaults_dir: []const u8,
    files: []const []const u8,
    overlays: []const SourceOverlay,
) ![]const RoleDefaultsEntryContext {
    var items = std.ArrayList(DefaultsFileItem).empty;
    for (files) |p| {
        if (!isUnderDir(p, defaults_dir)) continue;
        const rel = p[defaults_dir.len + 1 ..];
        const parsed = parseEntryPointFromRel(rel) orelse continue;
        try items.append(alloc, .{
            .path = p,
            .rel = rel,
            .entry_point = try alloc.dupe(u8, parsed.entry_point),
            .rank = parsed.rank,
        });
    }

    std.mem.sort(DefaultsFileItem, items.items, {}, struct {
        fn lessThan(_: void, a: DefaultsFileItem, b: DefaultsFileItem) bool {
            const ep_ord = std.mem.order(u8, a.entry_point, b.entry_point);
            if (ep_ord != .eq) return ep_ord == .lt;
            if (a.rank != b.rank) return a.rank < b.rank;
            return std.mem.lessThan(u8, a.rel, b.rel);
        }
    }.lessThan);

    var out = std.ArrayList(RoleDefaultsEntryContext).empty;
    var i: usize = 0;
    while (i < items.items.len) {
        const ep = items.items[i].entry_point;
        var vars = std.ArrayList(RoleDefaultsVar).empty;
        var var_idx = std.StringHashMapUnmanaged(usize).empty;

        while (i < items.items.len and std.mem.eql(u8, items.items[i].entry_point, ep)) : (i += 1) {
            const bytes = readFileOrOverlay(alloc, items.items[i].path, overlays) orelse continue;
            const recovered = yaml_recover.parse(alloc, bytes) catch continue;
            for (recovered.documents) |doc| {
                const root = doc.root orelse continue;
                if (root.kind != .map) continue;
                for (root.items) |pair| {
                    const k = pair.key orelse continue;
                    const vname = k.value orelse k.raw;
                    if (vname.len == 0) continue;
                    const tv = try value_mod.fromYaml(alloc, pair.val);
                    if (var_idx.get(vname)) |existing| {
                        vars.items[existing].value = tv;
                    } else {
                        try var_idx.put(alloc, vname, vars.items.len);
                        try vars.append(alloc, .{ .name = vname, .value = tv });
                    }
                }
            }
        }

        try out.append(alloc, .{
            .entry_point = ep,
            .has_files = true,
            .vars = try vars.toOwnedSlice(alloc),
        });
    }

    return out.toOwnedSlice(alloc);
}

fn parseEntryPointFromRel(rel: []const u8) ?struct { entry_point: []const u8, rank: u8 } {
    if (rel.len == 0) return null;
    if (std.mem.indexOfAny(u8, rel, "/\\")) |sep| {
        const ep = rel[0..sep];
        if (ep.len == 0) return null;
        return .{ .entry_point = ep, .rank = 2 };
    }
    if (std.mem.endsWith(u8, rel, ".yml")) {
        const stem = rel[0 .. rel.len - 4];
        if (stem.len == 0) return null;
        return .{ .entry_point = stem, .rank = 0 };
    }
    if (std.mem.endsWith(u8, rel, ".yaml")) {
        const stem = rel[0 .. rel.len - 5];
        if (stem.len == 0) return null;
        return .{ .entry_point = stem, .rank = 1 };
    }
    return null;
}

fn extractRoleEntryPoint(alloc: Allocator, doc_path: []const u8, role_dir: []const u8) ![]const u8 {
    if (!isUnderDir(doc_path, role_dir)) return "";
    const rel = doc_path[role_dir.len + 1 ..];
    const sep = std.mem.indexOfAny(u8, rel, "/\\") orelse return "";
    const subdir = rel[0..sep];
    const is_entry_dir = std.mem.eql(u8, subdir, "defaults") or
        std.mem.eql(u8, subdir, "tasks") or
        std.mem.eql(u8, subdir, "vars") or
        std.mem.eql(u8, subdir, "handlers");
    if (!is_entry_dir) return "";
    const sub_rel = rel[sep + 1 ..];
    const parsed = parseEntryPointFromRel(sub_rel) orelse return "";
    return alloc.dupe(u8, parsed.entry_point);
}

pub fn collectYamlFilesUnder(
    alloc: Allocator,
    dir_path: []const u8,
    overlays: []const SourceOverlay,
) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMapUnmanaged(void).empty;

    try walkYamlDir(alloc, dir_path, 0, &out, &seen);

    for (overlays) |ov| {
        if (!isUnderDir(ov.path, dir_path)) continue;
        if (!hasYamlExt(std.fs.path.basename(ov.path))) continue;
        if (seen.contains(ov.path)) continue;
        try seen.put(alloc, ov.path, {});
        try out.append(alloc, ov.path);
    }

    return out.toOwnedSlice(alloc);
}

fn hasAnyYamlUnder(alloc: Allocator, dir_path: []const u8, overlays: []const SourceOverlay) !bool {
    for (overlays) |ov| {
        if (isUnderDir(ov.path, dir_path) and hasYamlExt(std.fs.path.basename(ov.path))) return true;
    }
    const files = try collectYamlFilesUnder(alloc, dir_path, &.{});
    return files.len > 0;
}

fn walkYamlDir(
    alloc: Allocator,
    dir_path: []const u8,
    depth: usize,
    out: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    if (depth >= max_dir_walk_depth or out.items.len >= max_dir_walk_files) return;
    var dir = fsio.openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close(fsio.get());

    var it = dir.iterate();
    while (it.next(fsio.get()) catch null) |entry| {
        if (out.items.len >= max_dir_walk_files) break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const full = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => try walkYamlDir(alloc, full, depth + 1, out, seen),
            .file, .sym_link => {
                if (!hasYamlExt(entry.name)) continue;
                if (seen.contains(full)) continue;
                try seen.put(alloc, full, {});
                try out.append(alloc, full);
            },
            else => {},
        }
    }
}

fn hasYamlExt(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".yml") or std.mem.endsWith(u8, name, ".yaml");
}

fn isUnderDir(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and std.fs.path.isSep(path[dir.len]);
}

fn relativeDisplayPath(alloc: Allocator, target: []const u8, workspace_root: ?[]const u8) ![]const u8 {
    if (workspace_root) |ws| {
        if (std.mem.eql(u8, target, ws)) return ".";
        if (isUnderDir(target, ws)) return alloc.dupe(u8, target[ws.len + 1 ..]);
    }
    return alloc.dupe(u8, target);
}

fn findOverlay(path: []const u8, overlays: []const SourceOverlay) ?[]const u8 {
    for (overlays) |ov| {
        if (std.mem.eql(u8, ov.path, path)) return ov.bytes;
    }
    return null;
}

fn fileExistsOrOverlay(path: []const u8, overlays: []const SourceOverlay) bool {
    if (findOverlay(path, overlays) != null) return true;
    return paths.isFile(path);
}

fn readFileOrOverlay(alloc: Allocator, path: []const u8, overlays: []const SourceOverlay) ?[]const u8 {
    if (findOverlay(path, overlays)) |bytes| return bytes;
    return paths.readFile(alloc, path, max_context_read_bytes);
}

test "build role context merges directory-style defaults in Ansible lexicographical order and respects overlays" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "ws/roles/demo/meta");
    try tmp.dir.createDirPath(std.testing.io, "ws/roles/demo/defaults/main");
    try tmp.dir.createDirPath(std.testing.io, "ws/roles/demo/tasks");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ws/galaxy.yml",
        .data = "namespace: acme\nname: web\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ws/CHANGELOG.rst",
        .data = "changelog\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ws/roles/demo/meta/argument_specs.yml",
        .data =
        \\argument_specs:
        \\  main:
        \\    options:
        \\      app_port:
        \\        type: int
        \\        default: 8080
        \\      app_secret:
        \\        type: str
        \\        required: true
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ws/roles/demo/defaults/main/01_base.yml",
        .data = "app_port: 80\nbase_only: one\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ws/roles/demo/defaults/main/02_override.yml",
        .data = "app_port: 8080\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ws/roles/demo/tasks/main.yml",
        .data = "- name: ok\n  ansible.builtin.ping:\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws_root = try tmp.dir.realPathFileAlloc(std.testing.io, "ws", a);
    const def_path = try std.fs.path.join(a, &.{ ws_root, "roles/demo/defaults/main/01_base.yml" });
    const override_path = try std.fs.path.join(a, &.{ ws_root, "roles/demo/defaults/main/02_override.yml" });

    const ctx = try build(a, def_path, ws_root, &.{});
    try std.testing.expect(ctx.role.present);
    try std.testing.expectEqualStrings("demo", ctx.role.name);
    try std.testing.expectEqualStrings("roles/demo", ctx.role.path);
    try std.testing.expectEqualStrings("main", ctx.role.entry_point);
    try std.testing.expect(ctx.role.has_argument_specs_file);
    try std.testing.expect(ctx.role.has_argument_specs);
    try std.testing.expect(!ctx.role.has_meta);
    try std.testing.expect(ctx.role.has_defaults);
    try std.testing.expect(ctx.role.has_tasks);
    try std.testing.expect(!ctx.role.has_handlers);

    try std.testing.expectEqual(@as(usize, 1), ctx.role.defaults.len);
    try std.testing.expectEqualStrings("main", ctx.role.defaults[0].entry_point);
    try std.testing.expectEqual(@as(usize, 2), ctx.role.defaults[0].vars.len);
    try std.testing.expectEqual(@as(i64, 8080), ctx.role.defaults[0].vars[0].value.int_v);

    try std.testing.expect(ctx.collection.present);
    try std.testing.expectEqualStrings("acme", ctx.collection.namespace);
    try std.testing.expectEqualStrings("web", ctx.collection.name);
    try std.testing.expectEqualStrings("acme.web", ctx.collection.fqcn);
    try std.testing.expect(ctx.collection.has_changelog);
    try std.testing.expect(!ctx.collection.has_meta_runtime);

    const ov_ctx = try build(a, def_path, ws_root, &.{
        .{ .path = override_path, .bytes = "app_port: 9090\n" },
    });
    try std.testing.expectEqual(@as(i64, 9090), ov_ctx.role.defaults[0].vars[0].value.int_v);
}

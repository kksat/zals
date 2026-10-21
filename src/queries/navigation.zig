//! The semantic navigation interface. Protocol callers supply a typed subject
//! and encode the answer; applicability, precedence and docs fallback live here.
//! Internal typed domain operations never call JSON-taking providers.
const types = @import("../lsp/types.zig");
const variable_query = @import("variable_navigation.zig");
const files = @import("file_navigation.zig");
const collections = @import("collection_navigation.zig");
const roles = @import("role_navigation.zig");
const yaml = @import("../yaml/root.zig");
const cursor = @import("../cursor.zig");
const hover_format = @import("cursor_hover.zig");
const context_mod = @import("context.zig");
const Context = context_mod.Context;
pub const Position = @import("navigation_subject.zig").Position;
pub const Subject = @import("navigation_subject.zig").Subject;

/// Shape is part of the semantic answer: variable targets stay arrays even
/// when singleton; role singleton and file/collection/module targets are scalar.
pub const Definition = union(enum) {
    none,
    location: types.Location,
    locations: []const types.Location,
};

/// One request's navigation owner over the request's navigation context.
/// Call deinit on each subject and then this query. Results live in the request
/// allocator; no source-cache bytes or forest storage escape into hover text.
pub const Query = struct {
    context: *Context,
    bindings: variable_query.Query,

    pub fn init(context: *Context) Query {
        return .{ .context = context, .bindings = variable_query.Query.init(context) };
    }

    pub fn deinit(self: *Query) void {
        self.bindings.deinit();
    }

    pub fn subjectAt(self: *Query, position: Position) ?Subject {
        return Subject.at(self.context, position);
    }

    /// Definition: fields/parameters/roots, file, collection, role, module.
    /// Recognized empty bindings stop. Missing files/roles stop; unresolved
    /// collections intentionally continue so an FQCN's role/module can resolve.
    pub fn definition(self: *Query, subject: *Subject) !Definition {
        const context = self.context;
        const a = context.allocator;
        if (try self.bindings.locations(subject, .definition)) |locs| return .{ .locations = locs };
        switch (try files.definition(context, subject)) {
            .skip => {},
            .none => return .none,
            .location => |loc| return .{ .location = loc },
        }
        switch (try collections.definition(context, subject)) {
            .skip, .none => {},
            .location => |loc| return .{ .location = loc },
        }
        switch (try roles.definition(context, subject)) {
            .skip => {},
            .none => return .none,
            .locations => |locs| return if (locs.len == 1) .{ .location = locs[0] } else .{ .locations = locs },
        }
        const forest = subject.parse(a) orelse return .none;
        if (subject.path.len == 0) return .none;
        const name = subject.path[subject.path.len - 1].stringValue() orelse return .none;
        const declared = yaml.collections.getDeclaredCollections(forest.allocator(), subject.path) catch &.{};
        const lib = try context.docsFor(subject.doc.uri);
        const mod = lib.findModuleInContext(forest.allocator(), name, declared) orelse return .none;
        if (mod.filename.len == 0) return .none;
        return .{ .location = try context_mod.fileLocation(a, mod.filename) };
    }

    /// Implementation has no collection/file/module fallback. Passed keys
    /// retain applicable-empty callee answers, never caller-wide name fallback.
    pub fn implementation(self: *Query, subject: *Subject) !?[]const types.Location {
        if (try self.bindings.locations(subject, .implementation)) |locs| return locs;
        return roles.implementation(self.context, subject);
    }

    /// References prioritize collection, role, file, field, root. Contracts
    /// affect target selection but never narrow root/leaf-name reference groups.
    pub fn references(self: *Query, subject: *Subject, include_declaration: bool) !?[]const types.Location {
        if (try collections.references(self.context, subject)) |locs| return locs;
        if (try roles.references(self.context, subject)) |locs| return locs;
        if (try files.references(self.context, subject)) |locs| return locs;
        return self.bindings.references(subject, include_declaration);
    }

    /// Navigation-only hover terminates before contextual module catalog
    /// loading (which may shell out when cold). subjectAt/classification never
    /// need docs. Keyword/module formatting is the last, lazy fallback.
    pub fn hover(self: *Query, subject: *Subject) !?types.Hover {
        const context = self.context;
        const a = context.allocator;
        if (try self.bindings.fieldHover(subject)) |result| return result;
        if (try collections.hover(context, subject)) |result| return result;
        if (try roles.hover(context, subject)) |result| return result;
        if (try self.bindings.parameterHover(subject, false)) |result| return result;
        if (try self.bindings.rootHover(subject)) |result| return result;
        const forest = subject.parse(a) orelse return null;
        const lib = try context.docsFor(subject.doc.uri);
        const current = try cursor.classify(forest, subject.doc.uri, subject.path, subject.offset, cursor.fromLibrary(lib));
        return hover_format.format(a, subject.doc, current);
    }
};

// In-process tests at the navigation interface: a real temporary Workspace,
// a scanned index and open documents, with no Server.
const std = @import("std");
const testing = std.testing;
const Fixture = @import("testing.zig").Fixture;

fn expectAt(location: types.Location, uri: []const u8, line: u32, character: u32) !void {
    try testing.expectEqualStrings(uri, location.uri);
    try testing.expectEqual(line, location.range.start.line);
    try testing.expectEqual(character, location.range.start.character);
}

const precedence_role_task = "- debug:\n    msg: \"{{ port }}\"\n";
const precedence_playbook =
    \\- hosts: db
    \\  vars_files:
    \\    - vars/prod.yml
    \\  roles:
    \\    - db
    \\
;

fn writePrecedenceWorkspace(fixture: *Fixture) !void {
    try fixture.write("roles/db/defaults/main.yml", "port: 5432\n");
    try fixture.write("roles/db/tasks/main.yml", precedence_role_task);
    try fixture.write("roles/web/defaults/main.yml", "port: 80\n");
    try fixture.write("playbooks/site.yml", precedence_playbook);
    try fixture.write("playbooks/vars/prod.yml", "port: 8080\n");
}

test "variable definition ranks reachable bindings, then the rest of the Workspace" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    try writePrecedenceWorkspace(&fixture);
    const task = try fixture.open("roles/db/tasks/main.yml", precedence_role_task);
    var context = try fixture.context();
    var query = Query.init(&context);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = task, .offset = Fixture.offsetOf(precedence_role_task, "port", 1) }).?;
    defer subject.deinit();
    const locs = (try query.definition(&subject)).locations;
    try testing.expectEqual(@as(usize, 3), locs.len);
    // The invoking playbook's vars_files outrank the Role's defaults; the
    // unrelated Role's binding is listed last, unranked.
    try expectAt(locs[0], try fixture.uri("playbooks/vars/prod.yml"), 0, 0);
    try expectAt(locs[1], try fixture.uri("roles/db/defaults/main.yml"), 0, 0);
    try expectAt(locs[2], try fixture.uri("roles/web/defaults/main.yml"), 0, 0);
}

test "an open document replaces its indexed copy" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    try writePrecedenceWorkspace(&fixture);
    const task = try fixture.open("roles/db/tasks/main.yml", precedence_role_task);
    // Unsaved edits move the Role default down and add a file the index has
    // never seen.
    const defaults = try fixture.open("roles/db/defaults/main.yml", "# tuned\nport: 6432\n");
    const extra = try fixture.open("roles/db/vars/main.yml", "other: 1\nport: 7000\n");
    var context = try fixture.context();
    var query = Query.init(&context);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = task, .offset = Fixture.offsetOf(precedence_role_task, "port", 0) }).?;
    defer subject.deinit();
    const locs = (try query.definition(&subject)).locations;
    try testing.expectEqual(@as(usize, 4), locs.len);
    try expectAt(locs[0], extra, 1, 0); // role vars
    try expectAt(locs[1], try fixture.uri("playbooks/vars/prod.yml"), 0, 0);
    try expectAt(locs[2], defaults, 1, 0); // the unsaved position, not line 0
    try expectAt(locs[3], try fixture.uri("roles/web/defaults/main.yml"), 0, 0);

    // References see the same overlay: every read and binding of `port`.
    const refs = (try query.references(&subject, true)).?;
    try testing.expectEqual(@as(usize, 5), refs.len);
}

test "hover describes the unsaved value of a binding" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    try writePrecedenceWorkspace(&fixture);
    const task = try fixture.open("roles/db/tasks/main.yml", precedence_role_task);
    _ = try fixture.open("roles/db/defaults/main.yml", "port: 6432\n");
    var context = try fixture.context();
    var query = Query.init(&context);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = task, .offset = Fixture.offsetOf(precedence_role_task, "port", 0) }).?;
    defer subject.deinit();
    const text = (try query.hover(&subject)).?.contents.value;
    try testing.expect(std.mem.indexOf(u8, text, "`6432` — `roles/db/defaults/main.yml:1`") != null);
    try testing.expect(std.mem.indexOf(u8, text, "5432") == null);
    try testing.expect(std.mem.indexOf(u8, text, "**Active:** `8080` — `playbooks/vars/prod.yml:1`") != null);
}

test "role references and definition resolve through the referencing file's Workspace" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    const site = "- hosts: all\n  roles:\n    - web\n";
    const other = "- hosts: all\n  tasks:\n    - include_role:\n        name: web\n";
    try fixture.write("roles/web/tasks/main.yml", "- debug: msg=hi\n");
    try fixture.write("site.yml", site);
    try fixture.write("other.yml", other);
    // An unrelated same-named role elsewhere is not the one site.yml applies.
    try fixture.write("vendor/roles/web/tasks/main.yml", "- debug: msg=vendor\n");
    const site_uri = try fixture.open("site.yml", site);
    var context = try fixture.context();
    var query = Query.init(&context);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = site_uri, .offset = Fixture.offsetOf(site, "web", 1) }).?;
    defer subject.deinit();
    const refs = (try query.references(&subject, false)).?;
    try testing.expectEqual(@as(usize, 2), refs.len);
    try expectAt(refs[0], try fixture.uri("other.yml"), 3, 14);
    try expectAt(refs[1], site_uri, 2, 6);
    switch (try query.definition(&subject)) {
        .location => |loc| try expectAt(loc, try fixture.uri("roles/web/tasks/main.yml"), 0, 0),
        else => return error.TestUnexpectedResult,
    }
}

test "a passed role parameter navigates to the called role's unsaved option" {
    var fixture = try Fixture.init(true);
    defer fixture.deinit();
    const site = "- hosts: all\n  roles:\n    - role: web\n      app_port: 8080\n";
    try fixture.write("site.yml", site);
    try fixture.write("roles/web/tasks/main.yml", "- debug: msg={{ app_port }}\n");
    try fixture.write("roles/web/defaults/main.yml", "app_port: 80\n");
    try fixture.write("roles/web/meta/argument_specs.yml", "argument_specs:\n  main:\n    options:\n      app_port:\n        type: int\n");
    const site_uri = try fixture.open("site.yml", site);
    const specs = try fixture.open("roles/web/meta/argument_specs.yml", "argument_specs:\n  main:\n    options:\n      other: {}\n      app_port:\n        type: int\n");
    var context = try fixture.context();
    var query = Query.init(&context);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = site_uri, .offset = Fixture.offsetOf(site, "app_port", 0) }).?;
    defer subject.deinit();
    const defs = (try query.definition(&subject)).locations;
    try testing.expectEqual(@as(usize, 1), defs.len);
    try expectAt(defs[0], specs, 4, 6);
    const impls = (try query.implementation(&subject)).?;
    try testing.expectEqual(@as(usize, 1), impls.len);
    try expectAt(impls[0], try fixture.uri("roles/web/defaults/main.yml"), 0, 0);
}

test "without a session Workspace the playbook is the search boundary" {
    var fixture = try Fixture.init(false);
    defer fixture.deinit();
    const play = "- hosts: all\n  vars:\n    user: bob\n  tasks:\n    - debug: msg=\"{{ user }}\"\n";
    try fixture.write("other.yml", "- hosts: all\n  vars:\n    user: alice\n");
    const uri = try fixture.open("site.yml", play);
    var context = try fixture.context();
    var query = Query.init(&context);
    defer query.deinit();
    var subject = query.subjectAt(.{ .uri = uri, .offset = Fixture.offsetOf(play, "{{ user", 3) }).?;
    defer subject.deinit();
    const defs = (try query.definition(&subject)).locations;
    try testing.expectEqual(@as(usize, 1), defs.len);
    try expectAt(defs[0], uri, 2, 4);
}

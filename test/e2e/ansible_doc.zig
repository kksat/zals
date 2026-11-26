const std = @import("std");

pub fn requireUsable() !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var env = try std.process.Environ.createMap(std.testing.environ, a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("XDG_CACHE_HOME", try std.fs.path.join(a, &.{ home, ".cache" }));
    _ = env.orderedRemove("VIRTUAL_ENV");
    const result = std.process.run(a, std.testing.io, .{
        .argv = &.{ "ansible-doc", "--version" },
        .environ_map = &env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch return error.SkipZigTest;
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}

const std = @import("std");

pub fn requireUsable() !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(a, ".");
    var env = try std.process.getEnvMap(a);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("XDG_CACHE_HOME", try std.fs.path.join(a, &.{ home, ".cache" }));
    env.remove("VIRTUAL_ENV");
    const result = std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "ansible-doc", "--version" },
        .env_map = &env,
        .max_output_bytes = 1 << 20,
    }) catch return error.SkipZigTest;
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}

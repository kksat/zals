const std = @import("std");
const builtin = @import("builtin");

var process_io: std.Io = undefined;
var process_environ: std.process.Environ = undefined;

pub fn set(io: std.Io, environ: std.process.Environ) void {
    process_io = io;
    process_environ = environ;
}

pub fn get() std.Io {
    if (builtin.is_test) return std.testing.io;
    return process_io;
}

pub fn environment() std.process.Environ {
    if (builtin.is_test) return std.testing.environ;
    return process_environ;
}

pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.Environ.getAlloc(environment(), allocator, name) catch null;
}

pub fn getEnvMap(allocator: std.mem.Allocator) !std.process.Environ.Map {
    return std.process.Environ.createMap(environment(), allocator);
}

pub fn randomBytes(buffer: []u8) void {
    std.Io.random(get(), buffer);
}

pub fn randomInt(comptime T: type) T {
    var x: T = undefined;
    randomBytes(std.mem.asBytes(&x));
    return x;
}

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return cwd().realPathFileAlloc(get(), path, allocator);
}

pub fn openFile(path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
    return cwd().openFile(get(), path, options);
}

pub fn createFile(path: []const u8, flags: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
    return cwd().createFile(get(), path, flags);
}

pub fn openDir(path: []const u8, options: std.Io.Dir.OpenOptions) std.Io.Dir.OpenError!std.Io.Dir {
    return cwd().openDir(get(), path, options);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return cwd().readFileAlloc(get(), path, allocator, .limited(max_bytes));
}

pub fn statFile(path: []const u8) std.Io.Dir.StatFileError!std.Io.Dir.Stat {
    return cwd().statFile(get(), path, .{});
}

pub fn makePath(path: []const u8) std.Io.Dir.CreateDirPathError!void {
    return cwd().createDirPath(get(), path);
}

pub fn deleteTree(path: []const u8) std.Io.Dir.DeleteTreeError!void {
    return cwd().deleteTree(get(), path);
}

pub fn deleteFile(path: []const u8) std.Io.Dir.DeleteFileError!void {
    return cwd().deleteFile(get(), path);
}

pub fn rename(old_path: []const u8, new_path: []const u8) std.Io.Dir.RenameError!void {
    const dir = cwd();
    return std.Io.Dir.rename(dir, old_path, dir, new_path, get());
}

pub fn writeFile(options: std.Io.Dir.WriteFileOptions) std.Io.Dir.WriteFileError!void {
    return cwd().writeFile(get(), options);
}

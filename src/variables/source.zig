//! File-source seam for the variable index.
//!
//! The index reads file text and lists directories through this interface, so
//! tests can inject an in-memory filesystem and the server can wrap the real
//! one (consulting open documents first).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DirEntry = struct {
    name: []const u8,
    is_dir: bool,
};

pub const FileSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Text of `uri`, or null when it does not exist.
        read: *const fn (ptr: *anyopaque, allocator: Allocator, uri: []const u8) anyerror!?[]const u8,
        /// Entries of the directory at `path`. Missing directories yield an
        /// empty slice, not an error.
        listDir: *const fn (ptr: *anyopaque, allocator: Allocator, path: []const u8) anyerror![]const DirEntry,
    };

    pub fn read(self: FileSource, allocator: Allocator, uri: []const u8) !?[]const u8 {
        return self.vtable.read(self.ptr, allocator, uri);
    }

    pub fn listDir(self: FileSource, allocator: Allocator, path: []const u8) ![]const DirEntry {
        return self.vtable.listDir(self.ptr, allocator, path);
    }
};

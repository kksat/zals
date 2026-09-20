//! Role navigation: resolving role names to directories and detecting role
//! references in YAML.

pub const resolve = @import("resolve.zig");
pub const reference = @import("reference.zig");
pub const targets = @import("targets.zig");

pub const Resolver = resolve.Resolver;
pub const Reference = reference.Reference;

test {
    @import("std").testing.refAllDecls(@This());
}

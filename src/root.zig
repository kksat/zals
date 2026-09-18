//! zals — Zig Ansible Language Server.
//!
//! This is the library root. The CLI entry point lives in `main.zig`; everything
//! else is exposed here for testing and embedding.

pub const cli = @import("cli.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

//! Typed semantic navigation over the Workspace (ADR-0032): the queries the
//! navigation protocol adapter runs. No protocol params here.

pub const navigation = @import("navigation.zig");
pub const navigation_subject = @import("navigation_subject.zig");
pub const variable_navigation = @import("variable_navigation.zig");
pub const passed_parameters = @import("passed_parameters.zig");
pub const callee_bindings = @import("callee_bindings.zig");
pub const binding_descriptions = @import("binding_descriptions.zig");
pub const role_navigation = @import("role_navigation.zig");
pub const collection_navigation = @import("collection_navigation.zig");
pub const file_navigation = @import("file_navigation.zig");
pub const variable_hover = @import("variable_hover.zig");
pub const cursor_hover = @import("cursor_hover.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

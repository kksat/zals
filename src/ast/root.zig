pub const span = @import("span.zig");
pub const noqa = @import("noqa.zig");
pub const metadata = @import("metadata.zig");
pub const command = @import("command.zig");
pub const yaml_recover = @import("yaml_recover.zig");
pub const value = @import("value.zig");
pub const ansible = @import("ansible.zig");

pub const Span = span.Span;
pub const DocumentAst = ansible.DocumentAst;
pub const DocumentKind = ansible.DocumentKind;
pub const Play = ansible.Play;
pub const Task = ansible.Task;
pub const RoleRef = ansible.RoleRef;
pub const VarDef = ansible.VarDef;
pub const RoleMeta = ansible.RoleMeta;
pub const GalaxyMeta = ansible.GalaxyMeta;
pub const ParseIssue = ansible.ParseIssue;
pub const MetadataSnapshot = metadata.MetadataSnapshot;
pub const build = ansible.build;

test {
    _ = @import("span.zig");
    _ = @import("noqa.zig");
    _ = @import("metadata.zig");
    _ = @import("command.zig");
    _ = @import("yaml_recover.zig");
    _ = @import("value.zig");
    _ = @import("ansible.zig");
}

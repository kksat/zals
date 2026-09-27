//! zals — Zig Ansible Language Server.
//!
//! Library root. The CLI entry point lives in `main.zig`.

pub const cli = @import("cli.zig");
pub const lsp = struct {
    pub const Server = @import("lsp/server.zig").Server;
    pub const Transport = @import("lsp/transport.zig").Transport;
    pub const types = @import("lsp/types.zig");
};
pub const yaml = @import("yaml/root.zig");
pub const exec = @import("exec/root.zig");
pub const workspace = struct {
    pub const Document = @import("workspace/document.zig").Document;
    pub const DocumentStore = @import("workspace/store.zig").DocumentStore;
    pub const Settings = @import("workspace/settings.zig").Settings;
};
pub const services = @import("services/root.zig");
pub const providers = @import("providers/root.zig");
pub const variables = @import("variables/root.zig");
pub const roles = @import("roles/root.zig");
pub const paths = @import("paths.zig");
pub const concurrency = @import("concurrency/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("cli.zig");
    _ = @import("lsp/transport.zig");
    _ = @import("lsp/writer.zig");
    _ = @import("lsp/server.zig");
    _ = @import("lsp/handlers.zig");
    _ = @import("workspace/document.zig");
    _ = @import("workspace/store.zig");
    _ = @import("workspace/settings.zig");
    _ = @import("providers/validation.zig");
    _ = @import("yaml/parser.zig");
    _ = @import("yaml/keywords.zig");
    _ = @import("yaml/predicates.zig");
    _ = @import("yaml/keyword_docs.zig");
    _ = @import("yaml/jsonify.zig");
    _ = @import("services/schema.zig");
    _ = @import("services/schema_service.zig");
    _ = @import("variables/root.zig");
    _ = @import("roles/root.zig");
    _ = @import("paths.zig");
    _ = @import("concurrency/pool.zig");
}

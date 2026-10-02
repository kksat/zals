const roles = @import("cases/roles.zig");
const collections = @import("cases/collections.zig");
const files = @import("cases/files.zig");
const variables = @import("cases/variables.zig");
const role_parameters = @import("cases/role_parameters.zig");

/// Statically enumerated navigation contracts. No expected target is
/// discovered from the Workspace or from a previous zals response.
pub const all = roles.all ++ collections.all ++ files.all ++ variables.all ++ role_parameters.all;

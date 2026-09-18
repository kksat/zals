//! Bundled ansible-lint JSON Schema snapshots (v25.8.2).

pub const meta = @embedFile("meta.json");
pub const meta_runtime = @embedFile("meta-runtime.json");
pub const galaxy = @embedFile("galaxy.json");
pub const requirements = @embedFile("requirements.json");
pub const execution_environment = @embedFile("execution-environment.json");

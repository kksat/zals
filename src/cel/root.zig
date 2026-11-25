pub const limits = @import("limits.zig");
pub const schema = @import("schema.zig");
pub const env = @import("env.zig");
pub const rule = @import("rule.zig");
pub const builtins = @import("builtins.zig");
pub const registry = @import("registry.zig");
pub const evaluator = @import("evaluator.zig");

pub const TargetKind = schema.TargetKind;
pub const TargetMask = schema.TargetMask;
pub const Severity = schema.Severity;
pub const CompiledRule = rule.CompiledRule;
pub const WorkerRule = rule.WorkerRule;
pub const LoadResult = rule.LoadResult;
pub const LoadError = rule.LoadError;
pub const LoadErrorKind = rule.LoadErrorKind;
pub const EvalOutcome = rule.EvalOutcome;
pub const RuleMeta = rule.RuleMeta;
pub const RuleOrigin = rule.RuleOrigin;
pub const RuleOriginKind = rule.RuleOriginKind;
pub const SourcePos = rule.SourcePos;
pub const RuleSet = registry.RuleSet;
pub const WorkerRuleSet = registry.WorkerRuleSet;
pub const RegistryConfig = registry.RegistryConfig;
pub const RuleFileError = registry.RuleFileError;

test {
    _ = @import("limits.zig");
    _ = @import("schema.zig");
    _ = @import("env.zig");
    _ = @import("rule.zig");
    _ = @import("registry.zig");
    _ = @import("evaluator.zig");
    _ = @import("conformance_test.zig");
}

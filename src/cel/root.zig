pub const limits = @import("limits.zig");
pub const schema = @import("schema.zig");
pub const env = @import("env.zig");
pub const rule = @import("rule.zig");

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

test {
    _ = @import("limits.zig");
    _ = @import("schema.zig");
    _ = @import("env.zig");
    _ = @import("rule.zig");
}

//! Ansible keyword sets, ported from upstream's `utils/ansible.ts`.
//!
//! Only the names are needed for semantic tokens and context detection; hover
//! text for keywords is not yet included.

const std = @import("std");

pub const play_keywords = [_][]const u8{
    "any_errors_fatal",   "become",              "become_exe",      "become_flags",
    "become_method",      "become_user",         "check_mode",      "collections",
    "connection",         "debugger",            "diff",            "environment",
    "fact_path",          "force_handlers",      "gather_facts",    "gather_subset",
    "gather_timeout",     "handlers",            "hosts",           "ignore_errors",
    "ignore_unreachable", "max_fail_percentage", "module_defaults", "name",
    "no_log",             "order",               "port",            "post_tasks",
    "pre_tasks",          "remote_user",         "roles",           "run_once",
    "serial",             "strategy",            "tags",            "tasks",
    "throttle",           "timeout",             "vars",            "vars_files",
    "vars_prompt",
};

pub const task_keywords = [_][]const u8{
    "action",        "any_errors_fatal",   "args",         "async",
    "become",        "become_exe",         "become_flags", "become_method",
    "become_user",   "changed_when",       "check_mode",   "collections",
    "connection",    "debugger",           "delay",        "delegate_facts",
    "delegate_to",   "diff",               "environment",  "failed_when",
    "ignore_errors", "ignore_unreachable", "local_action", "loop",
    "loop_control",  "module_defaults",    "name",         "no_log",
    "notify",        "poll",               "port",         "register",
    "remote_user",   "retries",            "run_once",     "tags",
    "throttle",      "timeout",            "until",        "vars",
    "when",          "listen",
};

pub const block_keywords = [_][]const u8{
    "always",         "any_errors_fatal",   "become",          "become_exe",
    "become_flags",   "become_method",      "become_user",     "block",
    "check_mode",     "collections",        "connection",      "debugger",
    "delegate_facts", "delegate_to",        "diff",            "environment",
    "ignore_errors",  "ignore_unreachable", "module_defaults", "name",
    "no_log",         "notify",             "port",            "remote_user",
    "rescue",         "run_once",           "tags",            "throttle",
    "timeout",        "vars",               "when",
};

pub const role_keywords = [_][]const u8{
    "any_errors_fatal", "become",      "become_exe",     "become_flags",
    "become_method",    "become_user", "check_mode",     "collections",
    "connection",       "debugger",    "delegate_facts", "delegate_to",
    "diff",             "environment", "ignore_errors",  "ignore_unreachable",
    "module_defaults",  "name",        "no_log",         "port",
    "remote_user",      "run_once",    "tags",           "throttle",
    "timeout",          "vars",        "when",
};

/// Play keywords that are not also task, block, or role keywords.
pub const play_exclusive_keywords = [_][]const u8{
    "fact_path",      "force_handlers", "gather_facts", "gather_subset",
    "gather_timeout", "handlers",       "hosts",        "max_fail_percentage",
    "order",          "post_tasks",     "pre_tasks",    "roles",
    "serial",         "strategy",       "tasks",        "vars_files",
    "vars_prompt",
};

fn inSet(set: []const []const u8, value: []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, s, value)) return true;
    return false;
}

pub fn isPlayKeyword(v: []const u8) bool {
    return inSet(&play_keywords, v);
}
pub fn isTaskKeyword(v: []const u8) bool {
    return inSet(&task_keywords, v) or std.mem.startsWith(u8, v, "with_");
}
pub fn isBlockKeyword(v: []const u8) bool {
    return inSet(&block_keywords, v);
}
pub fn isRoleKeyword(v: []const u8) bool {
    return inSet(&role_keywords, v);
}
pub fn isPlayExclusiveKeyword(v: []const u8) bool {
    return inSet(&play_exclusive_keywords, v);
}

/// Play keywords that are not also task keywords (offered at ambiguous task-file roots).
pub fn isPlayWithoutTaskKeyword(v: []const u8) bool {
    return isPlayKeyword(v) and !isTaskKeyword(v);
}

# PRD-0002: Native CEL rules and rule authoring

**Status:** Draft recording agreed product requirements; not implemented.
**Audience:** Implementers, reviewers, and authors of built-in/custom rules.
**Baseline:** `fb808719d04b9bf68c33c09f588fec934f3847ba`.
**Related:** [PRD index](README.md), [Ansible AST](0001-ansible-ast.md),
[diagnostic delivery](0003-workspace-diagnostics.md),
[approved rule coverage](ansible-lint-coverage.md).

## Problem and outcome

Rule authors need a compact, checkable way to express diagnostics over the
native Ansible AST without embedding checks in Python or implementing each
check as Zig control flow. Built-in and custom rules must use the same rule
interface.

Use Common Expression Language (CEL), evaluated in process by the Zig
implementation [zig-cel](https://github.com/kksat/zig-cel). Users must not
install or run a separate CEL service, Python interpreter, or Ansible process
to evaluate a rule.

The engine baseline is zig-cel at commit
[`445a967`](https://github.com/kksat/zig-cel/commit/445a967) ("host function
registration (cel-go FunctionBinding equivalent)"). Pin an exact
commit. The library builds and passes its unit tests and its vendored cel-spec
simple conformance suite on the repository's pinned Zig 0.15.1 toolchain, with
no C++/protobuf/Bazel dependency closure. Upstream results are not evidence
that every Zals integration requirement is satisfied.

## Requirements

### CEL-01: One rule per CEL source file

Store each rule in one `.cel` file. Do not embed rule expressions in YAML
strings. LSP settings select rule files; there is no separate native
`.ansible-lint` configuration reader.

The agreed authoring direction is a typed CEL declaration with literal
metadata, a boolean condition, and a string message expression. This is the
proposed shape, not an already available interface:

```cel
zals.Rule{
  id: "custom/parse-error",
  target: "parse_issue",
  severity: "error",
  condition: true,
  message:
    "Cannot parse " + location.path +
    " on line " + string(location.line) +
    ", column " + string(location.column) +
    ": " + node.message
}
```

For a parse issue, `message: node.message` is also sufficient because the editor
receives the location separately. Constant strings are valid message expressions.
There is no additional `{{ ... }}` interpolation language.

The rule declaration is a Zals hosting convention using CEL syntax, not a
standard CEL rule-file format. Ordinary CEL evaluation of the whole constructor
would evaluate its members and return a record, not a deferred predicate.

### CEL-02: Separate rule loading, conditions, and messages

The host must parse the file and perform these operations without executing the
rule against a Task merely to discover its metadata:

1. Validate the declaration shape and required metadata.
2. Require literals for rule identity, target selection, severity, and any
   source-field selector metadata.
3. Select and type-check the condition as a boolean expression.
4. Select and type-check the message as a string expression.
5. Compile reusable programs with source mappings back to the original file.

Preserve expression IDs, macro information, and source offsets as required by
the engine. Constant-foldable expressions are not automatically literal metadata.
The concrete schema must state which literal metadata forms are accepted.

For each selected target, evaluate the condition first. **True means a
violation; false means no diagnostic.** Only a true condition evaluates the
message. The predicate does not return diagnostic records or lists of findings.
The host constructs the diagnostic and resolves its source range.

Target selection must support the approved checks' actual diagnostic sites.
Some checks apply to more than one Ansible node kind; others need enclosing or
sibling context. Do not reduce a multi-site check to one finding per document.
Resolve target granularity and any compatible multi-kind target representation
in the typed schema without moving the detector itself into Zig.

### CEL-03: Provide a typed, versioned rule environment

Supply rule authors with the declarations/descriptors needed to check `.cel`
files in CEL-aware tooling. These must describe the rule type, target-specific
input types, available functions, and supported CEL profile. Merely associating
the file extension or declaring everything `dyn` is not sufficient for useful
field/type checking.

The input environment must provide:

| Input | Required behavior |
| --- | --- |
| `node` | The selected AST target, including the fields appropriate to its type |
| Source location | A display path and 1-based line/column for the selected diagnostic location |
| Related AST context | Read-only parent/sibling/document facts needed by the selected check |
| Collected metadata | Read-only, already collected facts with explicit availability |
| Rule options | Documented effective options supplied through LSP configuration, where applicable |

The example names `node`, `location.path`, `location.line`,
`location.column`, and `node.message` establish the intended author experience.
Finalize exact field names, target enums, source-field selector syntax, and
schema versioning as an implementation deliverable. Reject unsupported schema
versions or invalid declarations rather than interpreting them silently.

zig-cel exposes its parsed AST (`cel.parser`, `ast.Ast`) with per-node start
offsets, and `cel.vm.Compiler.compile` accepts any `Ast`. Re-rooting a parsed
rule record onto its `condition` and `message` member expressions compiles them
separately from a single parse; that mechanism is verified feasible, but the
rule host still needs its own integration tests. Sharing declarations with a
particular CEL language server also needs an editor test, not a compatibility
claim based on CEL syntax alone.

### CEL-04: Keep evaluation data-only and bounded

All condition, message, and exposed helper evaluation must be deterministic
over its supplied snapshot. Do not expose subprocesses, filesystem/network
access, lazy module-documentation fetching, ambient environment access,
user-provided native functions, or runtime Jinja interpretation.

Shared helpers may perform bounded structural or lexical operations over
supplied data. Do not implement each violation predicate in Zig and expose only
a precomputed violation boolean to CEL. The host owns common normalization,
source handling, target traversal, and publication; the check belongs in CEL.

Compile/check rules outside the per-target evaluation loop and reuse programs.
Set explicit limits for source size, parsing depth and work, comprehensions,
regex complexity, string/collection sizes, per-rule evaluation, aggregate
document/workspace work, and diagnostic output. Provide cancellation that
makes obsolete work stop promptly. A background thread alone is not a
cancellation mechanism.

zig-cel bounds each run with an engine-level instruction budget
(`max_run_steps`, charged conservatively per entered instruction range) and a
cooperative cancellation flag polled per comprehension iteration at worst.
Bound inputs, expression size, and nesting first; keep the run-step budget and
mid-evaluation cancellation as the engine-level backstop so a runaway
comprehension deactivates its rule as a limit error or aborts promptly on
server shutdown.

Use the same bounded interface for built-ins, global custom rules, and trusted
Workspace rules. Trust does not remove resource limits. Do not log complete
AST activations, source secrets, or inherited process environments when a rule
fails.

### CEL-05: Distinguish ordinary results from rule failures

A false condition is not an evaluation error. A missing optional fact, explicit
null, an application-level templated-value marker, CEL `dyn`, and CEL unknown
are different concepts. Follow PRD-0001's value contract; a general symbolic or
unknown-propagation engine is not required for the first milestone.

Reject invalid syntax, missing required metadata, unknown rule targets, and
invalid field selectors during rule loading where possible. Validate runtime
result types as well. A condition must be boolean and a message must be a
string even when no static proof is available.

zig-cel implements no static type-checking phase. Rule loading must therefore
always validate runtime result types, and must perform a host-side structural
lint of the parsed rule AST: required metadata present and literal, a known
target, and condition/message identifiers resolvable against the declared
binding set. The lint reports what it can prove at load time; it does not
replace runtime validation.

A runtime error, unavailable required fact, or exhausted budget must not be
converted into an Ansible-code violation or silently presented as a successful
check. Report rule/configuration failures with the rule ID and rule-file
location where available. Isolate the failing rule/evaluation and keep unrelated
rules and providers working. An expected template is handled explicitly by the
rule, not treated as an engine fault.

### CEL-06: Load built-ins and explicit custom rule files

The approved settings direction is:

| Setting | Contract |
| --- | --- |
| `ansible.validation.cel.enabled` | Enables the native provider; default `true` |
| `ansible.validation.cel.globalRuleFiles` | Explicit absolute rule-file paths applied across Workspaces; default empty |
| `ansible.validation.cel.workspaceRuleFiles` | Explicit paths relative to each owning Workspace; default empty |
| `ansible.validation.cel.allowWorkspaceRules` | Explicit user/client opt-in before Workspace rule files are loaded; default `false` |

Rule files are `.cel`, not the YAML manifest considered earlier in the design
discussion. Do not automatically crawl directories, download rules, or load
arbitrary code plugins. Keep file-origin information so errors identify the
file and scope that supplied a rule.

Workspace content must not opt itself into execution merely by containing a
rule file or an enabling declaration. The LSP/client integration must establish
how explicit permission is supplied; a merged configuration object alone does
not prove that permission originated outside the repository. Resolve that trust
contract before enabling Workspace loading. This does not require changing
editor file detection.

Load built-ins, explicitly selected global rules, and permitted Workspace
rules through the same logical interface. Reject duplicate/conflicting IDs
rather than silently replacing another rule. Preserve built-in identities and
use distinct identities for custom and native-only checks.

Provide LSP controls to disable an individual rule, override its severity, and
set documented supported options. Final per-rule setting names/schema are an
implementation deliverable. Do not read or import `.ansible-lint` configuration.
A source-file suppression is a separate mechanism, specified in PRD-0003.

### CEL-07: Enable the entire implemented catalog by default

Implement the support column of the [coverage matrix](ansible-lint-coverage.md)
and enable **every implemented built-in**, including rules upstream treats as
opt-in. Do not silently apply upstream profiles or its default-enabled subset.
Include a native parse-issue reporting rule with a distinct native identity.

For example, `only-builtins` is enabled unless disabled through native settings,
even when a project intentionally uses Collection modules. Document this
consequence. The external provider keeps its own rule-selection behavior.

Built-in detector semantics follow the pinned subrules and their documented
native options. Fixed upstream lists remain pinned data; they are not replaced
with a superficially similar environment query. A custom rule is active when
its valid rule file is explicitly loaded and permission requirements are met.

### CEL-08: Reload rules without running stale source silently

Reload custom files on save/filesystem change and relevant configuration
updates. If a saved rule becomes invalid, deactivate that rule and clear its
previous findings across affected documents. Keep unrelated rules running and
report the error against the `.cel` file where possible. Do not silently keep
executing its last valid version, and do not disable all custom rules.

When a corrected rule becomes active, reevaluate its affected Workspace
sources. Use a ruleset generation so results from an obsolete program cannot
reappear after reload, disablement, deletion, or permission revocation.

## Native integration and distribution

Consume zig-cel as a pinned Zig package dependency of the server:

- Declare `zig_cel` in `build.zig.zon` using a pinned archive `url` and content
  `hash` for commit `445a967`, and consume its registered `cel` module via
  `b.dependency("zig_cel", ...).module("cel")`. Do not vendor `zig-cel` under
  `vendor/`.
- Do not maintain local patches to the engine; request changes upstream.
  The library is maintained by the Zals owner, so engine improvements belong in
  the upstream repository.
- One `Program` must not run concurrently: compile per worker (compilation is
  microsecond-scale) or serialize evaluation per program. Values built by a run
  reference the caller-provided arena; the snapshot ownership rules of
  PRD-0001 apply.
- The engine is plain Zig with no C++/protobuf/Bazel closure, so the existing
  five-target release matrix (`x86_64-linux-musl`, `aarch64-linux-musl`,
  `x86_64-macos.13.0`, `aarch64-macos.13.0`, `x86_64-windows`) inherits the
  ordinary Zig cross-build and needs only normal build coverage, not a
  foreign-toolchain integration project. The [release workflow](../../.github/workflows/release.yml),
  not the older “Windows later” wording in ADR-0019, defines this baseline.

Preserve a self-contained end-user server. Do not add a separate CEL runtime
service, runtime downloads, or an interpreter dependency. Do not drop a target
or change the Zig toolchain silently to make integration pass. Build-system
changes and dependency notices (the engine is Apache-2.0) must be explicit,
reproducible, and reviewed.

## Acceptance scenarios

| Scenario | Observable acceptance result |
| --- | --- |
| Typed rule with literal metadata | Metadata loads without a Task activation or condition evaluation |
| Boolean condition and dynamic message | Message evaluates only for a true condition; source mapping points into the original `.cel` file |
| Bad field name or result type | Actionable load/type error where statically knowable; runtime enforcement otherwise |
| Constant message, parser message, and composed path/line message | All produce string messages without a second interpolation language |
| Missing selected source field | Documented source-backed fallback; no fabricated coordinates |
| Task and role-entry sites for a shared check | Correct site-level findings without returning diagnostic lists from CEL |
| Literal and templated arguments | Rules can skip or explicitly reject templates as designed |
| Workspace rules without permission | No rule-file evaluation |
| Global rules plus permitted Workspace rules | Both run; source origin and IDs remain identifiable |
| Duplicate ID or invalid saved rule | Visible configuration error; no silent override or stale findings |
| Large/nested expression or expensive regex | Enforced limits; server remains responsive and cancellation works |
| Instrumented evaluator with all I/O routes denied | Built-in/custom conditions and messages still evaluate from supplied data |
| Concurrent evaluations and reloads | No cross-document data leakage, lifetime errors, or obsolete findings |
| Every supported release target | Build/link/package proof plus suitable native runtime smoke coverage |

## Technical validation gates

Before implementing the full catalog, prove a small end-to-end slice:

- Add the pinned zig-cel dependency and resolve the `cel` module in the server
  build.
- Parse a typed rule, extract literal metadata, and re-root/compile its
  condition and message separately with correct source positions.
- Supply typed Task and parse-issue inputs and source-backed locations built
  as zig-cel map/list values.
- Observe boolean/string results, engine errors, limits, and cancellation.
- Confirm ordinary cross-build coverage on all release targets.
- Demonstrate CEL-aware checking with the distributed rule environment.

Record numeric resource limits, memory/startup cost, and measured latency after
this exercise. No benchmark or five-target integration result is claimed by
these requirements. Engine choice is settled; proving a viable integration is
an engineering gate, not permission to substitute another engine silently.

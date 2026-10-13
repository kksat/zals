# Optimized performance regression CI

The dedicated [`performance` workflow](../../.github/workflows/performance.yml)
compares the current checkout with optimized pre-refactor zals at
**`c0c7ae384a12a747ca2596f53bbbb121b1c16ba0`**, with the explicit one-declaration
baseline build compatibility repair described below. Both endpoints are built via
`make build OPTIMIZE=ReleaseSafe`, the release-artifact mode, and measured
sequentially on the **same runner** with the **current existing benchmark
harness**. Historical Apple Silicon absolute medians are not CI budgets.

This workflow complements the existing lint/unit/E2E/smoke workflow; it does
not replace correctness checks. Every performance response must pass the
unchanged harness's content/path/count checks, watcher negotiation, indexed-file
count and the existing client's shutdown checks. Specifically, the inherited
`Client.close()` requests shutdown/exit, waits up to 10 seconds and asserts
process exit status zero; it does not inspect a richer server teardown contract.
The live tool refuses disabled Python assertions. Incorrect or missing results
cannot pass by being fast. No existing benchmark, test, fixture, inline test or production source
was changed to introduce the gate. The later scanner prototype repair does not
change benchmark/client assertions, workload contents or timing thresholds.

The client now retains server stderr and includes its last 8 KiB and the process
exit status when stdout closes. Teardown preserves an earlier response/readiness
failure instead of masking it with a secondary `BrokenPipeError`. This changes
failure diagnostics only: successful shutdown still requires the shutdown
response and process exit status zero within the original timeout. The updated
helper digest is pinned in config and the same helper runs for both endpoints.

## Run the complete live suite

Use separate clean checkouts, one at the fixed baseline SHA and one at the
current revision. Install Zig 0.15.1 and Python 3.12 (CI's interpreter version).
Local runs record their actual Python version; compare endpoints within one
run, not results from different hosts/interpreters.

```sh
# In the CURRENT checkout, with a sibling PINNED baseline checkout:
make performance-ci ARGS="run --baseline-tree ../baseline --output /tmp/zals-perf-new-run"
```

`--output` must be a new or empty directory outside both source checkouts.
The tool verifies the baseline HEAD exactly, requires clean tracked trees,
exports the pinned baseline into `--output/baseline-build`, applies only the
checked compatibility repair there, builds both endpoints explicitly in
ReleaseSafe, saves each executable and its digest, and always executes the current
`test/benchmark_operations.py` for both. The historical checkout remains clean.
It does not execute a baseline-local copy of the harness or select a moving
merge-base/PR base. On Darwin, only `make` child processes receive a copy of the
environment with inherited `DEVELOPER_DIR` removed: Apple's make launcher must
resolve its tool before loading the Makefile. The Makefile then reapplies the
`/nonexistent` SDK link workaround for Zig ([ADR-0019](../adr/0019-toolchain-build-and-platforms.md)).
The gate's own environment, non-make children and Linux behavior are unchanged;
Zig is still invoked exclusively through make with the same version/mode checks.
Existing harness/helper digests are pinned in
[`config.json`](../../tools/performance/config.json).

### Pinned baseline build compatibility repair

The pinned baseline's vendored YAML scanner defines
`tree_sitter_yaml_external_scanner_create()` without a C prototype, while the
runtime callback and generated grammar declare `create(void)`. On Linux,
ReleaseSafe's C function-type sanitizer distinguishes these signatures and
traps before parsing the first YAML file. The original failed CI executable
contains expected signature hash `18fe98a0`, actual hash `06e4201f` and an x64
`ud1` trap; native Linux arm64 reproduces the same failure with SIGTRAP. Debug
readiness is not a substitute for the required ReleaseSafe measurement.

The current vendored definition is fixed to `(void)`. To keep the historical
performance baseline usable **without moving its SHA or disabling any
sanitizer**, the gate applies that same declaration-only build compatibility
repair to an exported snapshot, never to the baseline checkout:

- Export exactly the pinned commit using `git archive`, retaining
  `baseline-source.tar` and its SHA-256 under the result directory. Untracked
  checkout files and build artifacts cannot enter this export.
- Verify the original checkout and exported
  `vendor/tree-sitter-yaml/src/scanner.c` SHA-256 is
  `a510c0ca699cf3853bd2192bf103e11132414bc002fe952a88a7106ffb5d44e9`.
- Require exactly one `void *tree_sitter_yaml_external_scanner_create() {`
  declaration, no already-repaired declaration, and replace only that text with
  `void *tree_sitter_yaml_external_scanner_create(void) {`. Require repaired
  source SHA-256
  `76cce2a10de4180864a43a820b3039d624a8dd3778f1bfcdc707f31c0e3ac4f9`.
- Record the original commit, archive digest, original exported source-tree
  digest, repaired build-input digest, source path, original/repaired source
  digests and exact replacement in `manifest.json` (`baseline_build`). The
  comparison provenance repeats this repair record. Tree digests hash a sorted
  list of relative file paths and their SHA-256 values; only root-level
  `.zig-cache` and `zig-out` are excluded as generated build outputs.
- Build the exported tree with the unchanged ReleaseSafe command. Before
  attesting completion, recheck both original checkout identities/cleanliness,
  the repaired build-input digest and the retained source archive digest.

This is an explicit reviewed exception for C callback ABI compatibility, not a
new performance baseline or a generally configurable patch mechanism. The repair
contract is pinned in code and config, and any mismatch fails closed. It changes
no scanner body, YAML parsing algorithm, compiler flag, harness, workload, optimization
mode, round order or threshold. A future repair requires separate policy review.
The gate retains the exported source/build tree as evidence; its binaries and
measurements must be identified as **pinned baseline plus prototype repair**, not
an unmodified historical executable.

There is deliberately no baseline-update input, build-mode override or partial
workload option on `run`. Baseline/mode/round/workload/scenario changes require
an explicit reviewed tooling-policy change. No baseline data is learned or
silently updated from PR results. As with other CI logic, intentional changes
to the workflow/tool itself require review; the gate is not a sandbox against
malicious changes to its own source.

## Workloads and order

All workloads use 20 tasks/background file, three fresh server sessions per
watcher mode/round, two warmup passes and both watcher modes. No source files
change during measurement.

| Workload | Background / indexed files | Warm samples/session | Scenarios/mode | Filter |
| --- | ---: | ---: | ---: | --- |
| Full checked request matrix | 1000 / 1027 | 10 | 73 measured + 16 N/A | none |
| Discovery-only semantic, small | 10 / 37 | 20 | 1 measured | `semantic tokens` |
| Discovery-only semantic, large | 8000 / 8027 | 20 | 1 measured | `semantic tokens` |

The full matrix covers **146 measured scenarios across both watcher modes**,
including the checked 20,001-location reference response. The two focused sizes
add four scenarios. Focused requests open only the semantic-token document;
full-matrix requests open their complete set of case documents. They are
separate workloads, never pooled together. The large focused workload detects
whole-index stale-file checks on discovery-only paths without hiding them
behind unrelated request costs. Both endpoint small→large median changes are
reported, but a noisy ratio of two sub-ms slopes is not a separate v1 gate.

Round 1 uses seed 42 in baseline → current order for each workload. Round 2
uses seed 1042 and reverses endpoint order. Each endpoint/scenario has six first
observations, plus **60 warm samples** in the matrix or **120 warm samples** in
a focused workload. Requests within sessions are interleaved in the harness's
seeded shuffled order. Endpoints never run concurrently.

## Fail-closed evidence checks

Before comparing timings, the tool requires complete data for both rounds,
endpoints, workloads and watcher modes. It validates the exact explicit
scenario contract, including all N/A rows, rather than comparing only an
intersection or trusting a row count. Duplicate, missing, unexpected,
method-changed or measured-to-N/A scenarios fail. Both focused workloads must
cover both watcher modes too.

Metadata and the workload/seed/filter/indexed-file contract must match. Raw
first/warm/startup sample arrays must have the expected lengths, contain only
finite positive numbers, and result counts must be the pinned positive integer
counts for each scenario. Count arrays include first and warm responses, not
untimed warmups. Redundant statistics are checked against raw samples; medians
and nearest-rank p95 are recomputed. N/A rows may not contain timing/count data.
JSON with duplicate object keys or nonstandard NaN/Infinity is refused.

Live provenance records exact endpoint Git SHAs, the explicit baseline build
repair and source/build-input digests, build commands, binary digests,
platform/machine, Python/Zig versions, harness/config digests, command
order, raw-report digests and completion status. Live raw reports must match
saved executable digests and runner identity. The complete live suite validates
before making any timing decisions. Missing, malformed, truncated, mismatched,
nonfinite or incorrect evidence is a failure, not a reason to skip a scenario
or accept an empty baseline.

## Median policy and jitter

A **confirmed regression** requires all three conditions:

1. Pooled warm median increases **strictly more than 10% AND 0.50 ms**.
2. Seed-42 round median increases **strictly more than 5% AND 0.25 ms**.
3. Seed-1042 reversed-order round median increases **strictly more than 5% AND
   0.25 ms**.

Either a relative-only or absolute-only increase is insufficient. Relative
thresholds protect slower navigation; the absolute floor avoids huge percentage
alarms from tiny transport/scheduling differences on sub-ms requests. Repeated
fresh sessions and order reversal help with drift; the independent-round
confirmation is an explicit jitter policy, **not** a significance test.

A pooled candidate lacking round confirmation is prominently listed as
**UNCONFIRMED**, with both round deltas, before the complete comparison table.
It does not fail v1 timing policy, but must not be described as evidence of
identical performance. Persistent candidate noise warrants runner investigation
and policy review, not threshold loosening solely to turn a fixed build green.

First-response medians, pooled p95/max and startup median/p95 are reported
**separately**, not mixed into warm medians or used as v1 failure thresholds.
First observations occur after readiness and may share warmed services with
earlier cases; they are not isolated cold requests. Nearest-rank p95 is a
sampled observation, not a production tail SLO. Readiness includes the server's
poll interval. These checks make no statistical-significance or SLO claim.

The [deep-module comparison](deep-modules-comparison.md) explains why both
watcher modes and focused scaling matter. Its Mac measurements are replay
examples, not portable hard latency ceilings. This synthetic gate does not
measure real Ansible imports/plugins, edits/watcher events, real user Workspace
shape, cold OS cache, concurrency, RSS or editor rendering.

## Results and failure behavior

Exit codes: **0** within policy (possibly with unconfirmed candidates), **1**
confirmed timing regressions, **2** invalid/incomplete evidence or command
failure. CLI syntax errors also return 2. The workflow does not mask nonzero
status with `continue-on-error`.

`summary.md` and `comparison.json` retain complete per-scenario warm median,
p95/max, first medians, sample/result counts and per-round deltas. Live runs also
retain `manifest.json`, per-command logs, raw benchmark JSON/Markdown and
endpoint executables, the pinned baseline source archive and its repaired build
snapshot. Errors retain an explicit failure summary and
`error.json`; unfinished runs are never marked complete. A setup/abrupt-failure
fallback summary exists before checkout. Summary publication and artifact
upload use `always()`; artifacts are retained for 14 days.

Runtime bounds: job 40 minutes, measurement/build step 35 minutes, aggregate
subprocess budget 30 minutes, each build/full-matrix command at most 10 minutes,
each focused command at most 3 minutes. Timeout cleanup kills the subprocess
group including benchmark/server children. A timed-out command or missing JSON
fails the gate rather than generating fake successful samples.

The new workflow uses existing action-version conventions (`checkout@v4`,
`setup-zig@v2`, `setup-python@v5`, `upload-artifact@v4`), a pinned Ubuntu 24.04
runner image major, contents-read permissions and non-persistent checkout
credentials. It uses ordinary `pull_request`, never `pull_request_target`, and
needs no secrets, write token, pip install or new Python dependency. Normal
checkout/toolchain setup accesses the network; the existing benchmark fixtures
and stand-in tools need no network access.

## Offline replay and guard self-checks

These commands read reports or use synthetic in-memory samples; they never
build or execute a zals server. Guard self-checks run automatically in an
explicit dedicated-workflow step, outside the existing test tree:

```sh
python3 -m unittest discover -s tools/performance -p test_gate.py
```

For complete two-round archived optimized matrix data:

```sh
archive=/tmp/zals-deepmodules-perf.p9SoJZ
python3 tools/performance/gate.py compare --workload matrix \
  --baseline "$archive/before-release-safe-r1.json" \
  --baseline "$archive/before-release-safe-r2.json" \
  --current "$archive/after-release-safe-r1.json" \
  --current "$archive/after-release-safe-r2.json" \
  --output /tmp/perf-gate-unfixed-new
# Expected exit 1: archived optimized BEFORE versus archived optimized UNFIXED.

# Baseline self control: same baseline reports on both sides, expected exit 0.
python3 tools/performance/gate.py compare --workload matrix \
  --baseline "$archive/before-release-safe-r1.json" \
  --baseline "$archive/before-release-safe-r2.json" \
  --current "$archive/before-release-safe-r1.json" \
  --current "$archive/before-release-safe-r2.json" \
  --output /tmp/perf-gate-self-new
```

`compare` validates the selected workload's complete two-round/both-watcher
contract but labels its output **offline replay**. Raw reports cannot prove
arbitrary binaries were built with a claimed optimization flag, identify their
Git revision, or attest that they shared one physical host. Replay reports
record input paths and reported binary digests. Live CI exclusively uses `run`,
never this partial-workload command. Single-round/no-watcher-only archived
focused reports are **not** accepted as a complete live suite or silently
expanded into another round/mode.

The unit controls include self comparison and bounded synthetic noise (+5%
plus 0.10 ms, with raw summaries recomputed), detection of 12% slower navigation,
both-round confirmation, malformed/missing/nonfinite/changed-workload data,
CLI failure codes/artifact retention, mocked process-group timeout cleanup and
a fully mocked live orchestration loop (complete suite/order, missing final
endpoint data and changed config/source digest), plus refusal of changed baseline
repair policy/source bytes, exact one-declaration replacement, clean original
checkout preservation, export/build provenance and post-build source/archive
integrity. These test the guard, not
production behavior. Repaired performance must be
validated by an attested same-host live run with the pinned baseline after the
parent supplies the repaired endpoint; archived Mac results must not be used
as the baseline for a new host's repaired measurements.

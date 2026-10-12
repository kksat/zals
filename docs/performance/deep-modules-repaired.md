# Deep-module performance regressions: diagnosis, fixes and CI

Measured on 2026-10-12. This follows the [original comparison](deep-modules-comparison.md).
Both demonstrated runtime causes are corrected. The complete optimized live
regression gate passed: **150 measured scenarios, zero confirmed regressions,
zero unconfirmed candidates**, against the optimized pre-refactor baseline.
This is a bounded warm-latency result, not a claim that every workload or tail
latency is unchanged.

## Runtime causes and corrections

### Discovery-only requests revalidated the entire index

Introduced by `e387a82`: `docsForUri` obtained project collection paths through
`WorkspaceIndex.info`, whose common lease preparation ran `refreshStale` without
file watching. Semantic tokens, completion and other discovery-only operations
therefore statted every known file. Commit isolation, watcher controls and
file-count scaling reproduced the cause; no CPU-profile claim is made.

`a6bea14` separates two private preparation states:

- First discovery/entry access drains pending results once, then freezes further
  drains and discovery storage until the existing handler-owned lease releases.
- First **entry** access performs no-watcher disk revalidation before borrowing
  entry storage. Discovery-only access does not refresh entries.
- Entry preparation may follow a RootInfo borrow: it does not drain again or
  replace discovery storage. Entry replacement remains prohibited after an
  entry borrow. Release clears both states.

No copied snapshots, nested leases, stale-fact shortcut or provider-specific
workaround was introduced. Changed/deleted closed-file facts and unsaved buffer
precedence were checked through existing clients; existing startup, notification
and navigation suites passed. There is no new deterministic queued-RootInfo
replacement oracle; the separate storage/preparation rules were also reviewed.

Serialized focused no-watcher semantic-token results, ReleaseSafe, 120 warm
samples/cell across two seeds (three sessions ×20 samples per round):

| Indexed files | Pre-refactor median ms | Unfixed median ms | Lease-fixed median ms |
| --- | ---: | ---: | ---: |
| 1,027 | 0.168 | 1.045 | 0.161 |
| 8,027 | 0.184 | 10.241 | 0.171 |

The original existing 1 ms p95 local budget remained red on the unfixed binary
and green on the correction. This budget is a local diagnostic, not CI policy.

### Callee lookup sorted the whole Workspace before selecting one Role

Introduced by `64a8385`. With all benchmark documents open and 1,027 indexed
files, the Debug root-parameter implementation loop passed before that commit
(14.902 ms median /17.244 p95) and failed immediately after it
(19.038 /22.668 ms). Tagged stage timings attributed approximately 4.3 ms to
collecting/sorting every Workspace entry, although only five callee sources
survived. Collection itself was about 0.08 ms; sorting dominated.

`9e685f6` adds `WorkspaceIndex.entriesWithin`, sharing preparation and collection
with `entriesOf`, but filtering the Workspace/directory before allocating and
sorting the pointer list. The callee query uses the scoped getter and retains
conventional-source filtering, path ordering, one-level explicit-load hydration,
load-site ranking, schema-only empty answers and unsaved overlays. There is still
a linear entry-map scan; no new secondary index or callback framework was added.

The final uninstrumented all-documents Debug loop, same workload and unchanged
18 ms p95 diagnostic budget:

| Endpoint | Median ms | p95 ms | Budget verdict |
| --- | ---: | ---: | --- |
| Integration before callee correction | 18.887 | 20.383 | fail |
| Corrected | 14.429 | 16.175 | pass |

The unchanged complete Debug matrix also recovered original pre-refactor root
implementation performance (60 warm samples/cell): watching 14.610 →14.389 ms;
no watching 15.992 →16.031 ms. ReleaseSafe did not originally have a comparable
callee regression. One broad ReleaseSafe slowdown in an agent's second round
was retained and investigated; reversed controls and a repeated full workload
at the same seed did not reproduce it. No unrelated optimized cause was guessed
or repaired to explain that batch. Temporary production instrumentation was
removed before final measurements and commits.

## Independent final optimized comparison

The parent ran the **exact** new `make performance-ci` live command, not a
hand-edited replay, after reviewing/integrating both runtime fixes and CI:

- Baseline: `c0c7ae384a12a747ca2596f53bbbb121b1c16ba0`.
- Corrected checkout: `f2b96a87ad8784ac103ae59a2a1831b2cf95e01d`.
- Both binaries freshly built with `make build OPTIMIZE=ReleaseSafe`.
- Apple M3 Pro, 36 GiB RAM, macOS 26.7.1 arm64, Zig 0.15.1, Python 3.14.5.
- Current unchanged harness for both endpoints; sequential endpoint runs.
- Two reversed-order rounds, seeds 42/1042, three fresh sessions/mode/round,
  two warmup passes. Matrix: 1,000 background files ×20 tasks, 1,027 indexed files,
  60 warm samples/cell. Focused semantic sizes: 37/8,027 indexed files,
  120 warm samples/cell. Both watcher modes in every workload.
- All twelve raw reports, scenarios, sample/result counts, digests and completion
  metadata validated; every measured response passed the existing content checks.

Representative **no-watcher** full-matrix medians:

| Operation | Optimized baseline ms | Corrected ms | Change |
| --- | ---: | ---: | ---: |
| Semantic tokens | 0.229 | 0.238 | +0.009 ms |
| Keyword completion | 0.298 | 0.292 | -1.8% |
| Workspace collection definition | 10.430 | 10.309 | -1.2% |
| Workspace collection hover | 5.319 | 5.305 | -0.3% |
| Role-read variable definition | 15.703 | 10.512 | -33.1% |
| Local-role references | 17.451 | 11.331 | -35.1% |
| Role-parameter implementation | 8.729 | 8.298 | -4.9% |
| 20,001-location references | 79.483 | 78.343 | -1.4% |

Focused no-watcher semantic tokens: **0.178 →0.179 ms** at 37 files and
**0.182 →0.175 ms** at 8,027 files. Corrected large-workload p95 was 0.404 ms,
versus baseline 0.242 ms; these remain sampled local observations. Full-matrix
high-fan-out p95 increased 87.615 →92.410 ms despite its lower median. The gate
reports p95/first/startup separately and does not claim tail regressions are ruled
out. Full-matrix startup medians were 116.582 →119.324 ms with watching and
118.454 →123.444 ms without; six samples/mode, reporting only. These are not the
separate original 14-process startup benchmark or controlled cold-disk timings.

The [complete repaired CSV](deep-modules-repaired.csv) preserves all 150
workload/mode/scenario comparisons, median/p95/first medians, per-round deltas,
sample/result counts and gate statuses. The original pre-fix CSV remains intact.

Binary SHA-256 from the final live manifest:

| Endpoint | SHA-256 |
| --- | --- |
| Optimized baseline | `a5d1e87e578426ffae4c50c26a35cb0d29a4c5f470727e1f1994730b91ffde9e` |
| Optimized corrected | `aaf4b31619620c3295ac517f0da6e6f30274da71609b54e8b535cdfe619d3bb3` |

## CI and verification

[`performance.yml`](../../.github/workflows/performance.yml) and
[`ci-gate.md`](ci-gate.md) document the gate. `55bbba6` adds the pinned optimized
comparison, complete workload contract, strict evidence validation, reporting
and automatic offline guard tests. The same-runner median policy is >10% **and**
>0.50 ms pooled, confirmed at >5% **and** >0.25 ms in each reversed round.
Thresholds were not loosened to make the correction pass. Startup/first/p95 are
reporting-only. Baseline updates require an explicit reviewed policy change.

The comparator rejects **all 14** archived optimized pre-fix regressions, passes
archived baseline-self and bounded synthetic-noise controls, and passes the final
complete live suite with **zero candidates**. The controls demonstrate guard
behavior; synthetic noise is not measured runner jitter.

The first live entrypoint attempt failed before measurement: the outer Makefile's
Darwin SDK override prevented Apple's nested make launcher from starting.
`f2b96a8` clears that variable only for Darwin make child environments; the child
Makefile still applies the Zig SDK workaround. A dedicated guard regression test
and real version-only red/green probes cover the failure. All failure artifacts
remain retained; the successful complete run uses a separate output directory.

Each completed change passed `make check`, full `make e2e` and `make smoke` before
commit, and the parent independently reran them after synchronization. The new
**27 guard tests** pass, and actionlint 1.7.7 accepts the workflow. Two earlier
parent post-rebase build invocations hit 300/600-second shell limits; subsequent
independent checks completed successfully. Those partial checks and the initial
launcher failure are not counted as successful performance runs.

Existing `test/` files, fixtures and benchmark sources are byte-identical; all
**55 named Zig-test-containing suffixes** across `src/` and `test/` were independently
compared byte-for-byte. Only dedicated new guard tests outside the existing test
tree were added. Existing suites establish preservation, not exhaustive new
lifetime/getter-boundary coverage. No RSS, concurrency, real Ansible/lint, edit
load or real-user Workspace benchmark was performed. CI has been added and its
exact command run locally; GitHub-hosted Linux execution and branch-protection
requirements have **not** been configured or claimed. Nothing was pushed.

## Reproduction and retained artifacts

With a separate clean checkout at the literal baseline SHA:

```sh
make performance-ci ARGS="run --baseline-tree /path/to/pinned-baseline --output /tmp/new-perf-results"
python3 -m unittest discover -s tools/performance -p test_gate.py
```

Raw timing JSON, executable copies, logs and final manifest are retained locally
under `/tmp/zals-perf-fixes.9G18AQ/live-gate-v2/`; the parent command log is
`/tmp/zals-perf-fixes.9G18AQ/live-gate-v2.log`. Final comparison JSON contains
all timing statistics; manifest binds the twelve reports to sources/binaries.
Diagnostic artifacts are under the same parent directory and `/tmp/lease-perf-fix-*`.
Full external findings: `/tmp/lease-perf-fix-report.md`,
`/tmp/callee-perf-fix-report.md`, `/tmp/perf-ci-gate-report.md`.

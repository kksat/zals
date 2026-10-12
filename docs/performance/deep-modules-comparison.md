# Deep-module refactor: before/after performance

Measured on 2026-10-12. **There are performance regressions, but not a blanket
slowdown.** The main release-build regression affects clients without file
watching: some previously document-local requests now pay for a whole-index
stale-file check. Variable navigation and role references became faster in
that mode. A separate role-parameter implementation regression appears in
Debug, not in ReleaseSafe.

## Comparison and method

- Before: `c0c7ae384a12a747ca2596f53bbbb121b1c16ba0`, before all deep-module runtime changes.
- After: `a8013c6fe364814ffe4604ab4040c2c9dedd369d`, after all changes.
- Hardware: Apple M3 Pro, 36 GiB RAM; macOS 26.7.1 arm64.
- Toolchain: Zig 0.15.1; Python 3.14.5.
- Compared identical build modes: ReleaseSafe (release-artifact mode) and Debug.
  All builds ran through `make`; build files and benchmark/test sources are
  byte-identical between the endpoints.
- Existing `test/benchmark_operations.py`: 1,000 background YAML files with
  20 tasks each, **1,027 indexed files**, 73 checked scenarios per watcher mode.
  Includes a 20,001-location reference response. Ansible tools are deterministic
  fixture helpers, not the real installation; validation is disabled.
- Two rounds, in **before/after then after/before** order. Each round used three
  fresh server sessions per mode, ten warm samples per scenario per session,
  two warmup passes, and seeded shuffled requests (42, then 1042).
- Tables below pool **60 warm samples per endpoint/scenario** across six
  sessions. Times are end-to-end stdio round trips including transport and
  client JSON decoding. p95 is nearest-rank. First observations are not isolated
  cold requests and are not mixed into warm statistics.
- Runs were sequential, not concurrent. Every measured response passed the
  existing harness's content/path/count checks; faster incorrect/empty results
  were not accepted.

The [complete comparison CSV](deep-modules-comparison.csv) contains all 292
measured build/mode/scenario combinations, pooled median/p95, first-observation
medians, sample/result counts, and each round's percentage change. N/A provider
combinations are not counted as measurements.

## 1. ReleaseSafe: regressions without file watching

Representative warm results at 1,027 indexed files:

| Operation | Before median ms | After median ms | Change | Before / after p95 ms |
| --- | ---: | ---: | ---: | ---: |
| Semantic tokens | 0.216 | 1.230 | +469% (+1.014 ms) | 0.268 / 1.918 |
| Play-keyword completion | 0.281 | 1.329 | +374% (+1.049 ms) | 0.343 / 1.864 |
| Module-option completion | 0.242 | 1.225 | +407% (+0.984 ms) | 0.309 / 2.073 |
| Completion resolve | 0.199 | 1.209 | +507% (+1.010 ms) | 0.254 / 1.850 |
| Workspace collection definition | 10.093 | 12.177 | +21% (+2.084 ms) | 11.099 / 12.641 |
| Workspace collection hover | 5.192 | 6.642 | +28% (+1.451 ms) | 5.950 / 7.485 |

Module definition/hover, module-option hover, keyword hover and installed
collection navigation also regressed in this mode. Using a descriptive
screening threshold of **at least 10% and 0.5 ms** median increase, 14 of 73
ReleaseSafe scenarios regressed without watching; all 14 increased in both
run-order rounds. This threshold is not a production SLO or a significance test.

### Attribution and scaling

A focused semantic-token comparison across the exact lease transition,
with 1,027 indexed files and no watching, reproduced the increase:

| Revision | Warm median ms | Warm p95 ms |
| --- | ---: | ---: |
| `77b9cda` — queued output owner, before lease | 0.166 | 0.201 |
| `e387a82` — query lease introduced | 1.019 | 1.304 |
| `67efe1e` — first implementation phase complete | 1.114 | 1.180 |
| `a8013c6` — all improvements | 1.137 | 1.263 |

Each focused measurement used three sessions and 20 warm samples/session.
The existing `--max-p95-ms 1` local budget passed before the lease and failed
at/after the lease. Failures were timing-budget assertions, not incorrect
responses. This identifies the initial lease change, rather than the later
typed navigation migration, as introducing this semantic-token regression.

Source inspection explains the path:

1. `handlers.handleRequest` acquires `index.acquireQuery(!watching_files)`.
2. Document features use `Server.docsForUri`, which obtains project context
   and `workspaceCollectionPaths`.
3. `WorkspaceIndex.info` calls `prepareQuery`, even for discovery metadata.
4. On the first borrow without watching, `prepareQuery` calls `refreshStale`,
   which stats every known indexed file before freezing the revision.

Previously this discovery-only path drained pending data but did not refresh
all file entries. The stable lease is a correctness improvement; its current
preparation policy adds unnecessary work to these document-feature requests.
This conclusion combines the isolated commit comparison, workload scaling,
watcher-mode control and the inspected call path; it is not a CPU profile.

Focused ReleaseSafe semantic-token scaling, no watching (60 samples/endpoint):

| Indexed files | Before median ms | After median ms | Before / after p95 ms |
| --- | ---: | ---: | ---: |
| 37 | 0.181 | 0.235 | 0.212 / 0.335 |
| 1,027 | 0.165 | 1.137 | 0.209 / 1.263 |
| 8,027 | 0.178 | 9.949 | 0.232 / 15.572 |

These focused runs open only the semantic-token case's document, unlike the
full matrix, which opens its complete set of case documents. Compare endpoints
within each workload, not the focused absolute timings against the full matrix.
The approximately 10 ms median tax at 8,027 files is more important than the
large percentage changes on sub-millisecond requests in the smaller workload.

## 2. File watching enabled and operations that improved

No ReleaseSafe watcher-enabled scenario crossed the 10% **and** 0.5 ms
screening threshold. This is evidence against a broad release-build slowdown
in the unchanged-files watcher mode, not proof of identical performance for
all workloads or watcher events.

Without watching, important ReleaseSafe operations became faster:

| Operation | Before median ms | After median ms | Change |
| --- | ---: | ---: | ---: |
| Variable definition, role read | 15.479 | 10.396 | -33% |
| Local-role references | 17.187 | 11.308 | -34% |
| Collection-FQCN role references | 17.049 | 11.074 | -35% |

The gains in variable/field definitions, implementations and several hovers
are consistent with sharing preparation rather than repeating fallback
refreshes; their hotspots were not separately profiled.
The 20,001-location reference request was approximately unchanged in
ReleaseSafe without watching: 77.780 to 78.481 ms (+0.9%).

## 3. Debug: role-parameter implementation regressed

The whole-matrix workload found an additional reproducible Debug regression:

| Root role-parameter implementation | Before median ms | After median ms | Change |
| --- | ---: | ---: | ---: |
| Watching enabled | 15.229 | 18.458 | +21% (+3.230 ms) |
| No watching | 15.742 | 20.481 | +30% (+4.739 ms) |

Both rounds increased in each mode. ReleaseSafe did not show a comparable
increase: 7.135 to 7.092 ms with watching, and 8.127 to 8.315 ms without it.
The exact introducing commit/hotspot for this Debug-specific regression has
**not** been isolated; do not treat the shared callee lookup as a proven cause.
The full workload's multiple open documents are part of this observation.

Debug also showed the no-watcher document-feature tax: semantic tokens
0.395 to 1.524 ms, keyword completion 0.557 to 1.724 ms. Overall, one Debug
watcher-enabled scenario and 15 non-watcher scenarios crossed the same
screening threshold. Other Debug variable navigation and role-reference
operations improved; see the CSV rather than assuming all Debug queries slowed.

## 4. Startup/indexing

Existing `test/benchmark_workspace.py`, 20 tasks/file, no Ansible tools,
empty application cache, two reversed-order batches of seven fresh processes
per endpoint (**14 samples each**):

| Build / files | Before median ms | After median ms | Change |
| --- | ---: | ---: | ---: |
| ReleaseSafe / 1,000 | 101.05 | 116.20 | +15.0% (+15.15 ms) |
| ReleaseSafe / 8,000 | 656.65 | 653.70 | -0.4% |
| Debug / 1,000 | 262.85 | 277.60 | +5.6% (+14.75 ms) |

The smaller startup workload showed a modest increase in both run-order
rounds; the larger ReleaseSafe workload did not. Readiness uses a 25 ms poll,
and sample ranges overlap substantially (ReleaseSafe 1,000: before 88.0–127.0,
after 88.3–127.4 ms). Thus report the observed smaller-workload increase, but
do not infer a broad proportional indexing regression or assign it to hashing
without further profiling. These are cold application-cache timings, not
controlled cold OS-disk measurements.

## Reproduction and artifacts

From the after revision, using separate detached worktrees/binaries:

```sh
make build OPTIMIZE=ReleaseSafe
# Copy each endpoint's binary before building another mode.
python3 test/benchmark_operations.py --binary /path/to/endpoint-binary \
  --label ReleaseSafe --files 1000 --tasks 20 --sessions 3 --samples 10 \
  --warmup 2 --seed 42 --json /tmp/endpoint-r1.json
# Reverse endpoint order and repeat with --seed 1042; repeat in Debug.

python3 test/benchmark_operations.py --binary /path/to/endpoint-binary \
  --files 1000 --tasks 20 --watching off --filter 'semantic tokens' \
  --sessions 3 --samples 20 --warmup 2 --max-p95-ms 1 \
  --json /tmp/endpoint-semantic.json
# Repeat focused scaling with --files 10 and --files 8000, without the budget.

python3 test/benchmark_workspace.py --binary /path/to/endpoint-binary \
  --files 1000 --tasks 20 --runs 7
# Reverse endpoint order and repeat; also --files 8000 for ReleaseSafe.
```

Local raw JSON, full generated Markdown tables, startup logs and binaries are
retained in `/tmp/zals-deepmodules-perf.p9SoJZ/`; the committed CSV preserves
all complete main-matrix summaries. Binary SHA-256 identifiers:

| Endpoint / build | SHA-256 |
| --- | --- |
| Before ReleaseSafe | `3e204a39291276a20a618a9d16102eb84df112c4af7e0eefe96c3d8b443dfed1` |
| After ReleaseSafe | `b6392dbabfee402585f7cef340e0bd7f52739bd20d4ac4c3cff3a3f36af6e5f5` |
| Before Debug | `267c22669a949ddda8f56676bffb180e4d84beed825987a5cbfaa439529558b8` |
| After Debug | `a8b9c72e345cc81f8e94c653d2fe81b1bae3dd705865cfe0fe639acf1bee6cd3` |

## Limits and recommendation

- No production code, tests, fixtures or benchmark sources were changed.
  This is measurement/reporting, not a regression fix.
- No RSS/peak-memory, CPU-profile, concurrent-client, real ansible-doc/lint,
  cache-lock-contention, edit/watcher-event or user-Workspace benchmark was
  performed. Synthetic background files contain reads rather than a large
  population of binding definitions. Results do not characterize every source
  shape or the persistent-memory cost of binding-line metadata.
- Two ancillary batches reached the shell tool's wall-clock limit: a partial
  8,000-file Debug startup batch and an intermediate-commit Debug full matrix.
  Their incomplete results are excluded. All main endpoint matrices, focused
  attribution/scaling runs and startup groups reported above completed; the
  focused timing-budget failures were intentional detection signals.
- Large percentages on sub-millisecond operations should be read alongside
  absolute deltas. Sampled p95 values are local observations, not tail-SLO claims.

**First optimization to investigate:** separate safe discovery-metadata
borrowing from whole-entry stale-file revalidation, preserving the lease's
request-long lifetime guarantees. Do not simply disable the lease or restore
nested mutation. Next, profile Debug root-parameter implementation under the
full matrix's open-document workload. The smaller startup delta warrants a
separate check before attributing it to new fact metadata.

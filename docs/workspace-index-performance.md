# Cold Workspace indexing performance

Measure initialization through `ansible/workspaceIndexReady`, not module-docs
prefetch. The benchmark starts a new server for every sample, isolates its docs
cache, disables Ansible subprocesses by using an empty `PATH`, and waits for
readiness without generating request traffic. Synthetic fixture creation is
outside the timed interval. File counts are checked so skipping work cannot
silently improve the result.

```sh
make build
python3 test/benchmark_workspace.py --files 1000 --runs 5 --max-ms 1000

# Optimized production-like build (the Makefile's macOS SDK workaround applies).
DEVELOPER_DIR=/nonexistent zig build -Doptimize=ReleaseFast
python3 test/benchmark_workspace.py --files 8000 --runs 5 --max-ms 1000

# Use the actual Workspace that feels slow; leave its sources unchanged.
python3 test/benchmark_workspace.py --workspace /path/to/workspace --runs 5
```

`--binary` selects an alternate build for before/after comparisons. The
synthetic workload has 20 tasks per file, including root and field references
in both delimited Jinja and bare `when` expressions. `--tasks` changes this
workload. These are **cold application-cache** measurements, not controlled
cold OS page-cache measurements. Run-to-run differences include executable
paging, filesystem caching, scheduling, and the server's 25 ms readiness poll.
The optional median budget is a local feedback loop, not a portable CI limit.

## Measurements and implemented changes

Local Apple Silicon/macOS measurements against `1b56b94`, using Zig 0.15.1.
Numbers are medians of three baseline samples and five final synthetic samples;
the real-workspace comparison used three samples per build.

| Workload | Build | Before | After | Reduction |
| --- | --- | ---: | ---: | ---: |
| 1,000 YAML files | Debug | 2,772 ms | 283 ms | 90% |
| 1,000 YAML files | ReleaseFast | 254 ms | 91 ms | 64% |
| 8,000 YAML files | ReleaseFast | 1,827 ms | 557 ms | 70% |
| Real Workspace, 1,313 indexed files | Debug | 853 ms | 136 ms | 84% |

1. **Optimize vendored C in Debug builds.** Sampling attributed roughly 70% of
   indexing-worker CPU time to unoptimized tree-sitter parsing. Compile its C
   sources with `-O2` even in Debug, without defining `NDEBUG` or changing Zig's
   debug mode. This alone reduced the 1,000-file Debug median to 930 ms.
   Release-mode flags remain unchanged.
2. **Share parsing work within the bounded worker pool.** ReleaseFast sampling
   still attributed most worker CPU time to YAML parsing while another worker
   was idle. Discovery now hands an immutable file set to up to four parsing
   tasks, with a shared atomic cursor to balance unequal file sizes. The server
   uses two to four pool threads according to CPU count. Each task has private,
   capped scratch storage. The discovery worker also parses instead of waiting
   on its pool; the last task publishes completion and frees the snapshot.
   Index-map writes remain exclusively on the main thread.

Regression tests exercise one-, two-, and four-thread pools, concurrent
Workspaces, retained root/field facts, overlapping generations, root removal,
and shutdown with queued work. Existing stdio navigation and cold-start tests
check that unsaved documents and independent docs bootstrap still work.

## Reviewed opportunities not implemented

- **Scanner indentation-stack reuse:** restoring tree-sitter-yaml scanner state
  frees/reallocates two stacks repeatedly. An experiment eliminated those
  allocations but did not produce a reliable end-to-end improvement in the
  tested workloads; the vendor patch and experimental test were removed.
- **Reusable tree-sitter parser per worker:** may reduce parser setup/allocation
  costs for many tiny files. Profile that workload first; the current dominant
  cost is parsing the contents, not parser construction.
- **Combine reference/fact passes:** root and field expression scans currently
  revisit the DOM separately. This is smaller than parser CPU in the sampled
  workload and needs lexical/position equivalence tests before consolidation.
- **Discovery syscall reduction and batched handoff:** likely useful for trees
  dominated by directories or very small files, but not the primary hotspot in
  these measurements.
- **Persistent on-disk Workspace facts:** can help subsequent starts, not a
  genuinely first build, and adds invalidation/versioning complexity.

For a few very large files, per-file parallelism cannot divide the largest
parse. For slow/network filesystems, CPU improvements alone may not reproduce
these reductions. Benchmark the user's actual Workspace before setting a
stronger latency target.

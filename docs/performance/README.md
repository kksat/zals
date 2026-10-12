# Editor operation benchmarks

`test/benchmark_operations.py` measures real LSP requests over stdio, checks
responses, and generates a Markdown table plus optional JSON with every timing
sample. It uses an isolated, generated Ansible Workspace, not the user's source
files or installed tools.

## Run

```sh
# Default Debug build; print the complete table.
make benchmark-operations

# Save the table and raw data. Parent directories are created automatically.
make benchmark-operations ARGS="--markdown /tmp/zals-perf/debug.md --json /tmp/zals-perf/debug.json"

# ReleaseSafe is the mode used for release artifacts.
make build OPTIMIZE=ReleaseSafe
python3 test/benchmark_operations.py --label ReleaseSafe \
  --markdown /tmp/zals-perf/release-safe.md --json /tmp/zals-perf/release-safe.json

# Smaller smoke run, or a focused performance feedback loop.
python3 test/benchmark_operations.py --files 10 --tasks 2 \
  --sessions 1 --samples 2 --warmup 0
python3 test/benchmark_operations.py --filter "references" --watching on

# Optional local budget: failures retain the generated report/raw samples.
python3 test/benchmark_operations.py --watching on --filter "Role (local)" \
  --max-p95-ms 100 --json /tmp/zals-perf/budget.json
```

`--binary` selects another executable for before/after comparisons; `--label`
records its build mode (the script does not infer optimization flags). Change
`--files` and `--tasks` to scale background load. `--sessions`, `--samples`,
`--warmup`, and `--seed` control measurement repetitions. The default fixture
has 1,027 indexed files: 1,000 background files with 20 tasks each, plus the
small feature-specific fixtures.

## Coverage

There are 89 rows per file-watching mode: 73 measured scenarios and 16 explicit
N/A combinations. The measured requests cover every editor request provider:

- Definition, implementation, references and hover for root Variable reads,
  bindings, Jinja templates, Variable fields, passed Role parameters and fields.
- The same four operations for local Roles, Collection FQCN Roles, Galaxy Roles
  and Roles inside an Installed collection.
- Definition, references and hover for Workspace/Installed collections.
- Definition and references for task-file and vars-file paths.
- Module definition and hover, module-option hover, and keyword hover.
- References both with and without declarations, plus a 20,001-result Variable
  reference search to expose result-size/serialization costs.
- Collection/keyword/module-option completion, completion-item resolve,
  Workspace symbols for Roles/Collections/Modules/Plugins/playbooks/tasks,
  document symbols, semantic tokens, and debug/extract code actions.

No target-specific implementation exists for Collections, task/vars-file paths,
or Modules; Module references and module-option/keyword navigation are also
omitted. Generic fallback completions are not mislabeled as Role or Variable
completion. N/A rows carry no timings, rather than counting null responses as
successful low-latency navigation.

Every measured response is checked against fixture expectations: navigation
paths **and counts**, expected hover excerpts, completion labels, symbol names,
action titles, and nonempty document symbols/tokens. The fan-out search also
checks reference counts per file. Empty or wrong responses fail the run rather
than generate misleading numbers. The actions are listed but never applied.

## Reading the table

- **First ms:** median first observation of that case across fresh sessions.
  The index is ready and source documents are open. This is **not** an isolated
  cold request: earlier cases may have warmed shared resolution/docs services.
- **Warm median / p95 / max:** end-to-end request round-trip times in
  milliseconds, including framing, server work, serialization and client JSON
  decoding. Validation and fixture creation are outside the timer. Warm samples
  are interleaved in seeded shuffled order, not all repetitions of one case in
  one contiguous block. p95 uses nearest rank. Defaults provide 30 warm samples
  per case, enough for a useful local comparison but not production tail-SLO
  claims.
- **Results:** locations/items/top-level document symbols or semantic-token
  count. Hover and resolved-completion objects count as one.
- **File watching enabled:** advertise and acknowledge dynamic watcher
  registration. No files change during sampling. **No file watching:** omit
  that capability, exercising fallback stale-file stats on requests.
- **Index-ready timing:** a separate startup measurement from process launch
  through `ansible/workspaceIndexReady`; samples do not include docs readiness
  or document opening in this number.

The docs catalog and module docs use deterministic Python stand-ins for
`ansible-doc`, `ansible-config`, and `ansible`. This tests zals's real process,
ingestion and provider paths, but is **not** a benchmark of real Ansible import,
plugin discovery, linting or playbook execution. First observations can include
fixture-helper startup. Warm module/doc timings assume the docs are cached in
memory. Validation is disabled; timings are not editor rendering latency,
concurrent-client throughput, cold OS disk latency, or a claim about every real
Workspace.

The JSON report includes build label, platform, binary SHA-256, workload and
shuffle configuration, startup samples, first and warm samples for every row,
result counts, and aggregate statistics. It deliberately excludes response
bodies and temporary fixture paths. Compare the same build mode, workload and
watching mode. Latency budgets are optional local checks, not hardware-independent
CI assertions.

## Local snapshots

The full tables below were generated on Apple Silicon/macOS with Zig 0.15.1,
three sessions per watching mode and 30 warm samples per operation:

- [ReleaseSafe](lsp-operations-release-safe.md)
- [Debug](lsp-operations-debug.md)

With watching enabled, ReleaseSafe warm medians were about 9 ms for Variable
definition/implementation/hover, 1.6 ms for sparse Variable references, 9.7 ms
for Role navigation/references, 5.5 ms for Role hover, 1.2 ms for Collection
references, and 4.4 ms for Collection hover. Completion/resolve, document
symbols, semantic tokens and code actions were generally below 1 ms; Workspace
symbols were about 2.1 ms. Returning 20,001 Variable locations took about 74 ms
(p95 80 ms), showing why result counts matter.

The larger remaining Debug costs are Variable definition/implementation/hover
and Role references (roughly 50–55 ms here), plus high-fan-out references
(roughly 243 ms). These are measurements, not diagnoses or new optimization
claims. Profile the relevant request before changing it.

## Deep-module before/after comparison

The [deep-module regression report](deep-modules-comparison.md) compares
`c0c7ae3` with `a8013c6` using repeated, reversed-order runs of the same
benchmarks. It records a no-watcher document-feature regression attributable
to query-lease stale-file preparation, a separate Debug role-parameter
implementation slowdown, operations that improved, and startup measurements.
The linked CSV includes the complete measured operation matrix.

Benchmark statistics/coverage safeguards run under `make test`. The complete
matrix is exercised with a tiny fixture under `make smoke`, without asserting
wall-clock budgets. For first-start indexing measurements against a real
Workspace, see [the separate index benchmark](../workspace-index-performance.md).

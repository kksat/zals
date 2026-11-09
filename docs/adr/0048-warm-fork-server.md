# ADR-0048: Warm fork-server for ansible-doc and ansible-lint

- **Status:** Accepted
- **Date:** 2025-11-09
- **Supersedes:** —
- **Superseded by:** —

## Context

`zals` shells out to Python tools for module documentation
(ADR-0007) and validation: `ansible-doc` for the version fingerprint, the
catalog bootstrap, and module-doc batches, and `ansible-lint` for per-save
diagnostics. Each call is a fresh process, so it pays interpreter startup and
the tool's imports before doing any work — most of the cost of a call
(measured on the reference machine: ~210 ms for `ansible-doc --version`, of
which the work is milliseconds).

[speedrunner](https://github.com/anthonyGosme/speedrunner) demonstrates the
fix for that class of tools: load the tool once in a daemon, and serve every
call from a `fork()`ed child that runs the tool's console script in-process.
The fork inherits everything the daemon preloaded (copy-on-write), so a call
costs neither startup nor imports. Output stays byte-identical when the
fork-fidelity hazards (state captured at import, atexit cleanups registered
by the daemon) are handled per child.

## Decision

Add a warm runner behind the existing pluggable `Runner` interface
(ADR-0003), serving `ansible-doc` and `ansible-lint`:

- **One daemon per tool** (`src/exec/warm_daemon.py`, embedded in the
  binary), started lazily on the first call with the tool's **own
  interpreter**, taken from the console script's shebang. The daemon imports
  the tool (`ansible.cli.doc`, `ansiblelint.__main__`), runs `--version`
  once in-process to warm runtime state (output discarded), then serves
  requests: one JSON line in (`argv`, optional `env`/`cwd`), one framed
  reply out (exit status, stdout, stderr).
- **Each request is a forked child** that applies env/cwd, redirects fds
  0–2, and runs the console script as `__main__` via `runpy` — the same
  code a native exec runs, minus the startup.
- **Fork-fidelity shims in the child**, before the tool runs: re-derive
  `ansible.constants` from the child's environment (ansible freezes
  env-derived settings, including the per-process local tmp directory, into
  module globals at import; a fork would otherwise reuse the daemon's, and
  the first child's atexit cleanup would delete a directory later children
  still use). The daemon's own cleanup then happens in whichever child runs
  it first.
- **The server's `Runner` is the warm runner** (`exec.Warm`), dispatching on
  `argv[0]`: `ansible-doc` and `ansible-lint` (by name or by a path to that
  same script, so a configured `ansible-lint.path` still serves warm) go to
  their daemons; everything else — `ansible-config`, `ansible-playbook`,
  unknown or non-Python executables — runs natively as before.
- **Never worse than native.** Any failure to serve — daemon died, protocol
  error, tool unresolvable, non-Python shebang — falls back to the native
  `Posix` runner for that call. A caller that finds the daemon busy runs
  natively instead of queueing, so a foreground request (for example a
  hover's synchronous fetch) never waits behind background prefetch batches.
  Cancellation kills the daemon's process group (the daemon `setpgid`s
  itself, so the in-flight tool child dies with it).
- **Opt-out:** `ZALS_WARM=0` disables the daemons entirely.

## Consequences

Measured on the reference machine (`tools/performance/warm_bench.py`,
byte-identical output verified per case):

| Command (as zals issues it) | native | warm | speedup |
| --- | ---: | ---: | ---: |
| `ansible-doc --version` (fingerprint) | 209 ms | 10 ms | x19.9 |
| `ansible-doc -l --json -t module` (catalog) | 324 ms | 107 ms | x3.0 |
| `ansible-doc --json -t module` (batch of 27) | 379 ms | 187 ms | x2.0 |
| `ansible-lint --offline -f codeclimate` (save) | 1548 ms | 1325 ms | x1.2 |
| Cold-cache docs bootstrap, end to end | 2587 ms | 1446 ms | x1.8 |

`ansible-lint` gains least: about 1 s of its runtime is itself spent spawning
`ansible-config`, `ansible`, `ansible-playbook --syntax-check`, and
`ansible-doc` as subprocesses, which a single stdin/stdout daemon cannot
serve (the daemon is busy serving the lint call itself). Serving those would
need speedrunner's socket daemon plus `PATH` shims — deliberately out of
scope for this change.

Trade-offs accepted:

- **One call at a time per daemon.** Concurrent callers fall back to native
  immediately rather than queueing, preserving the status quo for latency
  while background batches keep the warm speedup.
- **Env semantics.** A per-call `env` replaces the child's environment and
  is re-derived through ansible's constants; interpreter-startup variables
  (`PYTHON*`) cannot change between daemon start and a call. `zals` never
  varies those.
- **The daemon is killed, not exited, on cancellation**; on clean shutdown
  it exits via stdin EOF and runs its atexit cleanups. A killed daemon can
  leak its one small `~/.ansible/tmp/ansible-local-*` directory — the same
  leak a killed native tool leaves.
- **The daemon script is embedded, not installed**: it is written to a
  unique file under the zals cache directory at first use and removed at
  shutdown.

Future work, not decided here: a socket-based daemon serving concurrent
callers and the tools that ansible-lint itself spawns (speedrunner's full
architecture), and warm serving for `ansible-config`.

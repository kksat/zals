#!/usr/bin/env python3
"""Benchmark the warm fork-server against native tool execution.

Measures the exact command shapes zals issues — `ansible-doc` version probe,
catalog bootstrap, module-doc batches, and `ansible-lint` validation — natively
(spawn per call) and through the warm daemon from `src/exec/warm_daemon.py`
(one preloaded process, forked per call), started the same way zals starts it
(tool's own interpreter from the console script's shebang, same preloads).

Every case first verifies the warm run is byte-identical to native (stdout,
stderr, exit code) before timing anything. Results are printed as a Markdown
table; `--json` emits them machine-readably.

Run after `make build` (not required for the daemon itself):
    python3 tools/performance/warm_bench.py [--iterations N] [--json]
"""
import argparse
import json
from pathlib import Path
import shlex
import shutil
import statistics
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
DAEMON = ROOT / "src" / "exec" / "warm_daemon.py"

TOOLS = {
    "ansible-doc": "ansible.cli.doc",
    "ansible-lint": "ansiblelint.__main__",
}

BUILTIN_BATCH = [
    "ansible.builtin." + name
    for name in (
        "add_host apt apt_key apt_repository assemble assert command copy debug "
        "fail fetch file get_url group lineinfile meta pause replace service "
        "setup shell script stat template uri user wait_for"
    ).split()
]


def interpreter_for(script: str) -> str:
    """The interpreter a console script runs with (its shebang)."""
    with open(script, "rb") as f:
        shebang = f.readline().decode()
    if not shebang.startswith("#!"):
        raise SystemExit(f"{script}: no shebang")
    tokens = shebang[2:].split()
    if tokens[0] == "/usr/bin/env":
        found = shutil.which(tokens[1])
        if not found:
            raise SystemExit(f"{script}: cannot resolve {tokens[1]!r} on PATH")
        return found
    if not Path(tokens[0]).is_file():
        raise SystemExit(f"{script}: interpreter {tokens[0]!r} not found")
    return tokens[0]


class WarmDaemon:
    """The daemon protocol, as zals speaks it (see warm_daemon.py)."""

    def __init__(self, tool: str):
        self.script = shutil.which(tool)
        if not self.script:
            raise SystemExit(f"{tool} not found on PATH")
        self.interpreter = interpreter_for(self.script)
        started = time.perf_counter()
        self.proc = subprocess.Popen(
            [self.interpreter, str(DAEMON), "--script", self.script,
             "--preload", TOOLS[tool]],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        )
        assert self.proc.stdout.read(1) == b"+", f"{tool} daemon never became ready"
        self.start_seconds = time.perf_counter() - started

    def call(self, argv, env=None, cwd=None):
        request = {"argv": argv}
        if env is not None:
            request["env"] = env
        if cwd is not None:
            request["cwd"] = cwd
        self.proc.stdin.write(json.dumps(request).encode() + b"\n")
        self.proc.stdin.flush()
        header = self.proc.stdout.read(21)
        assert header[:1] == b"R", f"daemon refused: {header[:1]!r}"
        code = struct.unpack("<i", header[1:5])[0]
        nout, nerr = struct.unpack("<QQ", header[5:21])
        return code, self.proc.stdout.read(nout), self.proc.stdout.read(nerr)

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def native_call(argv, env=None, cwd=None):
    result = subprocess.run(argv, capture_output=True, env=env, cwd=cwd)
    return result.returncode, result.stdout, result.stderr


def run_case(name, argv, iterations, warm, env=None, cwd=None):
    """Verify warm == native, then time both. Returns one result row."""
    native = native_call(argv, env, cwd)
    served = warm.call(argv, env, cwd)
    identical = (
        native[0] == served[0]
        and native[1] == served[1]
        and native[2] == served[2]
    )
    if not identical:
        raise SystemExit(
            f"{name}: warm output differs from native\n"
            f"  native: code={native[0]} out={len(native[1])}B err={len(native[2])}B\n"
            f"  warm:   code={served[0]} out={len(served[1])}B err={len(served[2])}B"
        )

    native_times = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        native_call(argv, env, cwd)
        native_times.append(time.perf_counter() - t0)
    warm_times = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        warm.call(argv, env, cwd)
        warm_times.append(time.perf_counter() - t0)

    native_mean = statistics.mean(native_times)
    warm_mean = statistics.mean(warm_times)
    return {
        "name": name,
        "command": " ".join(shlex.quote(a) for a in argv[:6])
        + (" …" if len(argv) > 6 else ""),
        "identical": identical,
        "native_ms": native_mean * 1000,
        "native_min_ms": min(native_times) * 1000,
        "warm_ms": warm_mean * 1000,
        "warm_min_ms": min(warm_times) * 1000,
        "speedup": native_mean / warm_mean,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    doc = WarmDaemon("ansible-doc")
    lint = WarmDaemon("ansible-lint")

    playbook = ROOT / "test" / "fixtures" / "playbook.yml"
    lint_argv = [
        "ansible-lint", "--offline", "--nocolor", "-f", "codeclimate",
        str(playbook),
    ]
    cases = [
        run_case(
            "ansible-doc --version (fingerprint probe)",
            ["ansible-doc", "--version"],
            args.iterations, doc,
        ),
        run_case(
            "ansible-doc -l --json -t module (catalog bootstrap)",
            ["ansible-doc", "-l", "--json", "-t", "module"],
            max(3, args.iterations // 2), doc,
        ),
        run_case(
            f"ansible-doc --json -t module <{len(BUILTIN_BATCH)} modules> (prefetch batch)",
            ["ansible-doc", "--json", "-t", "module"] + BUILTIN_BATCH,
            max(3, args.iterations // 2), doc,
        ),
        run_case(
            "ansible-lint --offline -f codeclimate (validation on save)",
            lint_argv,
            max(3, args.iterations // 2), lint,
        ),
    ]
    doc.close()
    lint.close()

    if args.json:
        json.dump(
            {
                "daemon_start_ms": {
                    "ansible-doc": doc.start_seconds * 1000,
                    "ansible-lint": lint.start_seconds * 1000,
                },
                "cases": cases,
            },
            sys.stdout,
            indent=2,
        )
        print()
        return

    print("| Command (as zals issues it) | native | warm | speedup | identical output |")
    print("| --- | ---: | ---: | ---: | --- |")
    for case in cases:
        print(
            f"| `{case['name']}` | {case['native_ms']:.0f} ms | {case['warm_ms']:.0f} ms "
            f"| x{case['speedup']:.1f} | {'yes' if case['identical'] else 'NO'} |"
        )
    print()
    print(
        f"Daemon cold start (preload + warm `--version`, paid once per session): "
        f"ansible-doc {doc.start_seconds * 1000:.0f} ms, "
        f"ansible-lint {lint.start_seconds * 1000:.0f} ms."
    )


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Measure first-start Workspace indexing over real LSP stdio.

Each sample starts a fresh server with an empty, isolated docs cache and no
Ansible tools. This measures initialize-to-workspaceIndexReady, not docs
prefetch or OS cold-disk latency. Fixture creation is outside the timed region.
Run after building, e.g.:
  python3 test/benchmark_workspace.py --files 1000 --runs 5
  python3 test/benchmark_workspace.py --workspace /path/to/repo --max-ms 1000
"""
import argparse
import os
from pathlib import Path
import statistics
import tempfile
import time

import smoke_cold_start


def measure(root, binary, runs, expected_files):
    samples = []
    counts = []
    smoke_cold_start.BIN = str(binary)
    for _ in range(runs):
        with tempfile.TemporaryDirectory(prefix="zals-bench-cache-") as cache:
            env = dict(os.environ, PATH="", HOME=cache, XDG_CACHE_HOME=cache,
                       ANSIBLE_CONFIG=str(Path(cache) / "ansible.cfg"),
                       ANSIBLE_COLLECTIONS_PATH=cache, ANSIBLE_ROLES_PATH=cache)
            env.pop("VIRTUAL_ENV", None)
            began = time.perf_counter()
            client = smoke_cold_start.Client(str(root), env)
            try:
                client.request("initialize", {
                    "processId": None, "rootUri": root.as_uri(), "capabilities": {}})
                client.notify("initialized", {})
                ready = client.wait_notification("ansible/workspaceIndexReady")
                elapsed = (time.perf_counter() - began) * 1000
                count = ready["filesCount"]
                if expected_files is not None:
                    assert count == expected_files, ready
                counts.append(count)
                samples.append(elapsed)
                print(f"run {len(samples)}: {elapsed:.1f} ms ({count} files)", flush=True)
            finally:
                client.close()
    assert len(set(counts)) == 1, f"unstable indexing result: {counts}"
    median = statistics.median(samples)
    print(f"median: {median:.1f} ms; min: {min(samples):.1f} ms; max: {max(samples):.1f} ms")
    return median


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(smoke_cold_start.BIN))
    parser.add_argument("--workspace", type=Path)
    parser.add_argument("--files", type=int, default=1000)
    parser.add_argument("--tasks", type=int, default=20)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--max-ms", type=float, help="fail when the median exceeds this budget")
    args = parser.parse_args()
    if args.files < 1 or args.tasks < 1 or args.runs < 1:
        parser.error("--files, --tasks and --runs must be positive")
    binary = args.binary.resolve()
    if args.workspace:
        median = measure(args.workspace.resolve(), binary, args.runs, None)
    else:
        with tempfile.TemporaryDirectory(prefix="zals-bench-workspace-") as tmp:
            root = Path(tmp).resolve()
            (root / ".git").mkdir()
            (root / "tasks").mkdir()
            text = ('- name: Show value\n  ansible.builtin.debug:\n'
                    '    msg: "{{ settings.port | default(fallback) }}"\n'
                    '  when: enabled and settings.active\n') * args.tasks
            for i in range(args.files):
                (root / f"tasks/{i:05}.yml").write_text(text)
            median = measure(root, binary, args.runs, args.files)
    if args.max_ms is not None:
        assert median <= args.max_ms, f"indexing median {median:.1f} ms exceeds {args.max_ms:.1f} ms"


if __name__ == "__main__":
    main()

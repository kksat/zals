#!/usr/bin/env python3
"""Same-runner ReleaseSafe regression gate; offline comparison never builds/runs zals."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = Path(__file__).with_name("config.json")
BASELINE_SHA = "c0c7ae384a12a747ca2596f53bbbb121b1c16ba0"
MODE = "ReleaseSafe"
SEEDS = [42, 1042]
THRESHOLDS = {"pooled_relative": .10, "pooled_absolute_ms": .50,
              "round_relative": .05, "round_absolute_ms": .25}
WORKLOADS = {
    "matrix": {"files": 1000, "tasks": 20, "sessions": 3, "samples": 10,
               "warmup": 2, "filter": "", "indexed_files": 1027},
    "semantic-small": {"files": 10, "tasks": 20, "sessions": 3, "samples": 20,
                       "warmup": 2, "filter": "semantic tokens", "indexed_files": 37},
    "semantic-large": {"files": 8000, "tasks": 20, "sessions": 3, "samples": 20,
                       "warmup": 2, "filter": "semantic tokens", "indexed_files": 8027},
}
ROSTER_SHA256 = "2db705922758fce4fbb227a14a91a6f4588ea90990e096604c565bf005e438c2"
IDENTITY = {"watching", "target", "operation", "method", "status"}
STATISTICS = {"first_median_ms", "warm_median_ms", "warm_p95_ms", "warm_max_ms",
              "result_count_min", "result_count_max"}
MEASURED = IDENTITY | STATISTICS | {"first_ms", "warm_ms", "result_counts"}
META_KEYS = {"generated_at", "platform", "machine", "label", "binary", "binary_sha256",
             "files", "tasks", "sessions", "samples", "warmup", "seed", "filter"}


class GateError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise GateError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")


def load_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, f"{path}: duplicate JSON key {key!r}")
            result[key] = value
        return result

    def constant(value):
        raise GateError(f"{path}: invalid nonfinite JSON constant {value}")

    try:
        return json.loads(Path(path).read_text(), object_pairs_hook=pairs, parse_constant=constant)
    except (OSError, ValueError, RecursionError) as exc:
        raise GateError(f"cannot read JSON {path}: {exc}") from exc


def config():
    data = load_json(CONFIG_PATH)
    require(type(data) is dict, "config must be an object")
    for key, expected in {"schema_version": 1, "baseline_sha": BASELINE_SHA, "optimize": MODE,
                          "zig_version": "0.15.1", "ci_python": "3.12", "seeds": SEEDS,
                          "thresholds": THRESHOLDS, "workloads": WORKLOADS}.items():
        require(data.get(key) == expected, f"pinned config {key} changed; explicit policy review required")
    roster = data.get("matrix_scenarios")
    encoded = json.dumps(roster, sort_keys=True, separators=(",", ":")).encode()
    require(hashlib.sha256(encoded).hexdigest() == ROSTER_SHA256,
            "pinned complete scenario/count contract changed; explicit policy review required")
    require(type(data.get("harness_sha256")) is dict and
            set(data["harness_sha256"]) == {"test/benchmark_operations.py", "test/smoke_cold_start.py",
                                           "test/smoke_workspace.py"}, "incomplete harness digest contract")
    for path, expected in data["harness_sha256"].items():
        require(digest(ROOT / path) == expected, f"current harness/helper changed: {path}")
    return data


def number(value, name):
    try:
        valid = type(value) in (int, float) and math.isfinite(value) and value > 0
    except OverflowError:
        valid = False
    require(valid, f"{name}: expected finite positive number, got {value!r}")


def samples(values, count, name):
    require(type(values) is list and len(values) == count, f"{name}: expected {count} samples")
    for value in values:
        number(value, name)


def p95(values):
    return sorted(values)[math.ceil(len(values) * .95) - 1]


def summarize(row):
    return {"first_median_ms": statistics.median(row["first_ms"]),
            "warm_median_ms": statistics.median(row["warm_ms"]),
            "warm_p95_ms": p95(row["warm_ms"]), "warm_max_ms": max(row["warm_ms"]),
            "result_count_min": min(row["result_counts"]), "result_count_max": max(row["result_counts"])}


def row_key(row):
    return (row["watching"], row["target"], row["operation"], row["method"], row["status"])


def contract(cfg, workload):
    scenarios = cfg["matrix_scenarios"]
    if workload != "matrix":
        scenarios = [s for s in scenarios if s["operation"] == "semantic tokens"]
    return {row_key(dict(s, watching=mode)): s for mode in (True, False) for s in scenarios}


def validate_report(report, cfg, workload, seed, name, binary_sha=None):
    """Validate the whole report, including N/A and startup, before comparing any rows."""
    require(type(report) is dict and set(report) == {"metadata", "startup", "rows"},
            f"{name}: incomplete report schema")
    meta, policy = report["metadata"], cfg["workloads"][workload]
    require(type(meta) is dict and set(meta) == META_KEYS, f"{name}: invalid metadata schema")
    for key in ("generated_at", "platform", "machine", "label", "binary", "binary_sha256"):
        require(type(meta[key]) is str and meta[key], f"{name}: missing metadata {key}")
    try:
        require(datetime.fromisoformat(meta["generated_at"]).tzinfo is not None,
                f"{name}: timestamp missing timezone")
    except ValueError as exc:
        raise GateError(f"{name}: invalid timestamp") from exc
    require(re.fullmatch(r"[0-9a-f]{64}", meta["binary_sha256"]), f"{name}: invalid binary digest")
    require(re.search(r"\bReleaseSafe\b", meta["label"]), f"{name}: not a ReleaseSafe report")
    if binary_sha is not None:
        require(meta["label"] == MODE and meta["binary_sha256"] == binary_sha,
                f"{name}: live binary digest/mode mismatch")
    for key in ("files", "tasks", "sessions", "samples", "warmup"):
        require(type(meta[key]) is int and meta[key] == policy[key], f"{name}: workload {key} mismatch")
    require(type(meta["seed"]) is int and meta["seed"] == seed, f"{name}: shuffle seed mismatch")
    require(meta["filter"] == policy["filter"], f"{name}: filter/workload mismatch")
    startup = report["startup"]
    require(type(startup) is list and len(startup) == 2, f"{name}: startup must cover both watcher modes")
    startup_modes = set()
    for item in startup:
        require(type(item) is dict and set(item) == {"watching", "indexed_files", "samples_ms"},
                f"{name}: invalid startup schema")
        require(type(item["watching"]) is bool and item["watching"] not in startup_modes,
                f"{name}: invalid/duplicate startup watcher mode")
        startup_modes.add(item["watching"])
        require(type(item["indexed_files"]) is int and item["indexed_files"] == policy["indexed_files"],
                f"{name}: indexed-file workload mismatch")
        samples(item["samples_ms"], policy["sessions"], f"{name}: startup")
    require(type(report["rows"]) is list, f"{name}: rows must be an array")
    expected, actual = contract(cfg, workload), {}
    for row in report["rows"]:
        require(type(row) is dict and IDENTITY <= set(row), f"{name}: row identity missing")
        require(type(row["watching"]) is bool and
                all(type(row[key]) is str for key in IDENTITY - {"watching"}), f"{name}: invalid row identity")
        key = row_key(row)
        require(key in expected, f"{name}: unexpected scenario {key}")
        require(key not in actual, f"{name}: duplicate scenario {key}")
        actual[key] = row
        require(set(row) == (MEASURED if row["status"] == "measured" else IDENTITY),
                f"{name}: missing/extra fields (including N/A data) for {key}")
        if row["status"] == "N/A":
            continue
        label = f"{name}: {key}"
        sessions, warm = policy["sessions"], policy["sessions"] * policy["samples"]
        samples(row["first_ms"], sessions, label + " first")
        samples(row["warm_ms"], warm, label + " warm")
        counts = row["result_counts"]
        require(type(counts) is list and len(counts) == sessions + warm, label + ": result count samples mismatch")
        require(all(type(v) is int and v == expected[key]["results"] for v in counts),
                label + ": checked result workload changed")
        for stat, value in summarize(row).items():
            number(row[stat], label + " " + stat)
            if stat.startswith("result_count"):
                require(type(row[stat]) is int, label + ": count summary must be integer")
            require(math.isclose(row[stat], value, rel_tol=1e-9, abs_tol=1e-9),
                    label + f": {stat} disagrees with raw samples")
    missing = set(expected) - set(actual)
    require(not missing, f"{name}: missing scenarios {sorted(missing)}")
    return actual


def validate_pair(baseline, current, cfg, workload, binary_shas=None):
    require(len(baseline) == len(current) == len(SEEDS), "exactly two reports per endpoint required")
    indexed = {}
    # Finish validating every report before making even the first timing decision.
    identity = None
    for endpoint, reports in (("baseline", baseline), ("current", current)):
        seen = set()
        endpoint_digest = None
        for report in reports:
            require(type(report) is dict and type(report.get("metadata")) is dict,
                    f"{endpoint}: metadata missing")
            seed = report["metadata"].get("seed")
            require(type(seed) is int and seed in SEEDS and seed not in seen,
                    f"{endpoint}: missing/unexpected/duplicate round seed")
            seen.add(seed)
            rows = validate_report(report, cfg, workload, seed, f"{endpoint}/{workload}/{seed}",
                                   binary_shas[endpoint] if binary_shas else None)
            meta = report["metadata"]
            host = (meta["platform"], meta["machine"])
            require(identity in (None, host), "platform/machine mismatch between endpoints/rounds")
            identity = host
            require(endpoint_digest in (None, meta["binary_sha256"]), f"{endpoint}: binary changed between rounds")
            endpoint_digest = meta["binary_sha256"]
            indexed[endpoint, seed] = rows
    return indexed


def delta(before, after):
    return {"absolute_ms": after - before, "relative": (after - before) / before}


def exceeds(change, relative, absolute):
    return change["relative"] > relative and change["absolute_ms"] > absolute


def compare_pair(baseline, current, cfg, workload, binary_shas=None):
    indexed = validate_pair(baseline, current, cfg, workload, binary_shas)
    comparisons = []
    for key in contract(cfg, workload):
        if key[-1] == "N/A":
            continue
        totals, rounds = {}, []
        for endpoint in ("baseline", "current"):
            pooled = {field: sum((indexed[endpoint, seed][key][field] for seed in SEEDS), [])
                      for field in ("first_ms", "warm_ms", "result_counts")}
            totals[endpoint] = dict(summarize(pooled), warm_samples=len(pooled["warm_ms"]),
                                   first_samples=len(pooled["first_ms"]))
        for seed in SEEDS:
            before = statistics.median(indexed["baseline", seed][key]["warm_ms"])
            after = statistics.median(indexed["current", seed][key]["warm_ms"])
            rounds.append(dict(seed=seed, baseline_median_ms=before, current_median_ms=after,
                               **delta(before, after)))
        change = delta(totals["baseline"]["warm_median_ms"], totals["current"]["warm_median_ms"])
        policy = cfg["thresholds"]
        candidate = exceeds(change, policy["pooled_relative"], policy["pooled_absolute_ms"])
        confirmed = candidate and all(exceeds(r, policy["round_relative"], policy["round_absolute_ms"]) for r in rounds)
        comparisons.append(dict(workload=workload, watching=key[0], target=key[1], operation=key[2],
                                method=key[3], **totals, **change, rounds=rounds,
                                status="regression" if confirmed else "unconfirmed" if candidate else "within-policy"))
    startup = []
    for mode in (True, False):
        values = {}
        for endpoint, reports in (("baseline", baseline), ("current", current)):
            data = [v for report in reports for item in report["startup"] if item["watching"] == mode
                    for v in item["samples_ms"]]
            values[endpoint] = {"median_ms": statistics.median(data), "p95_ms": p95(data), "samples": len(data)}
        startup.append(dict(workload=workload, watching=mode, **values))
    return comparisons, startup


def finish(output, cfg, rows, startup, provenance):
    regressions = [r for r in rows if r["status"] == "regression"]
    unconfirmed = [r for r in rows if r["status"] == "unconfirmed"]
    result = {"schema_version": 1, "status": "fail" if regressions else "pass",
              "regressions": len(regressions), "unconfirmed_candidates": len(unconfirmed),
              "thresholds": cfg["thresholds"], "provenance": provenance, "comparisons": rows, "startup": startup}
    write_json(output / "comparison.json", result)
    lines = ["# Optimized performance regression gate", "",
             f"**{result['status'].upper()}: {len(regressions)} confirmed regressions; "
             f"{len(unconfirmed)} UNCONFIRMED candidates; {len(rows)} measured scenarios.**", "",
             f"Baseline: `{BASELINE_SHA}`; both endpoints `{MODE}`. Evidence: **{provenance['kind']}**.",
             "Pooled warm median must increase >10% AND >0.50 ms; both reversed rounds must increase >5% AND >0.25 ms.",
             "First responses, nearest-rank p95/max and startup are reporting-only, not SLOs or significance tests.", ""]
    if provenance["kind"] == "offline replay":
        lines += ["**Replay does not attest build flags, Git revision, harness execution or a shared physical runner.**",
                  "Only the selected workload is compared; this is not the complete live CI suite.", ""]
    for title, items in (("Confirmed regressions", regressions),
                         ("UNCONFIRMED candidates — inspect jitter/order effects", unconfirmed)):
        lines += [f"## {title}", ""]
        if not items:
            lines += ["None.", ""]
        for row in items:
            changes = "; ".join(f"seed {r['seed']}: {100*r['relative']:+.1f}% / {r['absolute_ms']:+.3f} ms" for r in row["rounds"])
            lines.append(f"- **{row['workload']} / watching={row['watching']} / {row['target']} / {row['operation']}**: "
                         f"{100*row['relative']:+.1f}% / {row['absolute_ms']:+.3f} ms; {changes}.")
        lines.append("")
    lines += ["## Complete measured comparison", "", "N/A scenarios are validated but are not timings. All times in ms.", "",
              "| Workload / watching | Target / operation | Median baseline/current | Delta % / ms | p95 baseline/current | First baseline/current | Warm / first samples each | Status |",
              "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |"]
    for row in rows:
        before, after = row["baseline"], row["current"]
        lines.append(f"| {row['workload']} / {row['watching']} | {row['target']} / {row['operation']} | "
                     f"{before['warm_median_ms']:.3f} / {after['warm_median_ms']:.3f} | "
                     f"{row['relative']*100:+.1f}% / {row['absolute_ms']:+.3f} | "
                     f"{before['warm_p95_ms']:.3f} / {after['warm_p95_ms']:.3f} | "
                     f"{before['first_median_ms']:.3f} / {after['first_median_ms']:.3f} | "
                     f"{before['warm_samples']} / {before['first_samples']} | {row['status']} |")
    lines += ["", "## Startup (reporting only)", ""]
    for item in startup:
        lines.append(f"- {item['workload']} / watching={item['watching']}: baseline/current medians "
                     f"{item['baseline']['median_ms']:.3f} / {item['current']['median_ms']:.3f} ms; "
                     f"p95 {item['baseline']['p95_ms']:.3f} / {item['current']['p95_ms']:.3f}; "
                     f"{item['baseline']['samples']} samples each.")
    if set(r["workload"] for r in rows) == set(WORKLOADS):
        lines += ["", "## Discovery-only semantic-token scaling", "", "Small/large indexed files: 37 / 8027; each endpoint compared within each workload.", ""]
        for mode in (True, False):
            small = next(r for r in rows if r["workload"] == "semantic-small" and r["watching"] == mode)
            large = next(r for r in rows if r["workload"] == "semantic-large" and r["watching"] == mode)
            for endpoint in ("baseline", "current"):
                a, b = small[endpoint]["warm_median_ms"], large[endpoint]["warm_median_ms"]
                lines.append(f"- {endpoint}, watching={mode}: {a:.3f} → {b:.3f} ms ({b-a:+.3f} ms).")
    (output / "summary.md").write_text("\n".join(lines) + "\n")
    print(lines[2])
    return 1 if regressions else 0


def inspect_tree(path, expected_sha=None):
    def git(*args):
        return subprocess.run(["git", "-C", str(path), *args], check=True,
                              capture_output=True, text=True, timeout=10).stdout.strip()
    sha = git("rev-parse", "HEAD")
    require(expected_sha is None or sha == expected_sha, "baseline tree is not the pinned pre-refactor SHA")
    require(not git("status", "--porcelain", "--untracked-files=no"), f"tracked checkout is dirty: {path}")
    return sha


def execute(command, cwd, log, timeout, deadline, manifest, manifest_path):
    remaining = min(timeout, deadline - time.monotonic())
    require(remaining > 0, "aggregate 30-minute gate deadline exceeded")
    entry = {"argv": command, "cwd": str(cwd), "log": log.name, "timeout_seconds": remaining, "status": "running"}
    manifest["commands"].append(entry)
    write_json(manifest_path, manifest)
    print("+ " + shlex.join(command), flush=True)
    with log.open("w") as stream:
        proc = subprocess.Popen(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = proc.wait(timeout=remaining)
        except subprocess.TimeoutExpired as exc:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass  # The process/group can exit between wait and cleanup.
            proc.wait()
            entry["status"] = "timeout"
            write_json(manifest_path, manifest)
            raise GateError(f"command timed out; see {log}") from exc
    if code != 0:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass  # The failed parent may already have cleaned up all children.
    entry.update(status="success" if code == 0 else "failed", exit_code=code)
    write_json(manifest_path, manifest)
    require(code == 0, f"command failed with exit {code}; see {log}")


def live_run(args, cfg, output):
    require(sys.flags.optimize == 0 and os.environ.get("PYTHONOPTIMIZE", "0") in ("", "0"),
            "Python assertions must be enabled for checked benchmark responses")
    baseline = args.baseline_tree.resolve()
    require(baseline != ROOT and baseline not in ROOT.parents and ROOT not in baseline.parents,
            "baseline must be a separate checkout, not nested in current checkout")
    require(not output.is_relative_to(ROOT) and not output.is_relative_to(baseline),
            "live result directory must be outside both source checkouts")
    shas = {"baseline": inspect_tree(baseline, BASELINE_SHA), "current": inspect_tree(ROOT)}
    manifest = {"schema_version": 1, "status": "running", "baseline_sha": BASELINE_SHA,
                "optimize": MODE, "endpoint_shas": shas, "config_sha256": digest(CONFIG_PATH),
                "harness_sha256": cfg["harness_sha256"], "platform": platform.platform(),
                "machine": platform.machine(), "python": sys.version, "commands": [], "reports": []}
    manifest_path = output / "manifest.json"
    write_json(manifest_path, manifest)
    deadline = time.monotonic() + 1800

    def command(argv, tree, name, timeout=600):
        execute(argv, tree, output / (name + ".log"), timeout, deadline, manifest, manifest_path)

    command(["make", "-s", "zig", "ARGS=version"], ROOT, "zig-version", 30)
    require((output / "zig-version.log").read_text().strip() == cfg["zig_version"], "wrong Zig toolchain")
    manifest["zig_version"] = cfg["zig_version"]
    binaries, binary_shas = {}, {}
    (output / "binaries").mkdir()
    for endpoint, tree in (("baseline", baseline), ("current", ROOT)):
        command(["make", "build", "OPTIMIZE=" + MODE], tree, endpoint + "-build")
        binary = output / "binaries" / (endpoint + "-zals")
        shutil.copy2(tree / "zig-out/bin/zals", binary)
        binaries[endpoint], binary_shas[endpoint] = binary, digest(binary)
    manifest["binary_sha256"] = binary_shas
    reports = {workload: {endpoint: [] for endpoint in ("baseline", "current")} for workload in WORKLOADS}
    for round_number, seed in enumerate(SEEDS, 1):
        order = ("baseline", "current") if round_number == 1 else ("current", "baseline")
        for workload, policy in cfg["workloads"].items():
            for endpoint in order:
                name = f"{workload}-{endpoint}-r{round_number}"
                report_path = output / (name + ".json")
                argv = [sys.executable, str(ROOT / "test/benchmark_operations.py"),
                        "--binary", str(binaries[endpoint]), "--label", MODE, "--watching", "both", "--seed", str(seed)]
                for key in ("files", "tasks", "sessions", "samples", "warmup", "filter"):
                    argv.extend(["--" + key, str(policy[key])])
                argv.extend(["--json", str(report_path), "--markdown", str(output / (name + ".md"))])
                command(argv, ROOT, name, 600 if workload == "matrix" else 180)
                report = load_json(report_path)
                validate_report(report, cfg, workload, seed, name, binary_shas[endpoint])
                require((report["metadata"]["platform"], report["metadata"]["machine"]) ==
                        (manifest["platform"], manifest["machine"]), "report host differs from live runner")
                reports[workload][endpoint].append(report)
                manifest["reports"].append({"endpoint": endpoint, "workload": workload, "seed": seed,
                                            "path": report_path.name, "sha256": digest(report_path)})
                write_json(manifest_path, manifest)
    # Detect source/config/binary changes during the run before attesting completion.
    require(config() == cfg, "configuration changed during live run")
    for endpoint, tree in (("baseline", baseline), ("current", ROOT)):
        require(inspect_tree(tree, shas[endpoint]) == shas[endpoint], "checkout changed during live run")
        require(digest(binaries[endpoint]) == binary_shas[endpoint], "saved executable changed during live run")
    for entry in manifest["reports"]:
        require(digest(output / entry["path"]) == entry["sha256"], "saved raw report changed during live run")
    require(time.monotonic() < deadline, "aggregate 30-minute gate deadline exceeded")
    # Validate all workload pairs before any timing comparison.
    for workload, data in reports.items():
        validate_pair(data["baseline"], data["current"], cfg, workload, binary_shas)
    rows, startup = [], []
    for workload, data in reports.items():
        compared, started = compare_pair(data["baseline"], data["current"], cfg, workload, binary_shas)
        rows.extend(compared)
        startup.extend(started)
    manifest["status"] = "complete"
    write_json(manifest_path, manifest)
    code = finish(output, cfg, rows, startup, {"kind": "attested same-runner live suite", "manifest": "manifest.json",
                                             "endpoint_shas": shas, "binary_sha256": binary_shas})
    manifest["gate_status"] = "fail" if code else "pass"
    write_json(manifest_path, manifest)
    return code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="build and measure the complete pinned suite on this runner")
    run.add_argument("--baseline-tree", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    replay = commands.add_parser("compare", help="strict two-round raw-data replay; no build/server execution")
    replay.add_argument("--workload", choices=tuple(WORKLOADS), required=True)
    replay.add_argument("--baseline", action="append", type=Path, required=True)
    replay.add_argument("--current", action="append", type=Path, required=True)
    replay.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    output = args.output.resolve()
    try:
        require(not output.exists() or not any(output.iterdir()), "output must be a new/empty directory (no stale results)")
        output.mkdir(parents=True, exist_ok=True)
    except (GateError, OSError) as exc:
        print(f"gate error: {exc}", file=sys.stderr)
        return 2
    (output / "summary.md").write_text("# Performance gate incomplete\n\n**FAIL: run did not complete; no passing result.**\n")
    try:
        cfg = config()
        if args.command == "run":
            return live_run(args, cfg, output)
        before, after = [load_json(p) for p in args.baseline], [load_json(p) for p in args.current]
        rows, startup = compare_pair(before, after, cfg, args.workload)
        return finish(output, cfg, rows, startup, {"kind": "offline replay", "workload": args.workload,
                                                  "inputs": {"baseline": [str(p.resolve()) for p in args.baseline],
                                                             "current": [str(p.resolve()) for p in args.current]},
                                                  "binary_sha256": {"baseline": before[0]["metadata"]["binary_sha256"],
                                                                    "current": after[0]["metadata"]["binary_sha256"]}})
    except (GateError, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as exc:
        message = f"{type(exc).__name__}: {exc}"
        write_json(output / "error.json", {"status": "fail", "error": message})
        manifest_path = output / "manifest.json"
        if manifest_path.exists():
            manifest = load_json(manifest_path)
            manifest.update(status="failed", gate_status="fail", error=message)
            write_json(manifest_path, manifest)
        # JSON quoting keeps arbitrary malformed input text out of summary markup.
        (output / "summary.md").write_text("# Performance gate failed\n\n**FAIL: invalid/incomplete evidence or command failure.**\n\n"
                                            "```json\n" + json.dumps({"error": message}) + "\n```\n\nSee retained logs/raw data.\n")
        print(message, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

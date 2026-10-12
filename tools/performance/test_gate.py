"""Offline guard coverage. Never imports fixtures, builds or launches a zals server."""
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import gate


def reports(cfg, workload="matrix"):
    result = []
    policy = cfg["workloads"][workload]
    for seed in gate.SEEDS:
        rows = []
        for key, scenario in gate.contract(cfg, workload).items():
            row = dict(zip(("watching", "target", "operation", "method", "status"), key))
            if key[-1] == "measured":
                value = .2 if key[2] in ("semantic tokens", "completion", "completion resolve") else 10.
                row.update(first_ms=[value * 2] * policy["sessions"],
                           warm_ms=[value] * (policy["sessions"] * policy["samples"]),
                           result_counts=[scenario["results"]] * (policy["sessions"] * (policy["samples"] + 1)))
                row.update(gate.summarize(row))
            rows.append(row)
        result.append({"metadata": {"generated_at": datetime.now(timezone.utc).isoformat(),
                                    "platform": "offline-test", "machine": "test", "label": "ReleaseSafe",
                                    "binary": "/not-executed", "binary_sha256": "a" * 64,
                                    **{k: policy[k] for k in ("files", "tasks", "sessions", "samples", "warmup", "filter")},
                                    "seed": seed},
                       "startup": [{"watching": mode, "indexed_files": policy["indexed_files"],
                                    "samples_ms": [100.] * policy["sessions"]} for mode in (True, False)],
                       "rows": rows})
    return result


def change_samples(data, relative=0., absolute=0., rows=None):
    changed = copy.deepcopy(data)
    for report in changed:
        for row in report["rows"]:
            if row["status"] != "measured" or (rows is not None and not rows(row)):
                continue
            for field in ("first_ms", "warm_ms"):
                row[field] = [v * (1 + relative) + absolute for v in row[field]]
            row.update(gate.summarize(row))
    return changed


class GuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cfg = gate.config()

    def setUp(self):
        self.before = reports(self.cfg)
        self.after = copy.deepcopy(self.before)

    def compare(self):
        return gate.compare_pair(self.before, self.after, self.cfg, "matrix")[0]

    def rejects(self, mutation, message=None):
        mutation(self.after)
        with self.assertRaises(gate.GateError) as caught:
            self.compare()
        if message:
            self.assertIn(message, str(caught.exception))

    def test_full_contract_has_146_measured_and_32_na_rows(self):
        self.assertEqual(len(self.before[0]["rows"]), 178)
        result = self.compare()
        self.assertEqual(len(result), 146)
        self.assertEqual(sum(r["status"] != "within-policy" for r in result), 0)
        self.assertTrue(all(r["baseline"]["warm_samples"] == 60 and
                            r["baseline"]["first_samples"] == 6 for r in result))

    def test_baseline_self_and_bounded_noise_pass(self):
        self.after = change_samples(self.before, .05, .10)
        self.assertTrue(all(r["status"] == "within-policy" for r in self.compare()))

    def test_focused_both_watchers_and_pooled_counts(self):
        for workload in ("semantic-small", "semantic-large"):
            data = reports(self.cfg, workload)
            compared, startup = gate.compare_pair(data, data, self.cfg, workload)
            self.assertEqual(len(compared), 2)
            self.assertEqual({r["watching"] for r in compared}, {True, False})
            self.assertTrue(all(r["baseline"]["warm_samples"] == 120 for r in compared))
            self.assertEqual(len(startup), 2)

    def test_confirmed_fast_path_regression_rejects(self):
        self.after = change_samples(self.before, absolute=1., rows=lambda r: r["operation"] == "semantic tokens" and not r["watching"])
        bad = [r for r in self.compare() if r["status"] == "regression"]
        self.assertEqual(len(bad), 1)
        self.assertFalse(bad[0]["watching"])

    def test_12_percent_navigation_regression_is_not_lost(self):
        self.after = change_samples(self.before, .12, rows=lambda r: r["operation"] == "definition")
        self.assertTrue(all(r["status"] == "regression" for r in self.compare() if r["operation"] == "definition"))

    def test_absolute_and_relative_thresholds_are_both_required(self):
        self.after = change_samples(self.before, .09)
        self.assertTrue(all(r["status"] == "within-policy" for r in self.compare()))
        self.after = change_samples(self.before, absolute=.49, rows=lambda r: r["operation"] == "semantic tokens")
        self.assertTrue(all(r["status"] == "within-policy" for r in self.compare()))
        self.assertFalse(gate.exceeds({"relative": .1, "absolute_ms": 1}, .1, .5))
        self.assertFalse(gate.exceeds({"relative": 1, "absolute_ms": .5}, .1, .5))

    def test_both_rounds_must_confirm_and_unconfirmed_is_prominent(self):
        self.after[0] = change_samples([self.before[0]], absolute=4.)[0]
        result = self.compare()
        self.assertTrue(any(r["status"] == "unconfirmed" for r in result))
        self.assertFalse(any(r["status"] == "regression" for r in result))
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)
            code = gate.finish(output, self.cfg, result, [], {"kind": "offline replay"})
            self.assertEqual(code, 0)
            summary = (output / "summary.md").read_text()
            self.assertIn("UNCONFIRMED candidates — inspect jitter/order effects", summary)
            self.assertIn("seed 1042", summary)

    def test_first_and_p95_and_startup_are_not_warm_median_gate(self):
        for report in self.after:
            for row in report["rows"]:
                if row["status"] == "measured":
                    row["first_ms"] = [500.] * 3
                    row["warm_ms"][-1] = 1000.
                    row.update(gate.summarize(row))
            for startup in report["startup"]:
                startup["samples_ms"] = [1000.] * 3
        self.assertTrue(all(r["status"] == "within-policy" for r in self.compare()))
        self.assertTrue(all(r["current"]["first_median_ms"] == 500. for r in self.compare()))

    def test_nearest_rank_percentile(self):
        self.assertEqual(gate.p95(list(range(1, 31))), 29)

    def test_empty_missing_duplicate_unexpected_and_na_scenarios_rejected(self):
        mutations = [lambda d: d[0].update(rows=[]),
                     lambda d: d[0]["rows"].pop(),
                     lambda d: d[0]["rows"].append(copy.deepcopy(d[0]["rows"][0])),
                     lambda d: d[0]["rows"][0].update(target="Other"),
                     lambda d: d[0]["rows"][0].update(method="different"),
                     lambda d: next(r for r in d[0]["rows"] if r["status"] == "N/A").update(warm_ms=[]),
                     lambda d: d[0]["rows"][0].update(status="N/A"),
                     lambda d: d[0]["rows"][0].update(watching=1)]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.after = copy.deepcopy(self.before)
                self.rejects(mutation)

    def test_missing_watcher_rejected_for_matrix_and_focused(self):
        self.rejects(lambda d: d[0].update(rows=[r for r in d[0]["rows"] if r["watching"]]))
        data = reports(self.cfg, "semantic-large")
        data[0]["startup"].pop()
        with self.assertRaises(gate.GateError):
            gate.compare_pair(data, reports(self.cfg, "semantic-large"), self.cfg, "semantic-large")

    def test_workload_round_mode_platform_binary_metadata_rejected(self):
        mutations = [lambda d: d.pop(), lambda d: d.append(copy.deepcopy(d[0])),
                     lambda d: d[1]["metadata"].update(seed=42),
                     lambda d: d[0]["metadata"].update(seed=True),
                     lambda d: d[0]["metadata"].update(files=999),
                     lambda d: d[0]["metadata"].update(sessions=True),
                     lambda d: d[0]["metadata"].update(samples=9),
                     lambda d: d[0]["metadata"].update(tasks=19),
                     lambda d: d[0]["metadata"].update(warmup=0),
                     lambda d: d[0]["metadata"].update(filter="semantic tokens"),
                     lambda d: d[0]["metadata"].update(platform="another runner"),
                     lambda d: d[0]["metadata"].update(machine="another machine"),
                     lambda d: d[0]["metadata"].update(label="Debug"),
                     lambda d: d[0]["metadata"].update(binary_sha256="missing"),
                     lambda d: d[1]["metadata"].update(binary_sha256="b" * 64),
                     lambda d: d[0]["metadata"].pop("binary_sha256")]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.after = copy.deepcopy(self.before)
                self.rejects(mutation)

    def test_nonfinite_nonpositive_boolean_samples_and_wrong_lengths_rejected(self):
        for field in ("warm_ms", "first_ms"):
            for bad in (float("nan"), float("inf"), 10 ** 400, 0, -1, True, "1"):
                with self.subTest(field=field, bad=bad):
                    self.after = copy.deepcopy(self.before)
                    self.rejects(lambda d: d[0]["rows"][0][field].__setitem__(0, bad))
            self.after = copy.deepcopy(self.before)
            self.rejects(lambda d: d[0]["rows"][0].update({field: []}))
        self.after = copy.deepcopy(self.before)
        self.rejects(lambda d: d[0]["rows"][0]["warm_ms"].pop())

    def test_result_counts_and_redundant_statistics_rejected(self):
        for mutation in [lambda d: d[0]["rows"][0]["result_counts"].pop(),
                         lambda d: d[0]["rows"][0]["result_counts"].__setitem__(0, 0),
                         lambda d: d[0]["rows"][0]["result_counts"].__setitem__(0, 3),
                         lambda d: d[0]["rows"][0]["result_counts"].__setitem__(0, 4.),
                         lambda d: d[0]["rows"][0].update(warm_median_ms=9.),
                         lambda d: d[0]["rows"][0].update(warm_p95_ms=float("inf")),
                         lambda d: d[0]["rows"][0].update(result_count_min=4.),
                         lambda d: next(r for r in d[0]["rows"] if r["target"] == "Variable (high fan-out)").update(result_counts=[20000] * 33)]:
            self.after = copy.deepcopy(self.before)
            self.rejects(mutation)

    def test_invalid_baseline_or_last_round_prevents_any_timing_decision(self):
        self.before[0]["rows"][0]["warm_ms"] = []
        with patch.object(gate, "exceeds") as decide, self.assertRaises(gate.GateError):
            self.compare()
        decide.assert_not_called()
        self.before = reports(self.cfg)
        self.after[-1]["rows"] = []
        with patch.object(gate, "exceeds") as decide, self.assertRaises(gate.GateError):
            self.compare()
        decide.assert_not_called()

    def test_pin_mode_workload_roster_threshold_changes_require_policy_review(self):
        for mutation in [lambda c: c.update(baseline_sha="f" * 40),
                         lambda c: c.update(optimize="Debug"),
                         lambda c: c["workloads"]["matrix"].update(files=2),
                         lambda c: c["matrix_scenarios"].pop(),
                         lambda c: c["thresholds"].update(pooled_relative=.20),
                         lambda c: c["harness_sha256"].update({"test/benchmark_operations.py": "0" * 64})]:
            altered = copy.deepcopy(self.cfg)
            mutation(altered)
            with patch.object(gate, "load_json", return_value=altered), self.assertRaises(gate.GateError):
                gate.config()

    def test_startup_workload_samples_and_duplicate_mode_rejected(self):
        for mutation in [lambda d: d[0]["startup"][0].update(indexed_files=1000),
                         lambda d: d[0]["startup"][0].update(samples_ms=[1]),
                         lambda d: d[0]["startup"][0]["samples_ms"].__setitem__(0, float("nan")),
                         lambda d: d[0]["startup"][1].update(watching=True)]:
            self.after = copy.deepcopy(self.before)
            self.rejects(mutation)

    def test_live_binary_digest_and_exact_label_checked(self):
        with self.assertRaises(gate.GateError):
            gate.validate_report(self.before[0], self.cfg, "matrix", 42, "live", "b" * 64)
        self.before[0]["metadata"]["label"] = "before ReleaseSafe round 1"
        gate.validate_report(self.before[0], self.cfg, "matrix", 42, "archive")
        with self.assertRaises(gate.GateError):
            gate.validate_report(self.before[0], self.cfg, "matrix", 42, "live", "a" * 64)

    def test_nonstandard_json_duplicate_keys_and_missing_file_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "input.json"
            for text in ('{"x":1,"x":2}', '{"x": NaN}', '{"x": Infinity}', '{"x":'):
                path.write_text(text)
                with self.assertRaises(gate.GateError):
                    gate.load_json(path)
            with self.assertRaises(gate.GateError):
                gate.load_json(Path(tmp) / "missing.json")

    def test_cli_exit_codes_and_retained_failure_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            paths = []
            for i, report in enumerate(self.before):
                path = root / f"before-{i}.json"
                gate.write_json(path, report)
                paths.append(path)
            argv = ["compare", "--workload", "matrix"]
            for path in paths:
                argv += ["--baseline", str(path), "--current", str(path)]
            self.assertEqual(gate.main(argv + ["--output", str(root / "self")]), 0)
            self.assertEqual(gate.main(argv + ["--output", str(root / "self")]), 2)  # stale evidence refused
            self.assertEqual(gate.main(["compare", "--workload", "matrix", "--baseline", str(paths[0]),
                                        "--current", str(paths[0]), "--output", str(root / "incomplete")]), 2)
            self.assertTrue((root / "incomplete/error.json").is_file())
            changed = change_samples(self.before, .2, 1.)
            for path, report in zip(paths, changed):
                gate.write_json(path, report)
            bad_argv = ["compare", "--workload", "matrix"]
            for path in paths:
                bad_argv += ["--current", str(path)]
            # Restore distinct unchanged baseline files.
            for i, report in enumerate(self.before):
                path = root / f"original-{i}.json"
                gate.write_json(path, report)
                bad_argv += ["--baseline", str(path)]
            self.assertEqual(gate.main(bad_argv + ["--output", str(root / "regression")]), 1)
            self.assertTrue((root / "regression/comparison.json").is_file())
            self.assertIn("FAIL", (root / "regression/summary.md").read_text())

    def test_timeout_kills_process_group_and_fails_not_passes(self):
        # Mock the process boundary: this never starts a binary or server.
        with tempfile.TemporaryDirectory() as tmp, patch.object(gate.subprocess, "Popen") as spawn, \
                patch.object(gate.os, "killpg") as kill:
            root = Path(tmp)
            proc = spawn.return_value
            proc.pid = 12345
            proc.wait.side_effect = [subprocess.TimeoutExpired("fake", 1), -9]
            manifest = {"commands": []}
            with self.assertRaisesRegex(gate.GateError, "timed out"):
                gate.execute(["not-executed"], root, root / "command.log", 1,
                             gate.time.monotonic() + 10, manifest, root / "manifest.json")
            kill.assert_called_once_with(12345, gate.signal.SIGKILL)
            self.assertEqual(manifest["commands"][0]["status"], "timeout")
            self.assertTrue((root / "command.log").is_file())

    def test_failed_command_fails_and_cleans_any_surviving_children(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(gate.subprocess, "Popen") as spawn, \
                patch.object(gate.os, "killpg") as kill:
            root = Path(tmp)
            proc = spawn.return_value
            proc.pid = 12345
            proc.wait.return_value = 7
            manifest = {"commands": []}
            with self.assertRaisesRegex(gate.GateError, "exit 7"):
                gate.execute(["not-executed"], root, root / "failed.log", 1,
                             gate.time.monotonic() + 10, manifest, root / "manifest.json")
            self.assertEqual(manifest["commands"][0]["status"], "failed")
            kill.assert_called_once_with(12345, gate.signal.SIGKILL)

    def test_exhausted_deadline_does_not_launch_command(self):
        with patch.object(gate.subprocess, "Popen") as spawn:
            with self.assertRaisesRegex(gate.GateError, "deadline"):
                gate.execute(["not-executed"], gate.ROOT, Path("unused.log"), 1,
                             gate.time.monotonic() - 1, {"commands": []}, Path("unused.json"))
            spawn.assert_not_called()

    def test_live_refuses_disabled_harness_assertions_before_execution(self):
        with patch.dict(gate.os.environ, {"PYTHONOPTIMIZE": "1"}), \
                patch.object(gate, "inspect_tree") as inspect, self.assertRaisesRegex(gate.GateError, "assertions"):
            gate.live_run(None, self.cfg, None)
        inspect.assert_not_called()

    def test_mocked_complete_live_suite_order_and_fail_closed_final_evidence(self):
        # All process/build/copy boundaries are mocked; no repo build artifact is touched.
        for case in ("complete", "missing-large-endpoint", "changed-config"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                baseline, output = root / "baseline", root / "output"
                baseline.mkdir()
                output.mkdir()
                args = SimpleNamespace(baseline_tree=baseline)
                order = []

                def inspect(tree, expected_sha=None):
                    return gate.BASELINE_SHA if tree == baseline else "1" * 40

                def copy_binary(source, destination):
                    destination.write_bytes(destination.name.encode())

                def execute(argv, cwd, log, timeout, deadline, manifest, manifest_path):
                    manifest["commands"].append({"argv": argv, "status": "success"})
                    log.write_text("0.15.1" if "ARGS=version" in argv else "mocked command, no server")
                    if "--json" not in argv:
                        gate.write_json(manifest_path, manifest)
                        return
                    path = Path(argv[argv.index("--json") + 1])
                    workload = next(w for w in gate.WORKLOADS if path.name.startswith(w + "-"))
                    endpoint = "baseline" if "-baseline-" in path.name else "current"
                    seed = int(argv[argv.index("--seed") + 1])
                    order.append((seed, workload, endpoint))
                    report = reports(self.cfg, workload)[gate.SEEDS.index(seed)]
                    report["metadata"].update(platform=gate.platform.platform(), machine=gate.platform.machine(),
                                              binary_sha256=gate.digest(Path(argv[argv.index("--binary") + 1])))
                    if case == "missing-large-endpoint" and (seed, workload, endpoint) == (1042, "semantic-large", "baseline"):
                        report["rows"] = []
                    gate.write_json(path, report)
                    gate.write_json(manifest_path, manifest)

                final_cfg = copy.deepcopy(self.cfg)
                if case == "changed-config":
                    final_cfg["harness_sha256"]["test/benchmark_operations.py"] = "0" * 64
                with patch.object(gate, "inspect_tree", side_effect=inspect), \
                        patch.object(gate.shutil, "copy2", side_effect=copy_binary), \
                        patch.object(gate, "execute", side_effect=execute), \
                        patch.object(gate, "config", return_value=final_cfg):
                    if case == "complete":
                        self.assertEqual(gate.live_run(args, self.cfg, output), 0)
                        result = gate.load_json(output / "comparison.json")
                        self.assertEqual(len(result["comparisons"]), 150)
                        manifest = gate.load_json(output / "manifest.json")
                        self.assertEqual(manifest["status"], "complete")
                        self.assertEqual(len(manifest["reports"]), 12)
                    else:
                        with self.assertRaises(gate.GateError), patch.object(gate, "exceeds") as decide:
                            gate.live_run(args, self.cfg, output)
                        decide.assert_not_called()
                        self.assertFalse((output / "comparison.json").exists())
                self.assertEqual(order, [(seed, workload, endpoint) for seed in gate.SEEDS
                                         for workload in gate.WORKLOADS
                                         for endpoint in (("baseline", "current") if seed == 42 else ("current", "baseline"))])

    def test_guard_selfchecks_are_explicit_in_dedicated_workflow(self):
        workflow = (gate.ROOT / ".github/workflows/performance.yml").read_text()
        self.assertIn("python3 -m unittest discover -s tools/performance -p test_gate.py", workflow)
        self.assertNotIn("continue-on-error", workflow)
        self.assertNotIn("pull_request_target", workflow)
        self.assertEqual(workflow.count("if: always()"), 2)


if __name__ == "__main__":
    unittest.main()

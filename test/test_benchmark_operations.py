"""Unit checks for benchmark statistics, coverage and false-fast safeguards."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import benchmark_operations as bench


class BenchmarkTests(unittest.TestCase):
    @staticmethod
    def crashing_client(root):
        popen = subprocess.Popen
        script = "import os; os.read(0, 1); os.write(2, b'intentional crash\\n'); os._exit(7)"
        with patch.object(bench.smoke_cold_start.subprocess, "Popen",
                          side_effect=lambda argv, **kwargs: popen([sys.executable, "-c", script], **kwargs)):
            return bench.Client(root, None)

    def test_server_crash_retains_status_stderr_and_primary_eof_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            client = self.crashing_client(tmp)
            with self.assertRaisesRegex(RuntimeError, "server exit=7; stderr tail: intentional crash"):
                try:
                    client.request("initialize", {})
                finally:
                    client.close()
            self.assertEqual(client.proc.returncode, 7)
            self.assertFalse(client.reader.is_alive())
            self.assertTrue(client.stderr.closed)

    def test_cleanup_does_not_mask_an_existing_response_assertion(self):
        with tempfile.TemporaryDirectory() as tmp:
            client = self.crashing_client(tmp)
            client.proc.stdin.write(b"x")
            client.proc.stdin.flush()
            client.proc.wait(timeout=2)
            with self.assertRaisesRegex(AssertionError, "primary wrong response"):
                try:
                    raise AssertionError("primary wrong response")
                finally:
                    client.close()
            self.assertTrue(client.stderr.closed)

    def test_shutdown_failure_without_a_primary_error_still_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            client = self.crashing_client(tmp)
            with self.assertRaisesRegex(RuntimeError, "server exit=7; stderr tail: intentional crash"):
                client.close()
            self.assertEqual(client.proc.returncode, 7)
            self.assertFalse(client.reader.is_alive())

    def test_percentile_uses_nearest_rank(self):
        self.assertEqual(bench.percentile([5], .95), 5)
        self.assertEqual(bench.percentile(list(range(1, 31)), .95), 29)
        self.assertEqual(bench.percentile([4, 1, 3, 2], .5), 2)

    def test_location_validator_rejects_empty_duplicate_and_wrong_results(self):
        root = Path("/fixture")
        check = bench.location_check(root, ["a.yml", "b.yml"])
        def location(name):
            return {"uri": (root / name).as_uri(), "range": {
                "start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}}
        check([location("b.yml"), location("a.yml")])
        for bad in (None, [], [location("a.yml")], [location("a.yml")] * 2,
                    [location("a.yml"), location("other.yml")]):
            with self.subTest(bad=bad), self.assertRaises(AssertionError):
                check(bad)

    def test_unsupported_operations_have_no_timing_statistics(self):
        cases = [bench.Case("Role", "hover", "textDocument/hover", {}, lambda _: None),
                 bench.Case("Collection", "implementation", "textDocument/implementation", {})]
        data = {0: {"first_ms": [2, 4, 3], "warm_ms": [1, 5, 2], "result_counts": [1, 1, 1]}}
        rows = bench.report_rows(cases, data, True)
        self.assertEqual(rows[0]["first_median_ms"], 3)
        self.assertEqual(rows[0]["warm_median_ms"], 2)
        self.assertEqual(rows[0]["warm_p95_ms"], 5)
        self.assertEqual(rows[1]["status"], "N/A")
        self.assertNotIn("warm_median_ms", rows[1])
        json.dumps(rows)  # Raw reports must remain JSON-serializable.

    def test_fixture_and_cases_reject_false_fast_empty_responses(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            sources = bench.fixture(root, 2, 3)
            cases = bench.cases_for(root, sources, 2, 3)
            for case in cases:
                if case.check is None:
                    continue
                with self.subTest(target=case.target, operation=case.operation):
                    with self.assertRaises((AssertionError, KeyError, TypeError)):
                        case.check(None)
            for target in ("Role (local)", "Role (Galaxy)", "Role (collection FQCN)",
                           "Role (installed collection)", "Variable (role read)",
                           "Variable field (read)", "Role parameter", "Role parameter field"):
                self.assertEqual({case.operation for case in cases if case.target == target and case.check},
                                 {"definition", "implementation", "references", "hover"})
            for case in cases:
                if "textDocument" in case.params:
                    uri = case.params["textDocument"]["uri"]
                    self.assertIn(uri, {(root / path).as_uri() for path in sources})
            self.assertEqual(sources["roles/app/meta/argument_specs.yml"].count("settings:"), 1)
            output = subprocess.run([sys.executable, str(root / "bin/ansible-doc"), "-l", "--json"],
                                    check=True, capture_output=True, text=True)
            self.assertEqual(set(json.loads(output.stdout)), {"ansible.builtin.debug", "acme.web.probe"})

    def test_fanout_validator_checks_per_file_counts(self):
        root = Path("/fixture")
        # Sources are needed only to locate the anchored query documents.
        with tempfile.TemporaryDirectory() as tmp:
            sources = bench.fixture(Path(tmp), 2, 2)
        case = next(case for case in bench.cases_for(root, sources, 2, 2)
                    if case.target == "Variable (high fan-out)")
        valid = [{"uri": (root / "playbooks/fanout.yml").as_uri()}]
        valid += [{"uri": (root / f"background/{i:05}.yml").as_uri()} for i in range(2) for _ in range(2)]
        case.check(valid)
        bad = list(valid)
        bad[-1] = valid[1]  # Same total and distinct URI count, wrong per-file counts.
        with self.assertRaises(AssertionError):
            case.check(bad)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Compare zals's YAML parsing against ansible-core's, document by document.

ansible-core is the authority for how Ansible YAML is parsed (ADR-0053). This
harness runs every `test/fixtures/yaml-parity/*.yaml` document through the
exact APIs ansible-core uses internally — `ansible.parsing.dataloader.
DataLoader` for parsing and `ansible.module_utils.common.text.converters.
jsonify` for lowering to JSON — and through zals's production parse path via
`zals --yaml-lower`. The two results must be equal, including the int/float
distinction; only `NaN` compares via `math.isnan`.

The harness also (re)writes each sibling `*.json` expectation from the
ansible-core result, so the fast Zig-side parity test in `src/yaml/jsonify.zig`
runs without a Python environment. Expectations are skipped for values that
strict JSON cannot express (`Infinity` / `NaN`); the comparison itself still
covers them.

Run it through the Makefile (`make yaml-parity`) so the ansible-core version
comes from the frozen `test/parity/.venv` (see `test/parity/requirements.txt`).
Documents ansible-core itself rejects (syntax errors, unknown tags) are out of
scope by construction: there is nothing to compare against, and zals is
deliberately error-tolerant.
"""

from __future__ import annotations

import json
import math
import os
import pathlib
import subprocess
import sys

os.environ.setdefault("ANSIBLE_DEPRECATION_WARNINGS", "False")
os.environ.setdefault("ANSIBLE_DUPLICATE_YAML_KEY_WARNINGS", "False")

from ansible.module_utils.common.text.converters import jsonify
from ansible.parsing.dataloader import DataLoader

CORPUS = pathlib.Path(__file__).resolve().parent.parent / "fixtures" / "yaml-parity"
ZALS_BIN = pathlib.Path(__file__).resolve().parent.parent.parent / "zig-out/bin/zals"


def strict_json(text: str) -> bool:
    def reject(constant):
        raise ValueError(constant)

    try:
        json.loads(text, parse_constant=reject)
    except ValueError:
        return False
    return True


def values_equal(expected, actual, path: str, errors: list[str]) -> None:
    where = path or "$"
    if isinstance(expected, bool) or isinstance(actual, bool):
        if type(expected) is not type(actual) or expected != actual:
            errors.append(f"{where}: expected {expected!r}, found {actual!r}")
        return
    if expected is None or actual is None:
        if expected is not actual:
            errors.append(f"{where}: expected {expected!r}, found {actual!r}")
        return
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        if type(expected) is not type(actual):
            errors.append(f"{where}: expected {type(expected).__name__} {expected!r}, "
                          f"found {type(actual).__name__} {actual!r}")
        elif isinstance(expected, float) and math.isnan(expected) and math.isnan(actual):
            pass
        elif expected != actual:
            errors.append(f"{where}: expected {expected!r}, found {actual!r}")
        return
    if isinstance(expected, str) and isinstance(actual, str):
        if expected != actual:
            errors.append(f"{where}: expected {expected!r}, found {actual!r}")
        return
    if isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            errors.append(f"{where}: expected {len(expected)} items, found {len(actual)}")
            return
        for i, (e, a) in enumerate(zip(expected, actual)):
            values_equal(e, a, f"{where}[{i}]", errors)
        return
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(set(expected) - set(actual)):
            errors.append(f"{where}: missing key {key!r}")
        for key in sorted(set(actual) - set(expected)):
            errors.append(f"{where}: unexpected key {key!r}")
        for key in sorted(set(expected) & set(actual)):
            values_equal(expected[key], actual[key], f"{where}[{key!r}]", errors)
        return
    errors.append(f"{where}: expected {expected!r}, found {actual!r}")


def main() -> int:
    if not ZALS_BIN.exists():
        raise SystemExit(f"missing zals binary: {ZALS_BIN} (run `make build`)")
    if not CORPUS.is_dir():
        raise SystemExit(f"missing corpus directory: {CORPUS}")

    loader = DataLoader()
    compared = 0
    failures: list[str] = []
    for case in sorted(CORPUS.glob("*.yaml")):
        text = case.read_text(encoding="utf-8")
        try:
            ansible = loader.load(text)
        except Exception as error:
            raise SystemExit(f"{case.name}: ansible-core cannot parse this corpus "
                             f"document, remove it: {error}")
        expected_text = jsonify(ansible)

        expectation = case.with_suffix(".json")
        if strict_json(expected_text):
            expectation.write_text(expected_text + "\n", encoding="utf-8")

        run = subprocess.run(
            [str(ZALS_BIN), "--yaml-lower", str(case)],
            capture_output=True,
            text=True,
            check=False,
        )
        if run.returncode != 0:
            failures.append(f"{case.name}: zals exited {run.returncode}: {run.stderr.strip()}")
            continue
        try:
            actual = json.loads(run.stdout)
        except ValueError as error:
            failures.append(f"{case.name}: zals output is not JSON: {error}\n{run.stdout}")
            continue
        errors: list[str] = []
        values_equal(json.loads(expected_text), actual, "", errors)
        if errors:
            failures.append(f"{case.name}:\n  " + "\n  ".join(errors))
        compared += 1

    if not compared:
        raise SystemExit(f"no *.yaml cases found under {CORPUS}")
    for failure in failures:
        print(failure, file=sys.stderr)
    print(f"yaml parity: {compared - len(failures)}/{compared} documents match ansible-core")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Generate the YAML-to-JSON parity corpus for zals.

ansible-core is the authority for how Ansible YAML is parsed. This script
runs each `test/fixtures/yaml-parity/*.yaml` document through the exact APIs
ansible-core uses internally — `ansible.parsing.dataloader.DataLoader` for
parsing and `ansible.module_utils.common.text.converters.jsonify` for
lowering to JSON — and records the result as the sibling `*.json`
expectation. The Zig test in `src/yaml/jsonify.zig` then asserts that zals
lowers the same documents identically. See ADR-0053 for the contract and the
corpus scope rules, which this script enforces so the Zig side stays simple:

- one YAML document per file (a `DataLoader.load` requirement)
- string keys only (zals keys are always strings)
- no `.inf` / `.nan` and no full timestamps: neither has a faithful JSON
  representation (`jsonify` emits `Infinity`; datetimes change format)

Usage:
    python3 test/parity/generate_yaml_fixtures.py

Requires ansible-core (any Python environment with `ansible` importable),
for example:
    uv venv --python 3.12 .venv && uv pip install ansible-core
"""

from __future__ import annotations

import json
import pathlib
import sys

from ansible.module_utils.common.text.converters import jsonify
from ansible.parsing.dataloader import DataLoader

CORPUS = pathlib.Path(__file__).resolve().parent.parent / "fixtures" / "yaml-parity"


def check_keys(node, path: str) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if not isinstance(key, str):
                raise SystemExit(f"{path}: non-string key {key!r} not allowed in the corpus")
            check_keys(value, path)
    elif isinstance(node, list):
        for item in node:
            check_keys(item, path)


def main() -> int:
    if not CORPUS.is_dir():
        raise SystemExit(f"missing corpus directory: {CORPUS}")

    loader = DataLoader()
    generated = 0
    for case in sorted(CORPUS.glob("*.yaml")):
        text = case.read_text(encoding="utf-8")
        data = loader.load(text)
        check_keys(data, case.name)
        expected = jsonify(data)
        if "Infinity" in expected or "NaN" in expected:
            raise SystemExit(f"{case.name}: non-JSON-representable value; exclude from corpus")
        json.loads(expected)
        (case.with_suffix(".json")).write_text(expected + "\n", encoding="utf-8")
        print(f"generated {case.stem}.json")
        generated += 1

    if generated == 0:
        raise SystemExit(f"no *.yaml cases found under {CORPUS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Comment-count ratchet (ADR-0048): inline comments are banned in this repo.

Counts comment lines per file and compares them against a committed budget
(``comment_ratchet.json``). The budget may only shrink. Run with
``--update-ratchet`` after deleting comments to tighten it.
"""

import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
RATCHET_PATH = Path(__file__).with_name("comment_ratchet.json")

HASH_MARKER = "#"
SLASH_MARKER = "//"

DIR_SUFFIXES = {
    "src": {".zig"},
    "test": {".zig", ".py"},
    "tools": {".py", ".mjs"},
    "python": {".py"},
    "editors/vscode/src": {".ts"},
    "editors/vscode/test": {".ts"},
}
EXPLICIT_FILES = {
    "build.zig": ".zig",
    "Makefile": "make",
    ".githooks/commit-msg": "sh",
    ".githooks/pre-commit": "sh",
}
EXCLUDED_DIRS = {"test/fixtures", "zig-out", ".zig-cache", "node_modules"}

SUFFIX_MARKER = {
    ".zig": SLASH_MARKER,
    ".ts": SLASH_MARKER,
    ".mjs": SLASH_MARKER,
    ".py": HASH_MARKER,
    "make": HASH_MARKER,
    "sh": HASH_MARKER,
}

FUNCTIONAL_MARKERS = ("x-release-please-version",)


def marker_for(rel: str, suffix: str) -> str:
    if suffix in SUFFIX_MARKER:
        return SUFFIX_MARKER[suffix]
    return SLASH_MARKER if rel.endswith(".zig") else HASH_MARKER


def candidate_files():
    files = []
    for rel_dir, suffixes in DIR_SUFFIXES.items():
        base = ROOT / rel_dir
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(ROOT).as_posix()
            if any(rel.startswith(excluded) for excluded in EXCLUDED_DIRS):
                continue
            if path.suffix in suffixes:
                files.append((rel, path.suffix))
    for rel, suffix in sorted(EXPLICIT_FILES.items()):
        path = ROOT / rel
        if path.is_file():
            files.append((rel, suffix))
    return files


def trailing_marker_index(line: str, marker: str):
    quote = None
    escaped = False
    for i in range(1, len(line)):
        ch = line[i]
        if escaped:
            escaped = False
            continue
        if quote and ch == "\\":
            escaped = True
            continue
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in ("'", '"'):
            quote = ch
            continue
        if ch == marker[0] and line[i : i + len(marker)] == marker:
            if line[i - 1].isspace() and line[i - 2 : i] != ":":
                return i
    return None


def is_functional(line: str) -> bool:
    return any(marker in line for marker in FUNCTIONAL_MARKERS)


def comment_lines(text: str, marker: str):
    found = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if lineno == 1 and line.startswith("#!"):
            continue
        if is_functional(line):
            continue
        stripped = line.lstrip()
        if stripped.startswith(marker):
            found.append(lineno)
            continue
        idx = trailing_marker_index(line, marker)
        if idx is not None and line[:idx].strip():
            found.append(lineno)
    return found


def scan():
    results = {}
    for rel, suffix in candidate_files():
        text = (ROOT / rel).read_text(encoding="utf-8")
        lines = comment_lines(text, marker_for(rel, suffix))
        if lines:
            results[rel] = lines
    return results


def load_ratchet():
    if not RATCHET_PATH.is_file():
        return {}
    return json.loads(RATCHET_PATH.read_text(encoding="utf-8"))["files"]


def write_ratchet(counts):
    payload = {"files": dict(sorted(counts.items()))}
    RATCHET_PATH.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def check(budget):
    scanned = {rel: len(lines) for rel, lines in scan().items()}
    violations = []
    for rel, count in sorted(scanned.items()):
        allowed = budget.get(rel)
        if allowed is None:
            violations.append(f"{rel}: {count} comments (not in ratchet; delete them)")
        elif count > allowed:
            violations.append(f"{rel}: {count} comments, budget {allowed} (delete {count - allowed})")
    stale = [rel for rel, allowed in budget.items() if scanned.get(rel, 0) < allowed]
    if violations:
        print("comment ratchet violated:")
        for violation in violations:
            print(f"  {violation}")
        return 1
    if stale:
        print("comment ratchet is stale (budgets exceed reality); tighten it:")
        for rel in sorted(stale):
            print(f"  {rel}: budget {budget[rel]}, actual {scanned.get(rel, 0)}")
        print("run: python3 tools/lint/comments.py --update-ratchet")
        return 1
    total = sum(scanned.values())
    print(f"comment ratchet ok: {total} comments across {len(scanned)} files")
    return 0


def update(force):
    budget = load_ratchet()
    scanned = {rel: len(lines) for rel, lines in scan().items()}
    if not force:
        for rel, count in scanned.items():
            if rel not in budget:
                print(f"refusing to add {rel} ({count} comments) to the ratchet; delete the comments")
                return 1
            if count > budget[rel]:
                print(f"refusing to raise {rel} from {budget[rel]} to {count}; delete the comments")
                return 1
    write_ratchet(scanned)
    print(f"ratchet updated: {sum(scanned.values())} comments across {len(scanned)} files")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="print every counted comment")
    parser.add_argument("--update-ratchet", action="store_true", help="tighten the budget to current counts")
    parser.add_argument("--force", action="store_true", help="allow raising the budget (initial baseline only)")
    args = parser.parse_args(argv)
    if args.list:
        for rel, lines in sorted(scan().items()):
            for lineno in lines:
                print(f"{rel}:{lineno}")
        return 0
    if args.update_ratchet:
        return update(args.force)
    return check(load_ratchet())


if __name__ == "__main__":
    sys.exit(main())

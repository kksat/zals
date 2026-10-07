#!/usr/bin/env python3
"""Generate checked LSP latency tables for navigation and other editor operations.

Run after `make build`. Default: three fresh sessions in each file-watching
mode, 1,000 background files, 20 tasks/file, and ten warm samples per case.
All sources/cache/tools are isolated fixtures; no real Ansible is required.
"""
import argparse
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import statistics
import sys
import tempfile
import time

import smoke_cold_start
from smoke_workspace import FILES, frame, pos


class Client(smoke_cold_start.Client):
    """Reuse the smoke client's asynchronous reader; acknowledge watcher setup."""
    registered = False

    def read(self, timeout=30):
        deadline = time.monotonic() + timeout
        while True:
            message = super().read(max(0, deadline - time.monotonic()))
            if "method" in message and "id" in message:
                if message["method"] != "client/registerCapability":
                    raise AssertionError(f"unexpected server request: {message['method']}")
                self.registered = True
                self.proc.stdin.write(frame({"jsonrpc": "2.0", "id": message["id"], "result": None}))
                self.proc.stdin.flush()
                continue
            return message

    def request(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        self.proc.stdin.write(frame({"jsonrpc": "2.0", "id": request_id,
                                    "method": method, "params": params}))
        self.proc.stdin.flush()
        deadline = time.monotonic() + 30
        while True:
            message = self.read(max(0, deadline - time.monotonic()))
            if message.get("id") == request_id:
                assert "error" not in message, f"{method}: {message.get('error')}"
                return message["result"]


def fixture(root, files, tasks):
    sources = dict(FILES)
    sources["roles/db/defaults/main.yml"] += "template_value: template hello\n"
    sources["roles/db/templates/config.j2"] = "Hello {{ template_value }}\n"
    sources["roles/app/defaults/main.yml"] = "app_port: 8000\nsettings:\n  listen: 8080\n"
    sources["roles/app/meta/argument_specs.yml"] = (
        "argument_specs:\n  main:\n    options:\n      app_port:\n"
        "        type: int\n        description: App port\n"
        "      settings:\n        type: dict\n        options:\n"
        "          listen:\n            type: int\n            description: Listening socket\n")
    sources["playbooks/params.yml"] = (
        "- hosts: all\n  roles:\n    - role: app\n      app_port: 5433\n"
        "      settings:\n        listen: 9090\n")
    sources["roles/app/tasks/main.yml"] += (
        '- name: Show config\n  debug:\n    msg: "{{ settings.listen }} / {{ app_port }}"\n')
    installed = ".venv/lib/python3.12/site-packages/ansible_collections/community/general"
    sources[f"{installed}/README.md"] = "# Installed community.general fixture\n"
    sources[f"{installed}/roles/agent/tasks/main.yml"] = "- debug: msg=installed\n"
    sources[f"{installed}/roles/agent/README.md"] = "# Installed agent role\n"
    sources["playbooks/installed.yml"] = "- hosts: all\n  roles: [community.general.agent]\n"
    sources["collections/ansible_collections/acme/web/plugins/modules/probe.py"] = "# module source fixture\n"
    sources["collections/ansible_collections/acme/web/plugins/filter/tools.py"] = "# filter source fixture\n"
    sources["bin/debug.py"] = "# builtin module source fixture\n"
    sources["playbooks/modules.yml"] = (
        "- hosts: all\n  tasks:\n    - ansible.builtin.debug:\n        msg: hello\n"
        "    - acme.web.probe:\n        payload: hello\n")
    sources["playbooks/fanout.yml"] = "- hosts: all\n  vars:\n    fanout: hello\n"
    unrelated = ('- name: Background task\n  debug:\n    msg: "{{ fanout }}"\n'
                 '  when: background_enabled\n') * tasks
    for i in range(files):
        sources[f"background/{i:05}.yml"] = unrelated
    for name, text in sources.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    # Exercise real subprocess/doc ingestion seams without depending on a
    # machine's Ansible installation. These timings are NOT ansible-doc timings.
    docs = {}
    for name, filename in (
        ("ansible.builtin.debug", "bin/debug.py"),
        ("acme.web.probe", "collections/ansible_collections/acme/web/plugins/modules/probe.py"),
    ):
        docs[name] = {"doc": {
            "filename": str(root / filename), "short_description": "Benchmark module documentation",
            "description": ["Benchmark module documentation"],
            "options": {key: {"description": [f"Benchmark {key} option"], "type": "str"}
                        for key in ("msg", "var", "verbosity", "payload")},
        }}
    (root / "bin/docs.json").write_text(json.dumps(docs))
    helper = f'''#!{sys.executable}
import json
from pathlib import Path
import sys
if Path(sys.argv[0]).name == "ansible-doc":
    docs = json.loads(Path(__file__).with_name("docs.json").read_text())
    if "--version" in sys.argv:
        print("ansible-doc [core benchmark-fixture]")
    elif "-l" in sys.argv:
        print(json.dumps({{name: value["doc"]["short_description"] for name, value in docs.items()}}))
    else:
        print(json.dumps({{name: value for name, value in docs.items() if name in sys.argv[1:]}}))
'''
    for command in ("ansible-doc", "ansible-config", "ansible"):
        path = root / "bin" / command
        path.write_text(helper)
        path.chmod(0o755)
    return sources


@dataclass
class Case:
    target: str
    operation: str
    method: str
    params: dict
    check: object = None


def locations(result):
    return [] if result is None else result if isinstance(result, list) else [result]


def location_check(root, paths):
    expected = sorted((root / name).as_uri() for name in paths)

    def check(result):
        actual = locations(result)
        actual_paths = sorted(item["uri"] for item in actual)
        assert actual_paths == expected, f"wrong location paths/count: expected {expected}, got {actual_paths}"
        for item in actual:
            for edge in ("start", "end"):
                assert item["range"][edge]["line"] >= 0
                assert item["range"][edge]["character"] >= 0
    return check


def hover_check(excerpt):
    def check(result):
        assert result and excerpt in result["contents"]["value"], f"missing hover excerpt: {excerpt}"
    return check


def item_check(key, expected):
    def check(result):
        items = result.get("items", []) if isinstance(result, dict) else result or []
        assert any(item.get(key) == expected for item in items), f"missing {key}: {expected}"
    return check


def cases_for(root, sources, files, tasks):
    cases = []

    def at(path, needle, offset=0, nth=0):
        return {"textDocument": {"uri": (root / path).as_uri()},
                "position": pos(sources[path], needle, nth=nth, offset=offset)}

    def navigation(target, position, definition, implementation, references, hover):
        for operation, expected in (("definition", definition), ("implementation", implementation),
                                    ("references", references), ("hover", hover)):
            params = dict(position)
            if operation == "references":
                params["context"] = {"includeDeclaration": True}
            check = None if expected is None else hover_check(expected) if operation == "hover" else location_check(root, expected)
            cases.append(Case(target, operation, f"textDocument/{operation}", params, check))

    navigation("Variable (role read)", at("roles/db/tasks/main.yml", "{{ port", 3),
               ["playbooks/vars/prod.yml", "roles/db/defaults/main.yml", "roles/db/meta/argument_specs.yml", "roles/web/defaults/main.yml"],
               ["playbooks/vars/prod.yml", "roles/db/defaults/main.yml", "roles/web/defaults/main.yml"],
               ["playbooks/vars/prod.yml", "roles/db/defaults/main.yml", "roles/db/meta/argument_specs.yml", "roles/web/defaults/main.yml", "roles/db/tasks/main.yml"],
               "**Active:** `8080`")
    navigation("Variable (binding)", at("roles/db/defaults/main.yml", "port"),
               ["playbooks/vars/prod.yml", "roles/db/defaults/main.yml", "roles/db/meta/argument_specs.yml", "roles/web/defaults/main.yml"],
               ["playbooks/vars/prod.yml", "roles/db/defaults/main.yml", "roles/web/defaults/main.yml"],
               ["playbooks/vars/prod.yml", "roles/db/defaults/main.yml", "roles/db/meta/argument_specs.yml", "roles/web/defaults/main.yml", "roles/db/tasks/main.yml"],
               "**Variable**")
    navigation("Variable (Jinja template)", at("roles/db/templates/config.j2", "template_value"),
               ["roles/db/defaults/main.yml"], ["roles/db/defaults/main.yml"],
               ["roles/db/defaults/main.yml", "roles/db/templates/config.j2"], "template hello")
    field_paths = ["roles/app/defaults/main.yml", "roles/app/meta/argument_specs.yml", "playbooks/params.yml"]
    navigation("Variable field (read)", at("roles/app/tasks/main.yml", "settings.listen", len("settings.")),
               field_paths, ["roles/app/defaults/main.yml", "playbooks/params.yml"],
               field_paths + ["roles/app/tasks/main.yml"], "**Variable field**")
    navigation("Role parameter", at("playbooks/params.yml", "app_port"),
               ["roles/app/meta/argument_specs.yml"], ["roles/app/defaults/main.yml"],
               ["roles/app/meta/argument_specs.yml", "roles/app/defaults/main.yml", "playbooks/params.yml", "roles/app/tasks/main.yml"], "App port")
    navigation("Role parameter field", at("playbooks/params.yml", "listen"),
               ["roles/app/meta/argument_specs.yml"], ["roles/app/defaults/main.yml"],
               field_paths + ["roles/app/tasks/main.yml"], "Listening socket")
    navigation("Role (local)", at("playbooks/site.yml", "- db", 2),
               ["roles/db/meta/argument_specs.yml"], ["roles/db/tasks/main.yml"],
               ["playbooks/site.yml", "playbooks/other.yml"], "Listening port")
    collection = "collections/ansible_collections/acme/web"
    navigation("Role (collection FQCN)", at("playbooks/collections.yml", "nginx"),
               [f"{collection}/roles/nginx/tasks/main.yml"], [f"{collection}/roles/nginx/tasks/main.yml"],
               ["playbooks/collections.yml"], "nginx")
    navigation("Role (Galaxy)", at("playbooks/other.yml", "geerlingguy.nginx"),
               ["galaxy_roles/geerlingguy.nginx/tasks/main.yml"], ["galaxy_roles/geerlingguy.nginx/tasks/main.yml"],
               ["playbooks/other.yml", "roles/requirements.yml"], "nginx from Galaxy")
    installed = ".venv/lib/python3.12/site-packages/ansible_collections/community/general"
    navigation("Role (installed collection)", at("playbooks/installed.yml", "agent"),
               [f"{installed}/roles/agent/tasks/main.yml"], [f"{installed}/roles/agent/tasks/main.yml"],
               ["playbooks/installed.yml"], "Installed agent role")
    navigation("Collection (Workspace)", at("playbooks/collections.yml", "acme.web.nginx"),
               [f"{collection}/galaxy.yml"], None,
               ["collections/requirements.yml", "playbooks/collections.yml", "playbooks/modules.yml"], "acme.web collection")
    navigation("Collection (installed)", at("playbooks/collections.yml", "community.general"),
               [f"{installed}/MANIFEST.json"], None,
               ["collections/requirements.yml", "playbooks/collections.yml", "playbooks/installed.yml"], "Installed community.general fixture")
    navigation("Task file", at("roles/app/tasks/main.yml", "install.yml"),
               ["roles/app/tasks/install.yml"], None,
               ["roles/app/tasks/main.yml", "roles/app/handlers/main.yml"], None)
    navigation("Vars file", at("playbooks/site.yml", "vars/prod.yml"),
               ["playbooks/vars/prod.yml"], None, ["playbooks/site.yml"], None)
    navigation("Module (builtin fixture docs)", at("playbooks/modules.yml", "ansible.builtin.debug", len("ansible.builtin.")),
               ["bin/debug.py"], None, None, "Benchmark module documentation")
    navigation("Module (Workspace fixture docs)", at("playbooks/modules.yml", "acme.web.probe", len("acme.web.")),
               [f"{collection}/plugins/modules/probe.py"], None, None, "Benchmark module documentation")
    navigation("Module option", at("playbooks/modules.yml", "msg:"), None, None, None, "Benchmark msg option")
    navigation("Play keyword", at("playbooks/modules.yml", "hosts"), None, None, None, "list of groups")

    def fanout_check(result):
        actual = locations(result)
        assert len(actual) == files * tasks + 1, "wrong fan-out reference count"
        counts = Counter(item["uri"] for item in actual)
        expected = {(root / f"background/{i:05}.yml").as_uri(): tasks for i in range(files)}
        expected[(root / "playbooks/fanout.yml").as_uri()] = 1
        assert counts == expected, "fan-out references skipped/duplicated sites or files"
    cases.append(Case("Variable (high fan-out)", "references", "textDocument/references",
                      dict(at("playbooks/fanout.yml", "fanout"), context={"includeDeclaration": True}), fanout_check))
    cases.append(Case("Variable (reads only)", "references", "textDocument/references",
                      dict(at("roles/db/tasks/main.yml", "{{ port", 3), context={"includeDeclaration": False}),
                      location_check(root, ["roles/db/tasks/main.yml"])))
    for target, position, label in (
        ("Collections", at("playbooks/collections.yml", "community.general"), "acme.web"),
        ("Play keywords", at("playbooks/modules.yml", "hosts"), "hosts"),
        ("Module options", at("playbooks/modules.yml", "msg:"), "var"),
    ):
        cases.append(Case(target, "completion", "textDocument/completion", position, item_check("label", label)))
    cases.append(Case("Module (fixture docs)", "completion resolve", "completionItem/resolve",
                      {"label": "ansible.builtin.debug", "data": {"uri": (root / "playbooks/modules.yml").as_uri()}},
                      lambda result: hover_check("Benchmark module documentation")({"contents": (result or {}).get("documentation", {})})))
    for target, query, name in (("Roles", "nginx", "nginx"), ("Collections", "acme", "acme.web"),
                                ("Modules", "probe", "probe"), ("Plugins", "tools", "tools"),
                                ("Playbooks / plays", "greet", "Greet"), ("Task files", "install", "install.yml")):
        cases.append(Case(target, "workspace symbols", "workspace/symbol", {"query": query}, item_check("name", name)))
    doc = {"textDocument": {"uri": (root / "playbooks/modules.yml").as_uri()}}
    cases.append(Case("Playbook", "document symbols", "textDocument/documentSymbol", doc,
                      lambda result: require(bool(result), "empty document symbols")))
    cases.append(Case("Playbook", "semantic tokens", "textDocument/semanticTokens/full", doc,
                      lambda result: require(bool(result and result.get("data")), "empty semantic tokens")))
    for target, position, title in (
        ("Variable", at("roles/db/tasks/main.yml", "{{ port", 3), "Add debug statement for 'port'"),
        ("Debug task", at("roles/db/tasks/main.yml", "debug"), "Remove debug statement"),
        ("Task extraction", at("roles/db/tasks/main.yml", "- name", 2), "Extract task to include_tasks (task1.yml)"),
    ):
        params = {"textDocument": position["textDocument"],
                  "range": {"start": position["position"], "end": position["position"]},
                  "context": {"diagnostics": []}}
        cases.append(Case(target, "code actions", "textDocument/codeAction", params, item_check("title", title)))
    return cases


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def percentile(samples, fraction):
    return sorted(samples)[max(0, math.ceil(len(samples) * fraction) - 1)]


def result_count(case, result):
    if case.operation == "hover" or case.operation == "completion resolve":
        return 1
    if case.operation == "semantic tokens":
        return len(result["data"]) // 5
    if case.operation == "completion":
        return len(result["items"])
    return len(locations(result))


def run_session(root, sources, cases, args, watching, session):
    with tempfile.TemporaryDirectory(prefix="zals-operations-cache-") as cache:
        env = dict(os.environ, PATH=str(root / "bin"), HOME=cache, XDG_CACHE_HOME=cache,
                   ANSIBLE_CONFIG=str(root / "ansible.cfg"), ANSIBLE_COLLECTIONS_PATH=str(root / "collections"),
                   ANSIBLE_ROLES_PATH=os.pathsep.join(str(root / name) for name in ("roles", "galaxy_roles")))
        env.pop("VIRTUAL_ENV", None)
        env.pop("ANSIBLE_COLLECTIONS_PATHS", None)
        began = time.perf_counter_ns()
        client = Client(str(root), env)
        try:
            client.request("initialize", {"processId": None, "rootUri": root.as_uri(),
                "capabilities": {"workspace": {"didChangeWatchedFiles": {"dynamicRegistration": watching},
                                                 "workspaceEdit": {"resourceOperations": ["create"]}}},
                "initializationOptions": {"ansible": {"validation": {"enabled": False}}}})
            client.notify("initialized", {})
            ready = client.wait_notification("ansible/workspaceIndexReady")
            startup_ms = (time.perf_counter_ns() - began) / 1e6
            client.wait_notification("ansible/docsLibraryReady")
            expected_files = sum(not name.startswith(".venv") and
                                 (name.endswith((".yml", ".yaml", ".j2")) or "/plugins/" in name and name.endswith(".py"))
                                 for name in sources if not name.startswith(".git/"))
            require(ready["filesCount"] == expected_files, "index skipped fixture files")
            paths = sorted({case.params["textDocument"]["uri"] for case in cases if "textDocument" in case.params})
            for uri in paths:
                name = next(name for name in sources if (root / name).as_uri() == uri)
                client.notify("textDocument/didOpen", {"textDocument": {
                    "uri": uri, "languageId": "jinja2" if name.endswith(".j2") else "ansible",
                    "version": 1, "text": sources[name]}})
            # Untimed barrier: process opens/registration before request samples.
            client.request("workspace/symbol", {"query": "__benchmark_barrier__"})
            require(client.registered == watching, "watcher negotiation did not match requested mode")
            measurements = {i: {"first_ms": [], "warm_ms": [], "result_counts": []}
                            for i, case in enumerate(cases) if case.check is not None}
            order = list(measurements)
            rng = random.Random(args.seed + session)
            rng.shuffle(order)

            def sample(i, phase):
                case = cases[i]
                start = time.perf_counter_ns()
                result = client.request(case.method, case.params)
                elapsed = (time.perf_counter_ns() - start) / 1e6
                try:
                    case.check(result)
                except (AssertionError, KeyError, TypeError) as exc:
                    raise AssertionError(f"{case.target} / {case.operation}: {exc}") from exc
                if phase is not None:
                    measurements[i][phase].append(elapsed)
                    measurements[i]["result_counts"].append(result_count(case, result))

            for i in order:
                sample(i, "first_ms")
            for _ in range(args.warmup):
                rng.shuffle(order)
                for i in order:
                    sample(i, None)
            for _ in range(args.samples):
                rng.shuffle(order)
                for i in order:
                    sample(i, "warm_ms")
            print(f"{('watching' if watching else 'no watching')}, session {session + 1}/{args.sessions}: "
                  f"{ready['filesCount']} files, index {startup_ms:.1f} ms, all responses checked", file=sys.stderr)
            return startup_ms, ready["filesCount"], measurements
        finally:
            client.close()


def report_rows(cases, measurements, watching):
    rows = []
    for i, case in enumerate(cases):
        row = {"watching": watching, "target": case.target, "operation": case.operation,
               "method": case.method, "status": "measured" if case.check else "N/A"}
        if case.check:
            samples = measurements[i]
            row.update(samples)
            row.update(first_median_ms=statistics.median(samples["first_ms"]),
                       warm_median_ms=statistics.median(samples["warm_ms"]),
                       warm_p95_ms=percentile(samples["warm_ms"], .95), warm_max_ms=max(samples["warm_ms"]),
                       result_count_min=min(samples["result_counts"]), result_count_max=max(samples["result_counts"]))
        rows.append(row)
    return rows


def markdown(report):
    meta = report["metadata"]
    lines = ["# LSP operation latency", "", f"Generated: {meta['generated_at']}",
             f"Build label: {meta['label']}; platform: {meta['platform']} / {meta['machine']}",
             f"Binary SHA-256: `{meta['binary_sha256']}`", "",
             f"Fixture: {meta['files']} background files × {meta['tasks']} tasks; "
             f"{meta['sessions']} fresh sessions/mode; {meta['samples']} warm samples/session/case.", "",
             "All times are end-to-end stdio round-trip milliseconds, including JSON transport/decoding.",
             "First = median first observation per session, **not** an isolated cold-cache request; cases share a session.",
             "Warm samples are interleaved in seeded shuffled order. p95 uses nearest rank; max includes outliers.",
             "Ansible tools/docs are deterministic Python fixtures, not measurements of real ansible-doc or plugin discovery.",
             "N/A = no target-specific provider; omitted rather than timing empty/fallback results.",
             "Results = returned locations/items/top-level document symbols, or token count; hover/resolve = 1.",
             f"Warmup passes: {meta['warmup']}; shuffle seed: {meta['seed']}; filter: `{meta['filter'] or '(all)'}`.", ""]
    for watching in dict.fromkeys(row["watching"] for row in report["rows"]):
        mode = "File watching enabled" if watching else "No file watching (fallback stats)"
        startup = next(item for item in report["startup"] if item["watching"] == watching)
        lines += [f"## {mode}", "", f"Indexed files: {startup['indexed_files']}; "
                  f"initialize-to-index-ready median: {statistics.median(startup['samples_ms']):.1f} ms.", "",
                  "| Target | Operation | First ms | Warm median ms | Warm p95 ms | Warm max ms | Results | Samples |",
                  "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
        for row in report["rows"]:
            if row["watching"] != watching:
                continue
            if row["status"] == "N/A":
                lines.append(f"| {row['target']} | {row['operation']} | N/A | — | — | — | — | 0 |")
                continue
            counts = str(row["result_count_min"]) if row["result_count_min"] == row["result_count_max"] else f"{row['result_count_min']}–{row['result_count_max']}"
            values = " | ".join(f"{row[key]:.2f}" for key in ("first_median_ms", "warm_median_ms", "warm_p95_ms", "warm_max_ms"))
            lines.append(f"| {row['target']} | {row['operation']} | {values} | {counts} | {len(row['warm_ms'])} |")
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(smoke_cold_start.BIN))
    parser.add_argument("--label", default="unspecified", help="build label, e.g. Debug or ReleaseSafe")
    parser.add_argument("--files", type=int, default=1000)
    parser.add_argument("--tasks", type=int, default=20)
    parser.add_argument("--sessions", type=int, default=3)
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--warmup", type=int, default=2)
    parser.add_argument("--watching", choices=("both", "on", "off"), default="both")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--filter", default="", help="case-insensitive target/operation substring")
    parser.add_argument("--markdown", type=Path, help="also save the Markdown table")
    parser.add_argument("--json", type=Path, help="save metadata and all raw timing samples")
    parser.add_argument("--max-p95-ms", type=float, help="optional local budget for every measured warm p95")
    args = parser.parse_args()
    if min(args.files, args.tasks, args.sessions, args.samples) < 1 or args.warmup < 0:
        parser.error("files/tasks/sessions/samples must be positive; warmup must be nonnegative")
    if args.max_p95_ms is not None and args.max_p95_ms < 0:
        parser.error("--max-p95-ms must be nonnegative")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error(f"missing binary: {binary}; run make build first")
    smoke_cold_start.BIN = str(binary)
    report = {"metadata": {"generated_at": datetime.now(timezone.utc).isoformat(),
                           "platform": platform.platform(), "machine": platform.machine(),
                           "label": args.label,
                           "binary": os.path.relpath(binary), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                           **{key: getattr(args, key) for key in ("files", "tasks", "sessions", "samples", "warmup", "seed", "filter")}},
              "startup": [], "rows": []}
    with tempfile.TemporaryDirectory(prefix="zals-operations-") as tmp:
        root = Path(tmp).resolve()
        sources = fixture(root, args.files, args.tasks)
        cases = cases_for(root, sources, args.files, args.tasks)
        cases = [case for case in cases if args.filter.casefold() in f"{case.target} {case.operation}".casefold()]
        if not any(case.check is not None for case in cases):
            parser.error("--filter matched no measurable operations")
        modes = [True, False] if args.watching == "both" else [args.watching == "on"]
        for watching in modes:
            all_samples = {}
            startup_samples = []
            for session in range(args.sessions):
                startup, indexed_files, measurements = run_session(root, sources, cases, args, watching, session)
                startup_samples.append(startup)
                for i, values in measurements.items():
                    merged = all_samples.setdefault(i, {"first_ms": [], "warm_ms": [], "result_counts": []})
                    for key, value in values.items():
                        merged[key].extend(value)
            report["startup"].append({"watching": watching, "indexed_files": indexed_files, "samples_ms": startup_samples})
            report["rows"].extend(report_rows(cases, all_samples, watching))
    table = markdown(report)
    print(table)
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(table + "\n")
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(report, indent=2) + "\n")
    if args.max_p95_ms is not None:
        failures = [f"{row['target']} / {row['operation']} (watching={row['watching']}): {row['warm_p95_ms']:.2f} ms"
                    for row in report["rows"] if row["status"] == "measured" and row["warm_p95_ms"] > args.max_p95_ms]
        require(not failures, "warm p95 budget exceeded:\n" + "\n".join(failures))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Parity harness: stream the same YAML + LSP requests to the upstream Ansible
Language Server and to `zals`, then compare the results.

Usage:
    python3 test/parity/compare.py [--json report.json] [--verbose]

Environment:
    ZALS_BIN   path to the zals binary (default: ./zig-out/bin/zals)
    ALS_BIN    path to the upstream ALS cli.cjs
               (default: /tmp/als-install/node_modules/@ansible/ansible-language-server/dist/cli.cjs)
    ALS_CMD    full command override for the upstream server (shell-split)

The harness starts both servers over stdio, initializes them, opens each corpus
document, and issues hover / completion / semanticTokens / definition requests.
Results are normalized (hover text, completion labels, decoded semantic tokens,
definition targets) and compared. Exit code is 0 when every case scores at or
above the threshold (default 0.9), 1 otherwise; pass --allow-diffs for
report-only mode.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

ZALS_BIN = os.environ.get("ZALS_BIN", os.path.join(os.getcwd(), "zig-out/bin/zals"))
ALS_BIN = os.environ.get(
    "ALS_BIN",
    "/tmp/als-install/node_modules/@ansible/ansible-language-server/dist/cli.cjs",
)
ALS_CMD = os.environ.get("ALS_CMD")

# ---------------------------------------------------------------------------
# Corpus
# ---------------------------------------------------------------------------

PLAYBOOK = """---
- hosts: all
  become: true
  tasks:
    - name: ping
      ansible.builtin.ping:
    - name: install
      ansible.builtin.package:
        name: nginx
        state: present
"""

TASKS = """---
- name: copy file
  ansible.builtin.copy:
    src: /tmp/a
    dest: /tmp/b
    mode: "0644"
- name: template
  ansible.builtin.template:
    src: x.j2
    dest: /tmp/x
- name: incomplete
  ansible.builtin.
"""

VARS = """---
app_name: demo
app_port: 8080
app_debug: false
app_tags:
  - web
  - api
"""

CASES = [
    {
        "name": "playbook",
        "text": PLAYBOOK,
        "requests": [
            {"method": "textDocument/hover", "line": 5, "character": 8},
            {"method": "textDocument/completion", "line": 4, "character": 6},
            {"method": "textDocument/semanticTokens/full"},
            {"method": "textDocument/definition", "line": 5, "character": 8},
        ],
    },
    {
        "name": "tasks",
        "text": TASKS,
        "requests": [
            {"method": "textDocument/hover", "line": 1, "character": 8},
            {"method": "textDocument/completion", "line": 10, "character": 2},
            {"method": "textDocument/semanticTokens/full"},
        ],
    },
    {
        "name": "vars",
        "text": VARS,
        "requests": [
            {"method": "textDocument/semanticTokens/full"},
        ],
    },
]

# ---------------------------------------------------------------------------
# LSP client
# ---------------------------------------------------------------------------


def frame(obj):
    body = json.dumps(obj).encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


class LspClient:
    def __init__(self, name, argv):
        self.name = name
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        self.next_id = 1
        self.notifications = []
        self.legend = []
        self.capabilities = {}

    def send(self, obj):
        try:
            self.proc.stdin.write(frame(obj))
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            raise RuntimeError("%s: server is not accepting input" % self.name)

    def request(self, method, params, timeout=30.0):
        rid = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return self._read_until_id(rid, timeout)

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def _read_msg(self):
        headers = {}
        while True:
            line = self.proc.stdout.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                break
            k, v = line.split(b":", 1)
            headers[k.strip().lower()] = v.strip()
        n = int(headers[b"content-length"])
        return json.loads(self.proc.stdout.read(n))

    def _read_until_id(self, want, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self._read_msg()
            if msg is None:
                raise RuntimeError("%s: EOF waiting for id %s" % (self.name, want))
            if msg.get("id") == want:
                return msg
            if "method" in msg:
                self.notifications.append(msg["method"])
        raise TimeoutError("%s: timeout waiting for id %s" % (self.name, want))

    def initialize(self, root_uri):
        resp = self.request(
            "initialize",
            {
                "processId": None,
                "rootUri": root_uri,
                "capabilities": {},
                "workspaceFolders": [{"uri": root_uri, "name": "ws"}],
            },
        )
        result = resp.get("result") or {}
        self.capabilities = result.get("capabilities", {})
        st = self.capabilities.get("semanticTokensProvider") or {}
        self.legend = st.get("legend", {}).get("tokenTypes", [])
        self.notify("initialized", {})

    def wait_for_notification(self, method, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = self._read_msg()
            if msg is None:
                return False
            if msg.get("method") == method:
                return True
            if "method" in msg:
                self.notifications.append(msg["method"])
        return False

    def shutdown(self):
        try:
            self.request("shutdown", None, timeout=10)
            self.notify("exit", None)
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


# ---------------------------------------------------------------------------
# Normalization
# ---------------------------------------------------------------------------


def norm_hover(result):
    if not result:
        return None
    contents = result.get("contents")
    if isinstance(contents, dict):
        text = contents.get("value", "")
    elif isinstance(contents, list):
        text = "\n".join(c.get("value", "") if isinstance(c, dict) else str(c) for c in contents)
    else:
        text = str(contents)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def norm_completion(result):
    if result is None:
        return None
    items = result.get("items", result) if isinstance(result, dict) else result
    if not isinstance(items, list):
        return []
    return sorted({it.get("label", "") for it in items if isinstance(it, dict)})


def norm_semantic(result, legend):
    if not result:
        return []
    data = result.get("data", [])
    tokens = []
    line = char = 0
    for i in range(0, len(data) - 4, 5):
        dl, dc, length, ttype, mods = data[i : i + 5]
        line += dl
        char = dc if dl else char + dc
        name = legend[ttype] if 0 <= ttype < len(legend) else str(ttype)
        tokens.append((line, char, length, name))
    return sorted(tokens)


def norm_definition(result):
    if not result:
        return []
    if isinstance(result, dict):
        result = [result]
    out = []
    for loc in result:
        uri = loc.get("uri") or loc.get("targetUri") or ""
        out.append(uri)
    return sorted(out)


def jaccard(a, b):
    sa, sb = set(a), set(b)
    if not sa and not sb:
        return 1.0
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / len(sa | sb)


def text_similarity(a, b):
    if a is None and b is None:
        return 1.0
    if a is None or b is None:
        return 0.0
    wa = set(re.findall(r"[A-Za-z0-9_.]+", a.lower()))
    wb = set(re.findall(r"[A-Za-z0-9_.]+", b.lower()))
    return jaccard(wa, wb)


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------


def compare_request(method, upstream, zals, legend_up, legend_zals):
    if method == "textDocument/hover":
        a, b = norm_hover(upstream), norm_hover(zals)
        score = text_similarity(a, b)
        return score, {"upstream": a, "zals": b}
    if method == "textDocument/completion":
        a, b = norm_completion(upstream), norm_completion(zals)
        score = jaccard(a or [], b or [])
        return score, {
            "upstream_count": len(a or []),
            "zals_count": len(b or []),
            "only_upstream": sorted(set(a or []) - set(b or []))[:20],
            "only_zals": sorted(set(b or []) - set(a or []))[:20],
        }
    if method == "textDocument/semanticTokens/full":
        a = norm_semantic(upstream, legend_up)
        b = norm_semantic(zals, legend_zals)
        score = jaccard(a, b)
        return score, {
            "upstream_count": len(a),
            "zals_count": len(b),
            "only_upstream": [list(t) for t in sorted(set(a) - set(b))][:20],
            "only_zals": [list(t) for t in sorted(set(b) - set(a))][:20],
        }
    if method == "textDocument/definition":
        a, b = norm_definition(upstream), norm_definition(zals)
        score = jaccard(a, b)
        return score, {"upstream": a, "zals": b}
    return 0.0, {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", help="write a JSON report to this path")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--threshold", type=float, default=0.9, help="match threshold (default 0.9)")
    ap.add_argument(
        "--allow-diffs",
        action="store_true",
        help="exit 0 even when cases differ (report-only mode)",
    )
    args = ap.parse_args()

    if ALS_CMD:
        als_argv = ALS_CMD.split()
    else:
        if not os.path.exists(ALS_BIN):
            print(
                "SKIP: upstream ALS not found at %s\n"
                "      install it with: npm install @ansible/ansible-language-server\n"
                "      or set ALS_BIN / ALS_CMD." % ALS_BIN
            )
            return 0
        als_argv = ["node", ALS_BIN, "--stdio"]
    zals_argv = [ZALS_BIN, "--stdio"]

    if not os.path.exists(ZALS_BIN):
        print("SKIP: zals binary not found at %s (run `make build`)" % ZALS_BIN)
        return 0

    root_uri = "file:///tmp"
    upstream = LspClient("upstream", als_argv)
    zals = LspClient("zals", zals_argv)
    report = {"cases": [], "summary": {}}
    failures = 0
    total = 0

    try:
        upstream.initialize(root_uri)
        zals.initialize(root_uri)
        # Give both servers time to load their docs catalogs.
        time.sleep(2.0)

        for case in CASES:
            uri = "%s/%s.yml" % (root_uri, case["name"])
            doc = {
                "textDocument": {
                    "uri": uri,
                    "languageId": "ansible",
                    "version": 1,
                    "text": case["text"],
                }
            }
            upstream.notify("textDocument/didOpen", doc)
            zals.notify("textDocument/didOpen", doc)
            time.sleep(1.5)

            case_report = {"name": case["name"], "requests": []}
            for req in case["requests"]:
                method = req["method"]
                params = {"textDocument": {"uri": uri}}
                if "line" in req:
                    params["position"] = {"line": req["line"], "character": req["character"]}
                try:
                    up = upstream.request(method, params)
                    up_result = up.get("result")
                except Exception as e:
                    up_result = None
                    if args.verbose:
                        print("  upstream error: %s" % e)
                try:
                    za = zals.request(method, params)
                    za_result = za.get("result")
                except Exception as e:
                    za_result = None
                    if args.verbose:
                        print("  zals error: %s" % e)

                score, detail = compare_request(
                    method, up_result, za_result, upstream.legend, zals.legend
                )
                total += 1
                ok = score >= args.threshold
                if not ok:
                    failures += 1
                entry = {
                    "method": method,
                    "position": {"line": req.get("line"), "character": req.get("character")},
                    "score": round(score, 3),
                    "match": ok,
                    "detail": detail,
                }
                case_report["requests"].append(entry)
                status = "OK " if ok else "DIFF"
                print("[%s] %-14s %-40s score=%.2f" % (status, case["name"], method, score))
                if args.verbose and not ok:
                    print("      " + json.dumps(detail)[:400])
            report["cases"].append(case_report)

            upstream.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
            zals.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
    finally:
        upstream.shutdown()
        zals.shutdown()

    report["summary"] = {
        "total": total,
        "matched": total - failures,
        "diffs": failures,
        "threshold": args.threshold,
    }
    print(
        "\nSummary: %d/%d matched (threshold %.2f)"
        % (total - failures, total, args.threshold)
    )
    if args.json:
        with open(args.json, "w") as f:
            json.dump(report, f, indent=2)
        print("Report written to %s" % args.json)
    if args.allow_diffs:
        return 0
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
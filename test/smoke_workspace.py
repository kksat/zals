#!/usr/bin/env python3
"""Smoke-test workspace-wide navigation over stdio (ADR-0031, ADR-0032).

Builds a throwaway Workspace under a temporary directory, starts zals, waits
for `ansible/workspaceIndexReady`, and checks each workspace-wide feature.
Exits non-zero on the first failed check.
"""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "zig-out/bin/zals")

FILES = {
    ".git/HEAD": "ref: refs/heads/main\n",
    "ansible.cfg": "[defaults]\nroles_path = ./roles:./galaxy_roles\n",
    "roles/web/defaults/main.yml": "port: 80\n",
    "roles/db/defaults/main.yml": "port: 5432\n",
    "roles/db/tasks/main.yml": "- name: Show port\n  debug:\n    msg: \"{{ port }}\"\n",
    "playbooks/vars/prod.yml": "port: 8080\n",
    "playbooks/site.yml": (
        "- name: Databases\n"
        "  hosts: db\n"
        "  vars_files:\n"
        "    - vars/prod.yml\n"
        "  roles:\n"
        "    - db\n"
    ),
    "playbooks/other.yml": (
        "- name: Web\n"
        "  hosts: web\n"
        "  tasks:\n"
        "    - include_role:\n"
        "        name: db\n"
    ),
}


def frame(obj):
    body = json.dumps(obj).encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


class Client:
    def __init__(self, root):
        self.proc = subprocess.Popen([BIN, "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL)
        self.next_id = 1
        self.notifications = []
        self.root = root

    def send(self, obj):
        self.proc.stdin.write(frame(obj))
        self.proc.stdin.flush()

    def read(self):
        headers = {}
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("server closed the connection")
            line = line.strip()
            if not line:
                break
            k, _, v = line.decode().partition(":")
            headers[k.strip().lower()] = v.strip()
        return json.loads(self.proc.stdout.read(int(headers["content-length"])))

    def request(self, method, params):
        req_id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        while True:
            msg = self.read()
            if msg.get("id") == req_id and "method" not in msg:
                return msg.get("result")
            if "method" in msg and "id" not in msg:
                self.notifications.append(msg)

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def wait_index(self):
        for _ in range(200):
            if any(n["method"] == "ansible/workspaceIndexReady" for n in self.notifications):
                return
            self.request("zals/ping", {})
        raise RuntimeError("index never became ready")

    def open(self, rel):
        path = os.path.join(self.root, rel)
        with open(path) as f:
            text = f.read()
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": uri(path), "languageId": "ansible", "version": 1, "text": text}})
        return path, text

    def close(self):
        self.request("shutdown", None)
        self.notify("exit", None)
        self.proc.wait(timeout=10)


def uri(path):
    return "file://" + path


def pos(text, needle, nth=0, offset=0):
    idx = -1
    for _ in range(nth + 1):
        idx = text.index(needle, idx + 1)
    idx += offset
    line = text.count("\n", 0, idx)
    col = idx - (text.rfind("\n", 0, idx) + 1)
    return {"line": line, "character": col}


def rel(root, loc):
    return os.path.relpath(loc["uri"][len("file://"):], root)


FAILURES = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + detail))
    if not cond:
        FAILURES.append(name)


def as_list(result):
    if result is None:
        return []
    return result if isinstance(result, list) else [result]


def main():
    with tempfile.TemporaryDirectory(prefix="zals-ws-") as tmp:
        root = os.path.realpath(tmp)
        for name, text in FILES.items():
            path = os.path.join(root, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(text)

        c = Client(root)
        c.request("initialize", {"processId": None, "rootUri": uri(root), "capabilities": {}})
        c.notify("initialized", {})
        c.wait_index()

        tasks, text = c.open("roles/db/tasks/main.yml")
        at = {"textDocument": {"uri": uri(tasks)}, "position": pos(text, "{{ port", offset=3)}

        refs = as_list(c.request("textDocument/references", dict(at, context={"includeDeclaration": True})))
        files = sorted({rel(root, l) for l in refs})
        check("variable references span the Workspace",
              files == ["playbooks/vars/prod.yml", "roles/db/defaults/main.yml",
                        "roles/db/tasks/main.yml", "roles/web/defaults/main.yml"], str(files))

        defs = [rel(root, l) for l in as_list(c.request("textDocument/definition", at))]
        check("reachable definitions come first, ranked",
              defs[:2] == ["playbooks/vars/prod.yml", "roles/db/defaults/main.yml"], str(defs))
        check("unreachable definitions follow", defs[2:] == ["roles/web/defaults/main.yml"], str(defs))

        c.close()
    if FAILURES:
        sys.exit(1)


if __name__ == "__main__":
    main()

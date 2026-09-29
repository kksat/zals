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
        "  roles:\n"
        "    - geerlingguy.nginx\n"
        "  tasks:\n"
        "    - include_role:\n"
        "        name: db\n"
    ),
    "roles/requirements.yml": "roles:\n  - name: geerlingguy.nginx\n",
    "galaxy_roles/geerlingguy.nginx/README.md": "# nginx from Galaxy\n",
    "galaxy_roles/geerlingguy.nginx/tasks/main.yml": "- debug: msg=hi\n",
    "roles/db/meta/argument_specs.yml": (
        "argument_specs:\n"
        "  main:\n"
        "    options:\n"
        "      port:\n"
        "        type: int\n"
        "        description: Listening port\n"
    ),
    "roles/app/meta/argument_specs.yml": (
        "argument_specs:\n"
        "  main:\n"
        "    options:\n"
        "      app_port:\n"
        "        type: int\n"
        "        description: App port\n"
        "  setup:\n"
        "    options:\n"
        "      db_name:\n"
        "        type: str\n"
        "        description: Database to create\n"
    ),
    "roles/app/tasks/main.yml": "- debug: msg=app\n",
    "playbooks/params.yml": (
        "- name: Params\n"
        "  hosts: app\n"
        "  roles:\n"
        "    - role: app\n"
        "      app_port: 5433\n"
        "  tasks:\n"
        "    - ansible.builtin.include_role:\n"
        "        name: app\n"
        "        tasks_from: setup.yml\n"
        "      vars:\n"
        "        db_name: app\n"
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
              files == ["playbooks/vars/prod.yml", "roles/db/defaults/main.yml", "roles/db/meta/argument_specs.yml",
                        "roles/db/tasks/main.yml", "roles/web/defaults/main.yml"], str(files))

        defs = [rel(root, l) for l in as_list(c.request("textDocument/definition", at))]
        check("reachable definitions come first, ranked",
              defs[:3] == ["playbooks/vars/prod.yml", "roles/db/defaults/main.yml",
                           "roles/db/meta/argument_specs.yml"], str(defs))
        check("unreachable definitions follow", defs[3:] == ["roles/web/defaults/main.yml"], str(defs))

        site, site_text = c.open("playbooks/site.yml")
        at_db = {"textDocument": {"uri": uri(site)}, "position": pos(site_text, "- db", offset=2)}
        refs = as_list(c.request("textDocument/references", dict(at_db, context={"includeDeclaration": True})))
        files = sorted(rel(root, l) for l in refs)
        check("role references span the Workspace", files == ["playbooks/other.yml", "playbooks/site.yml"], str(files))

        hov = c.request("textDocument/hover", at_db)
        check("role hover shows argument specs", hov and "Listening port" in hov["contents"]["value"], str(hov))

        other, other_text = c.open("playbooks/other.yml")
        at_galaxy = {"textDocument": {"uri": uri(other)}, "position": pos(other_text, "geerlingguy")}
        defs = [rel(root, l) for l in as_list(c.request("textDocument/implementation", at_galaxy))]
        check("galaxy role resolves through roles_path", defs == ["galaxy_roles/geerlingguy.nginx/tasks/main.yml"], str(defs))
        hov = c.request("textDocument/hover", at_galaxy)
        check("role hover shows README", hov and "nginx from Galaxy" in hov["contents"]["value"], str(hov))
        refs = as_list(c.request("textDocument/references", dict(at_galaxy, context={"includeDeclaration": True})))
        files = sorted(rel(root, l) for l in refs)
        check("requirements entries are role references",
              files == ["playbooks/other.yml", "roles/requirements.yml"], str(files))

        params, params_text = c.open("playbooks/params.yml")
        hov = c.request("textDocument/hover", {"textDocument": {"uri": uri(params)},
                                               "position": pos(params_text, "app_port")})
        check("role parameter hover in a roles entry",
              hov and "```yaml\napp_port:\n  type: int" in hov["contents"]["value"], str(hov))
        hov = c.request("textDocument/hover", {"textDocument": {"uri": uri(params)},
                                               "position": pos(params_text, "db_name")})
        check("role parameter hover uses the tasks_from entry point",
              hov and "entry point `setup`" in hov["contents"]["value"]
              and "Database to create" in hov["contents"]["value"], str(hov))

        c.close()
    if FAILURES:
        sys.exit(1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Cold replies and idle readiness must not wait for Ansible docs bootstrap.

The fake ansible-doc catalog blocks on a gate, making a synchronous bootstrap
fail deterministically. No real Ansible installation or wall-clock benchmark is
needed. Run after `make build`; --files controls the unrelated indexing load.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time

from smoke_workspace import BIN, frame, pos


class Client:
    def __init__(self, root, env):
        self.proc = subprocess.Popen(
            [BIN, "--stdio", "--log-level", "error"], cwd=root, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        )
        self.messages = queue.Queue()
        self.notifications = []
        self.next_id = 1
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            while True:
                headers = {}
                while True:
                    line = self.proc.stdout.readline()
                    if not line:
                        raise RuntimeError("server closed stdout")
                    if not line.strip():
                        break
                    key, _, value = line.decode().partition(":")
                    headers[key.lower()] = value.strip()
                body = self.proc.stdout.read(int(headers["content-length"]))
                self.messages.put(json.loads(body))
        except Exception as exc:
            self.messages.put(exc)

    def read(self, timeout=2):
        try:
            message = self.messages.get(timeout=timeout)
        except queue.Empty as exc:
            raise AssertionError("cold reply blocked by docs/index startup") from exc
        if isinstance(message, Exception):
            raise message
        if "method" in message and "id" not in message:
            self.notifications.append(message)
        return message

    def notify(self, method, params):
        self.proc.stdin.write(frame({"jsonrpc": "2.0", "method": method, "params": params}))
        self.proc.stdin.flush()

    def request(self, method, params):
        request_id = self.next_id
        self.next_id += 1
        self.proc.stdin.write(frame({"jsonrpc": "2.0", "id": request_id,
                                    "method": method, "params": params}))
        self.proc.stdin.flush()
        deadline = time.monotonic() + 2
        while True:
            message = self.read(max(0, deadline - time.monotonic()))
            if message.get("id") == request_id:
                assert "error" not in message, message
                return message["result"]

    def wait_notification(self, method):
        deadline = time.monotonic() + 15
        while True:
            for message in self.notifications:
                if message["method"] == method:
                    return message["params"]
            assert time.monotonic() < deadline, f"missing idle {method}"
            self.read(max(0, deadline - time.monotonic()))

    def close(self):
        try:
            self.request("shutdown", None)
            self.notify("exit", None)
            self.proc.wait(timeout=10)
            assert self.proc.returncode == 0, self.proc.returncode
        finally:
            if self.proc.poll() is None:
                self.proc.kill()
                self.proc.wait()
            self.reader.join(timeout=2)
            self.proc.stdin.close()
            self.proc.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--files", type=int, default=500)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="zals-cold-") as tmp:
        root = Path(tmp).resolve()
        (root / ".git").mkdir()
        (root / "bin").mkdir()
        gate = root / "release-docs"
        entered = root / "catalog-started"
        calls = root / "calls"
        script = f'''#!{sys.executable}
import json
from pathlib import Path
import sys
import time
root = Path({str(root)!r})
with (root / "calls").open("a") as log:
    log.write(Path(sys.argv[0]).name + " " + " ".join(sys.argv[1:]) + "\\n")
if Path(sys.argv[0]).name == "ansible-doc":
    if "--version" in sys.argv:
        print("ansible-doc [core cold-test]")
    elif "-l" in sys.argv:
        (root / "catalog-started").touch()
        while not (root / "release-docs").exists():
            time.sleep(.01)
        print(json.dumps({{"ansible.builtin.debug": "Display a message"}}))
    else:
        print("{{}}")
'''
        for command in ("ansible", "ansible-doc", "ansible-config"):
            path = root / "bin" / command
            path.write_text(script)
            path.chmod(0o755)
        text = '- hosts: all\n  vars:\n    cold_value: hello\n  tasks:\n    - debug:\n        msg: "{{ cold_value }}"\n'
        source = root / "site.yml"
        source.write_text(text)
        (root / "roles/demo/tasks").mkdir(parents=True)
        (root / "roles/demo/tasks/main.yml").write_text("- debug: msg=hello\n")
        (root / "roles/demo/README.md").write_text("# A cold role hover\n")
        role_text = "- hosts: all\n  roles: [demo]\n"
        role_source = root / "role.yml"
        role_source.write_text(role_text)
        (root / "data").mkdir()
        unrelated = '- name: unrelated\n  debug:\n    msg: "{{ unrelated }}"\n' * 20
        for i in range(args.files):
            (root / f"data/{i:05}.yml").write_text(unrelated)
        env = dict(os.environ, PATH=str(root / "bin"), HOME=str(root),
                   XDG_CACHE_HOME=str(root / ".cache"), ANSIBLE_CONFIG=str(root / "ansible.cfg"),
                   ANSIBLE_COLLECTIONS_PATH=str(root / "missing"),
                   ANSIBLE_ROLES_PATH=str(root / "roles"))
        env.pop("VIRTUAL_ENV", None)
        client = Client(str(root), env)
        try:
            client.request("initialize", {"processId": None, "rootUri": root.as_uri(), "capabilities": {}})
            # Initialization must not spawn any Ansible subprocess.
            assert not calls.exists(), "initialize synchronously probes Ansible"
            client.notify("workspace/didChangeConfiguration", {
                "settings": {"ansible": {"validation": {"enabled": False}}}})
            client.notify("initialized", {})
            client.notify("textDocument/didOpen", {"textDocument": {
                "uri": source.as_uri(), "languageId": "ansible", "version": 1, "text": text}})
            at = {"textDocument": {"uri": source.as_uri()}, "position": pos(text, "cold_value", nth=1)}
            began = time.perf_counter()
            hover = client.request("textDocument/hover", at)
            assert hover and "hello" in hover["contents"]["value"], hover
            print(f"ok   useful cold hover: {(time.perf_counter() - began) * 1000:.1f} ms")
            definitions = client.request("textDocument/definition", at)
            assert definitions and definitions[0]["uri"] == source.as_uri(), definitions
            refs = client.request("textDocument/references", dict(at, context={"includeDeclaration": True}))
            assert len([loc for loc in refs if loc["uri"] == source.as_uri()]) == 2, refs
            symbols = client.request("workspace/symbol", {"query": "site"})
            assert any(symbol["name"] == "site.yml" for symbol in symbols), symbols
            actions = client.request("textDocument/codeAction", {
                "textDocument": at["textDocument"],
                "range": {"start": at["position"], "end": at["position"]},
                "context": {"diagnostics": []},
            })
            assert actions, actions
            client.notify("textDocument/didOpen", {"textDocument": {
                "uri": role_source.as_uri(), "languageId": "ansible", "version": 1, "text": role_text}})
            role_hover = client.request("textDocument/hover", {
                "textDocument": {"uri": role_source.as_uri()}, "position": pos(role_text, "demo")})
            assert role_hover and "A cold role hover" in role_hover["contents"]["value"], role_hover
            ready = client.wait_notification("ansible/workspaceIndexReady")
            assert ready["filesCount"] == args.files + 3, ready
            # A tiny Workspace can finish before the version probe has even
            # launched the catalog subprocess. Wait for the gate without LSP
            # traffic; the catalog must remain blocked until we release it.
            deadline = time.monotonic() + 2
            while not entered.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            assert entered.exists(), "docs bootstrap did not run concurrently"
            assert not any(n["method"] == "ansible/docsLibraryReady" for n in client.notifications)
            print("ok   index ready while idle and docs catalog is still blocked")
            gate.touch()
            ready = client.wait_notification("ansible/docsLibraryReady")
            assert ready["modulesCount"] == 1, ready
            print("ok   docs ready while idle, after catalog bootstrap")
        finally:
            gate.touch()
            client.close()


if __name__ == "__main__":
    main()

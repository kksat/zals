"""Assert LSP behavior against the built server, without an Ansible installation.

Run with `make protocol` or `python3 -m unittest discover -s test -p 'test_*.py'`.
Each conversation has a timeout so a broken response or shutdown fails CI.
"""

import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "zig-out" / "bin" / ("zals.exe" if os.name == "nt" else "zals")


def message(method, params=None, req_id=None):
    obj = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if req_id is not None:
        obj["id"] = req_id
    return obj


def frame(obj):
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


def decode_messages(output):
    stream = io.BytesIO(output)
    messages = []
    while stream.tell() < len(output):
        headers = {}
        while True:
            line = stream.readline()
            if line == b"\r\n":
                break
            if not line.endswith(b"\r\n"):
                raise AssertionError(f"Unframed server output: {line!r}")
            key, value = line.decode().split(":", 1)
            headers[key.lower()] = value.strip()
        length = int(headers["content-length"])
        body = stream.read(length)
        if len(body) != length:
            raise AssertionError("Truncated server response")
        messages.append(json.loads(body))
    return messages


class LspTests(unittest.TestCase):
    def conversation(self, messages=(), capabilities=None, root=None):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            uri = (workspace / "tasks.yml").as_uri()
            # Isolate tool discovery and caches from the developer's machine.
            # The executable is addressed absolutely, so an empty PATH is safe.
            env = dict(os.environ, PATH=directory, HOME=directory, XDG_CACHE_HOME=directory)
            initialization = {
                "processId": None,
                "capabilities": capabilities or {},
                "initializationOptions": {"ansible": {"validation": {"enabled": False}}},
                **(root or {}),
            }
            outgoing = [
                message("initialize", initialization, "init"),
                message("initialized"),
                *(messages(uri) if callable(messages) else messages),
                message("shutdown", req_id="shutdown"),
                message("exit"),
            ]
            proc = subprocess.run(
                [str(BIN), "--stdio"],
                input=b"".join(frame(obj) for obj in outgoing),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=workspace,
                env=env,
                timeout=15,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr.decode(errors="replace"))
            self.assertNotIn(b"[gpa]", proc.stderr, proc.stderr.decode(errors="replace"))
            received = decode_messages(proc.stdout)
            self.assertTrue(all(obj.get("jsonrpc") == "2.0" for obj in received))
            responses = [obj for obj in received if "id" in obj]
            expected_ids = [obj["id"] for obj in outgoing if "id" in obj]
            self.assertCountEqual([obj["id"] for obj in responses], expected_ids)
            by_id = {obj["id"]: obj for obj in responses}
            self.assertEqual(by_id["shutdown"], {"jsonrpc": "2.0", "id": "shutdown", "result": None})
            self.assertFalse(any(
                str(obj.get("method", "")).startswith("ansible/") for obj in received
            ))
            return by_id, received

    @staticmethod
    def open_document(uri, text, version=1):
        return message("textDocument/didOpen", {"textDocument": {
            "uri": uri, "languageId": "ansible", "version": version, "text": text,
        }})

    @staticmethod
    def symbols(uri, req_id):
        return message("textDocument/documentSymbol", {"textDocument": {"uri": uri}}, req_id)

    def test_position_encoding_negotiation(self):
        for advertised, expected, end_column in [
            (None, "utf-16", 10),
            (["utf-16", "utf-8"], "utf-8", 12),
            (["utf-32"], "utf-16", 10),
        ]:
            with self.subTest(advertised=advertised):
                caps = {} if advertised is None else {"general": {"positionEncodings": advertised}}
                responses, _ = self.conversation(lambda uri: [
                    self.open_document(uri, "- name: 😀\n  debug:\n    msg: hi\n"),
                    self.symbols(uri, 2),
                ], capabilities=caps)
                server_caps = responses["init"]["result"]["capabilities"]
                self.assertEqual(server_caps["positionEncoding"], expected)
                self.assertEqual(server_caps["textDocumentSync"]["change"], 2)
                self.assertEqual(server_caps["textDocumentSync"]["openClose"], True)
                symbol = responses[2]["result"][0]
                self.assertEqual(symbol["name"], "😀")
                self.assertEqual(symbol["selectionRange"], {
                    "start": {"line": 0, "character": 8},
                    "end": {"line": 0, "character": end_column},
                })

    def test_workspace_capability_with_folders_and_legacy_root(self):
        for root, supported in [
            ({}, False),
            ({"rootUri": "file:///workspace"}, True),
            ({"rootUri": "file:///workspace", "workspaceFolders": []}, False),
            ({"workspaceFolders": [{"uri": "file:///workspace", "name": "workspace"}]}, True),
        ]:
            with self.subTest(root=root):
                responses, _ = self.conversation(root=root)
                workspace = responses["init"]["result"]["capabilities"]["workspace"]
                self.assertEqual(workspace, {"workspaceFolders": {
                    "supported": True, "changeNotifications": True,
                }} if supported else {})

    def test_unknown_requests_preserve_ids_and_notifications_are_ignored(self):
        responses, received = self.conversation([
            message("unknown/request", req_id=0),
            message("unknown/request", req_id="string-id"),
            message("unknown/notification"),
        ])
        for req_id in (0, "string-id"):
            self.assertNotIn("result", responses[req_id])
            self.assertEqual(responses[req_id]["error"]["code"], -32601)
        self.assertEqual([obj["method"] for obj in received if "method" in obj], [])

    def test_document_changes_reopen_and_close_are_visible_to_providers(self):
        def messages(uri):
            return [
                self.open_document(uri, "- name: 😀\r\n  debug:\r\n    msg: hi\r\n"),
                message("textDocument/didChange", {
                    "textDocument": {"uri": uri, "version": 2},
                    "contentChanges": [{
                        "range": {"start": {"line": 0, "character": 8},
                                  "end": {"line": 0, "character": 10}},
                        "text": "Renamed",
                    }],
                }),
                self.symbols(uri, "renamed"),
                message("textDocument/didChange", {
                    "textDocument": {"uri": uri, "version": 3},
                    "contentChanges": [
                        {"text": "- name: old\n  debug:\n    msg: hi\n"},
                        {"range": {"start": {"line": 0, "character": 8},
                                   "end": {"line": 0, "character": 11}}, "text": "Batch"},
                    ],
                }),
                self.symbols(uri, "batch"),
                self.open_document(uri, "- name: Reopened\n  debug:\n    msg: hi\n", version=4),
                self.symbols(uri, "reopened"),
                message("textDocument/didClose", {"textDocument": {"uri": uri}}),
                self.symbols(uri, "closed"),
                message("textDocument/semanticTokens/full", {"textDocument": {"uri": uri}}, "tokens"),
            ]
        responses, received = self.conversation(messages)
        for req_id, name in [("renamed", "Renamed"), ("batch", "Batch"), ("reopened", "Reopened")]:
            self.assertEqual(responses[req_id]["result"][0]["name"], name)
        self.assertEqual(responses["closed"]["result"], [])
        self.assertEqual(responses["tokens"]["result"], {"data": []})
        diagnostics = [obj for obj in received if obj.get("method") == "textDocument/publishDiagnostics"]
        self.assertEqual(len(diagnostics), 2)
        self.assertTrue(all(obj["params"]["diagnostics"] == [] for obj in diagnostics))

    def test_extract_actions_require_create_support_and_use_current_version(self):
        for operations in (["rename"], ["rename", "create"]):
            with self.subTest(operations=operations):
                responses, _ = self.conversation(lambda uri: [
                    self.open_document(uri, "- name: Demo\n  debug:\n    msg: hi\n"),
                    message("textDocument/didChange", {
                        "textDocument": {"uri": uri, "version": 7},
                        "contentChanges": [{"text": "- name: Updated\n  debug:\n    msg: hi\n"}],
                    }),
                    message("textDocument/codeAction", {
                        "textDocument": {"uri": uri},
                        "range": {"start": {"line": 0, "character": 8},
                                  "end": {"line": 0, "character": 8}},
                        "context": {"diagnostics": [], "only": ["refactor.extract"]},
                    }, "extract"),
                ], capabilities={"workspace": {"workspaceEdit": {"resourceOperations": operations}}})
                actions = responses["extract"]["result"]
                if "create" not in operations:
                    self.assertEqual(actions, [])
                    continue
                self.assertEqual(len(actions), 2)
                for action in actions:
                    self.assertEqual(action["kind"], "refactor.extract")
                    create, fill, source = action["edit"]["documentChanges"]
                    self.assertEqual(create["kind"], "create")
                    self.assertEqual(create["options"], {"overwrite": False})
                    self.assertEqual(fill["textDocument"], {"uri": create["uri"], "version": None})
                    self.assertIn("- name: Updated", fill["edits"][0]["newText"])
                    self.assertEqual(source["textDocument"]["version"], 7)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Smoke-test the references and definition providers over stdio."""
import json
import os
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "zig-out/bin/zals")


def frame(obj):
    body = json.dumps(obj).encode()
    return b"Content-Length: %d\r\n\r\n" % len(body) + body


def read_message(proc):
    headers = {}
    while True:
        line = proc.stdout.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        k, _, v = line.decode().partition(":")
        headers[k.strip().lower()] = v.strip()
    length = int(headers["content-length"])
    return json.loads(proc.stdout.read(length))


def read_response(proc, req_id):
    while True:
        msg = read_message(proc)
        if msg is None:
            return None
        if msg.get("id") == req_id:
            return msg


def uri(path):
    return "file://" + path


def main():
    proc = subprocess.Popen([BIN, "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    proc.stdin.write(frame({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "processId": None,
        "rootUri": uri(ROOT),
        "capabilities": {},
    }}))
    proc.stdin.flush()
    init = read_response(proc, 1)
    caps = init["result"]["capabilities"]
    print("referencesProvider:", caps.get("referencesProvider"))
    print("definitionProvider:", caps.get("definitionProvider"))

    proc.stdin.write(frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}))
    proc.stdin.flush()

    tasks = os.path.join(ROOT, "test/fixtures/roles/demo/tasks/main.yml")
    with open(tasks) as f:
        text = f.read()
    proc.stdin.write(frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": uri(tasks), "languageId": "ansible", "version": 1, "text": text},
    }}))
    proc.stdin.flush()

    # Cursor on `app_name` in the debug msg (line 3, col 12).
    line = text.splitlines()[3]
    col = line.index("app_name")
    proc.stdin.write(frame({"jsonrpc": "2.0", "id": 2, "method": "textDocument/references", "params": {
        "textDocument": {"uri": uri(tasks)},
        "position": {"line": 3, "character": col},
        "context": {"includeDeclaration": True},
    }}))
    proc.stdin.flush()
    refs = read_response(proc, 2)
    print("\nreferences(app_name):")
    for loc in refs["result"]:
        print("  ", loc["uri"].replace(uri(ROOT) + "/", ""), loc["range"]["start"])

    # Go to definition for app_name.
    proc.stdin.write(frame({"jsonrpc": "2.0", "id": 3, "method": "textDocument/definition", "params": {
        "textDocument": {"uri": uri(tasks)},
        "position": {"line": 3, "character": col},
    }}))
    proc.stdin.flush()
    defn = read_response(proc, 3)
    print("\ndefinition(app_name):")
    for loc in defn["result"]:
        print("  ", loc["uri"].replace(uri(ROOT) + "/", ""), loc["range"]["start"])

    # References for app_port (defined in defaults and vars, used in tasks).
    col2 = line.index("app_port")
    proc.stdin.write(frame({"jsonrpc": "2.0", "id": 4, "method": "textDocument/references", "params": {
        "textDocument": {"uri": uri(tasks)},
        "position": {"line": 3, "character": col2},
        "context": {"includeDeclaration": True},
    }}))
    proc.stdin.flush()
    refs2 = read_response(proc, 4)
    print("\nreferences(app_port):")
    for loc in refs2["result"]:
        print("  ", loc["uri"].replace(uri(ROOT) + "/", ""), loc["range"]["start"])

    proc.stdin.write(frame({"jsonrpc": "2.0", "id": 99, "method": "shutdown"}))
    proc.stdin.write(frame({"jsonrpc": "2.0", "method": "exit"}))
    proc.stdin.flush()
    proc.wait(timeout=5)


if __name__ == "__main__":
    main()
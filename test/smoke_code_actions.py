#!/usr/bin/env python3
"""Smoke-test the debug code actions over stdio."""
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


def code_actions(proc, req_id, path, line, character):
    proc.stdin.write(frame({"jsonrpc": "2.0", "id": req_id, "method": "textDocument/codeAction", "params": {
        "textDocument": {"uri": uri(path)},
        "range": {"start": {"line": line, "character": character},
                  "end": {"line": line, "character": character}},
        "context": {"diagnostics": []},
    }}))
    proc.stdin.flush()
    return read_response(proc, req_id)


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
    print("codeActionProvider:", caps.get("codeActionProvider"))

    proc.stdin.write(frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}))
    proc.stdin.flush()

    tasks = os.path.join(ROOT, "test/fixtures/roles/demo/tasks/main.yml")
    with open(tasks) as f:
        text = f.read()
    proc.stdin.write(frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": uri(tasks), "languageId": "ansible", "version": 1, "text": text},
    }}))
    proc.stdin.flush()

    # Cursor on `app_result` in `register: app_result` (line 8).
    line = text.splitlines()[8]
    col = line.index("app_result")
    resp = code_actions(proc, 2, tasks, 8, col)
    print("\ncodeAction(register: app_result):")
    for act in resp["result"]:
        print("  ", act["title"], "->", repr(act["edit"]["documentChanges"][0]["edits"][0]["newText"]))

    # Cursor inside the first debug task (line 2, the module key).
    resp = code_actions(proc, 3, tasks, 2, 2)
    print("\ncodeAction(debug task):")
    for act in resp["result"]:
        print("  ", act["title"], "->", act["edit"]["documentChanges"][0]["edits"][0]["range"])

    proc.stdin.write(frame({"jsonrpc": "2.0", "id": 99, "method": "shutdown"}))
    proc.stdin.write(frame({"jsonrpc": "2.0", "method": "exit"}))
    proc.stdin.flush()
    proc.wait(timeout=5)


if __name__ == "__main__":
    main()
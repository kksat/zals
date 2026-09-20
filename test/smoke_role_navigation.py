#!/usr/bin/env python3
"""Smoke-test role go-to-definition and go-to-implementation over stdio."""
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


def open_doc(proc, path, text):
    proc.stdin.write(frame({"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": {
        "textDocument": {"uri": uri(path), "languageId": "ansible", "version": 1, "text": text},
    }}))
    proc.stdin.flush()


def request(proc, req_id, method, path, line, character):
    proc.stdin.write(frame({"jsonrpc": "2.0", "id": req_id, "method": method, "params": {
        "textDocument": {"uri": uri(path)},
        "position": {"line": line, "character": character},
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
    print("definitionProvider:", caps.get("definitionProvider"))
    print("implementationProvider:", caps.get("implementationProvider"))

    proc.stdin.write(frame({"jsonrpc": "2.0", "method": "initialized", "params": {}}))
    proc.stdin.flush()

    playbook = os.path.join(ROOT, "test/fixtures/playbook.yml")
    with open(playbook) as f:
        text = f.read()
    open_doc(proc, playbook, text)

    # Locate the role name in `- role: demo`.
    line_no = next(i for i, l in enumerate(text.splitlines()) if "role: demo" in l)
    col = text.splitlines()[line_no].index("demo")

    defn = request(proc, 2, "textDocument/definition", playbook, line_no, col)
    print("\ndefinition(role demo):", json.dumps(defn.get("result")))
    impl = request(proc, 3, "textDocument/implementation", playbook, line_no, col)
    print("implementation(role demo):", json.dumps(impl.get("result")))

    # include_role form in a synthetic document next to the fixtures.
    synthetic = os.path.join(ROOT, "test/fixtures/role_nav_playbook.yml")
    synthetic_text = (
        "---\n"
        "- hosts: all\n"
        "  tasks:\n"
        "    - include_role:\n"
        "        name: demo\n"
    )
    open_doc(proc, synthetic, synthetic_text)
    inc_line = next(i for i, l in enumerate(synthetic_text.splitlines()) if "name: demo" in l)
    inc_col = synthetic_text.splitlines()[inc_line].index("demo")
    inc_defn = request(proc, 4, "textDocument/definition", synthetic, inc_line, inc_col)
    print("\ndefinition(include_role demo):", json.dumps(inc_defn.get("result")))
    inc_impl = request(proc, 5, "textDocument/implementation", synthetic, inc_line, inc_col)
    print("implementation(include_role demo):", json.dumps(inc_impl.get("result")))

    proc.stdin.write(frame({"jsonrpc": "2.0", "id": 99, "method": "shutdown"}))
    proc.stdin.write(frame({"jsonrpc": "2.0", "method": "exit"}))
    proc.stdin.flush()
    proc.wait(timeout=5)


if __name__ == "__main__":
    main()
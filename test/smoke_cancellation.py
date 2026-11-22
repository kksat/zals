#!/usr/bin/env python3
"""$/cancelRequest must skip a not-yet-dispatched request with -32800.

The cancel is written before its request so the FIFO pipe makes the outcome
deterministic: the server records the cancel, then answers that request with
LSP RequestCancelled instead of computing it. An uncanceled request still
answers normally. Run after `make build`; no Ansible installation is needed.
"""
import os
import sys
import tempfile
import time
from pathlib import Path

import smoke_cold_start
from smoke_workspace import BIN, frame


def request_with_id(client, request_id, method, params):
    """A request whose response may carry a result or an error object."""
    client.proc.stdin.write(frame({"jsonrpc": "2.0", "id": request_id,
                                   "method": method, "params": params}))
    client.proc.stdin.flush()
    deadline = time.monotonic() + 2
    while True:
        message = client.read(max(0, deadline - time.monotonic()))
        if message.get("id") == request_id:
            return message


def main():
    smoke_cold_start.BIN = BIN
    with tempfile.TemporaryDirectory(prefix="zals-cancel-") as tmp:
        root = Path(tmp).resolve()
        (root / ".git").mkdir()
        env = dict(os.environ, HOME=str(root), XDG_CACHE_HOME=str(root / ".cache"))
        env.pop("VIRTUAL_ENV", None)
        client = smoke_cold_start.Client(str(root), env)
        try:
            client.request("initialize", {"processId": None, "rootUri": root.as_uri(),
                                          "capabilities": {}})
            client.notify("initialized", {})

            client.notify("$/cancelRequest", {"id": 41})
            cancelled = request_with_id(client, 41, "workspace/symbol", {"query": ""})
            assert "result" not in cancelled and cancelled["error"]["code"] == -32800, cancelled
            print("ok   cancelled request answered with RequestCancelled")

            normal = request_with_id(client, 42, "workspace/symbol", {"query": ""})
            assert "error" not in normal and "result" in normal, normal
            print("ok   uncanceled request answered normally")
        finally:
            client.close()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Shutdown must cancel an in-flight docs subprocess, not wait for its output."""

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import smoke_cold_start


def check_shutdown(binary, stage, close_output=False):
    with tempfile.TemporaryDirectory(prefix="zals-shutdown-") as tmp:
        root = Path(tmp).resolve()
        (root / ".git").mkdir()
        (root / "bin").mkdir()
        script = f'''#!{sys.executable}
import json
import os
from pathlib import Path
import signal
import sys
import time
root = Path({str(root)!r})
command = Path(sys.argv[0]).name
if command == "ansible-config":
    stage = "config"
elif command == "ansible":
    stage = "module-version"
elif "--version" in sys.argv:
    stage = "fingerprint"
elif "-l" in sys.argv:
    stage = "catalog"
else:
    stage = "prefetch"
if stage == {stage!r}:
    if os.name == "posix":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    (root / "started").write_text(str(os.getpid()))
    if {close_output!r}:
        os.close(1)
        os.close(2)
    while not (root / "release").exists():
        time.sleep(.01)
if stage == "fingerprint":
    print("ansible-doc [core shutdown-test]")
elif stage == "catalog":
    print(json.dumps({{"ansible.builtin.debug": "Display a message"}}))
elif stage == "config":
    print("COLLECTIONS_PATHS(default) = []")
elif stage == "module-version":
    print("ansible [core shutdown-test]")
else:
    print("{{}}")
'''
        for command in ("ansible-doc", "ansible-config", "ansible"):
            tool = root / "bin" / command
            tool.write_text(script)
            tool.chmod(0o755)
        env = dict(os.environ, PATH=str(root / "bin"), HOME=str(root),
                   XDG_CACHE_HOME=str(root / ".cache"))
        env.pop("VIRTUAL_ENV", None)
        smoke_cold_start.BIN = binary
        client = smoke_cold_start.Client(str(root), env)
        try:
            client.request("initialize", {"processId": None, "rootUri": root.as_uri(),
                                          "capabilities": {}})
            client.notify("initialized", {})
            deadline = time.monotonic() + 3
            while not (root / "started").exists() and time.monotonic() < deadline:
                time.sleep(.01)
            assert (root / "started").exists(), f"{stage} helper did not start"
            client.request("shutdown", None)
            client.notify("exit", None)
            try:
                client.proc.wait(timeout=1)
            except subprocess.TimeoutExpired as exc:
                raise AssertionError(f"shutdown waited for blocked {stage} subprocess") from exc
            assert client.proc.returncode == 0, client.proc.returncode
            assert not (root / "release").exists(), "test released the subprocess early"
            if os.name == "posix":
                child_pid = int((root / "started").read_text())
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError(f"cancelled {stage} child was not reaped")
            suffix = " with closed output streams" if close_output else ""
            print(f"ok   shutdown cancels blocked {stage}{suffix}")
        finally:
            # Let an unfixed server finish teardown without leaking a test helper.
            (root / "release").touch()
            try:
                client.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                client.proc.kill()
                client.proc.wait()
            client.reader.join(timeout=2)
            client.proc.stdin.close()
            client.proc.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=smoke_cold_start.BIN)
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    for stage in ("fingerprint", "catalog", "config", "module-version", "prefetch"):
        check_shutdown(binary, stage)
    check_shutdown(binary, "fingerprint", close_output=True)


if __name__ == "__main__":
    main()

"""zals warm fork server.

Idea from speedrunner (https://github.com/anthonyGosme/speedrunner): a CLI
tool's cost is dominated by interpreter startup and imports, so load the tool
once in a daemon and serve every invocation from a forked child that runs the
tool's console script in-process via runpy. The child keeps everything the
daemon preloaded (copy-on-write), so a call pays neither startup nor imports.

Started by zals with the tool's own interpreter:

    <python> warm_daemon.py --script PATH [--preload M1,M2] [--no-warmup]

The console script at PATH must be a Python script (its interpreter is what
zals launches us with). --preload names modules to import eagerly; without
them the daemon still serves, just colder. Unless --no-warmup is given, the
daemon first runs the script with `--version` in-process (output discarded)
so runtime caches the tool builds while answering --version are warm in every
fork.

Protocol over stdin/stdout (fds 0 and 1), stdout written with os.write only:

    zals    -> daemon  one JSON line: {"argv": [...], "env": {...}?,
                                    "cwd": "..."?}
               env, when present, replaces the child's environment wholesale;
               cwd, when present, is chdir'd to before the tool runs.
    daemon  -> zals    b"+" once preloaded and warmed, then per request:
               b"R" + i32 exit + u64 stdout len + u64 stderr len + bytes
               exit is the wait status: >= 0 is an exit code, < 0 negates the
               terminating signal. b"E" + u32 len + message is a daemon-level
               failure (fork, bad request); zals then runs the call natively.

Standard library only. POSIX only (fork). The child redirects fds 0-2 before
running the tool, so tool output reaches zals byte-for-byte and nothing can
consume the request stream.

Requests are served strictly one at a time; zals serializes callers.
"""

import json
import os
import runpy
import selectors
import struct
import sys
import traceback

READY = b"+"
REPLY_RESULT = b"R"
REPLY_ERROR = b"E"
MAX_REQUEST_BYTES = 1 << 20  # argv/env/cwd JSON; tool output is uncapped


def log(msg):
    """Best-effort trace to stderr (inherited from zals). Never fatal."""
    try:
        sys.stderr.write("zals-warm: %s\n" % msg)
        sys.stderr.flush()
    except Exception:
        pass


def write_all(fd, data):
    while data:
        data = data[os.write(fd, data):]


def read_request_line(fd):
    """Read one newline-terminated request; None on EOF. Caps total size."""
    buf = b""
    while b"\n" not in buf:
        if len(buf) > MAX_REQUEST_BYTES:
            raise ValueError("request too large")
        chunk = os.read(fd, 65536)
        if not chunk:
            return None
        buf += chunk
    line, _, rest = buf.partition(b"\n")
    if rest:
        raise ValueError("trailing bytes after request line")
    return line


def apply_env(env):
    """Replace the environment wholesale (copies are per-fork, so this is
    safe). Values the interpreter reads only at startup cannot be honored
    in a fork; zals never varies those between daemon start and a call."""
    for key in list(os.environ):
        if key not in env:
            del os.environ[key]
    for key, value in env.items():
        os.environ[key] = value


def reset_ansible_state():
    """Re-derive ansible's import-time constants in this forked child.

    Fork fidelity shim. `ansible.constants` resolves every setting once at
    import: env-dependent values (collections paths, the per-process local
    tmp directory, ...) are frozen into module globals, and the tmp directory
    comes with an atexit cleanup. A forked child inherits both, so a caller's
    env override would be ignored, and the first child's exit would delete the
    tmp directory every later child still uses. Re-running the loop from
    `ansible/constants.py` against this child's environment (about a
    millisecond once the config manager is warm) restores native behaviour:
    constants match the request env, and each child owns a fresh tmp directory
    whose cleanup runs at this child's exit. The inherited handler for the
    daemon's directory then does the daemon's cleanup for it. No-op when
    ansible is not importable.
    """
    try:
        from ansible import constants as C
    except ImportError:
        return
    try:
        for setting in C.config.get_configuration_definitions():
            C.set_constant(setting, C.config.get_config_value(setting, variables=vars(C)))
    except Exception:
        pass


def run_tool(script, argv, env, cwd):
    """In a forked child: run the console script as __main__ and _exit.

    Never returns. Output goes to the fds zals wired up (see serve()); SystemExit
    and exit codes are preserved, unexpected errors print a traceback (to the
    captured stderr, like a native crash would) and exit 1.
    """
    code = 1
    try:
        if env is not None:
            apply_env(env)
        if cwd:
            os.chdir(cwd)
        reset_ansible_state()
        sys.argv = [str(a) for a in argv]
        try:
            runpy.run_path(script, run_name="__main__")
            code = 0
        except SystemExit as exc:
            if exc.code is None:
                code = 0
            elif isinstance(exc.code, int):
                code = exc.code
            else:
                code = 1
        except BaseException:
            traceback.print_exc()
            code = 1
        try:
            sys.stdout.flush()
            sys.stderr.flush()
        except Exception:
            pass
        # The tool may have registered exit handlers during the run; a native
        # exit would run them. The daemon itself registers none.
        try:
            import atexit

            atexit._run_exitfuncs()
        except Exception:
            pass
    except BaseException:
        code = 70
    os._exit(code & 0xFF if code >= 0 else 1)


def drain(fds):
    """Read every pipe to EOF (selectors: no deadlock on full pipes)."""
    chunks = {fd: bytearray() for fd in fds}
    sel = selectors.SelectSelector()
    for fd in fds:
        sel.register(fd, selectors.EVENT_READ)
    open_fds = set(fds)
    while open_fds:
        for key, _ in sel.select():
            fd = key.fd
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            if data:
                chunks[fd] += data
            else:
                sel.unregister(fd)
                open_fds.discard(fd)
    for fd in fds:
        os.close(fd)
    return chunks


def serve(script, warmup):
    tool = os.path.basename(script)
    if warmup:
        # Run `--version` in-process with fds 1/2 discarded: warms runtime
        # state (config, plugin loader caches) that lives past the call.
        devnull = os.open(os.devnull, os.O_WRONLY)
        saved_out, saved_err = os.dup(1), os.dup(2)
        try:
            sys.stdout.flush()
            sys.stderr.flush()
            os.dup2(devnull, 1)
            os.dup2(devnull, 2)
            sys.argv = [tool, "--version"]
            try:
                runpy.run_path(script, run_name="__main__")
            except SystemExit:
                pass
            except BaseException:
                pass  # a tool that cannot even answer --version still serves
            # Discard whatever the warmup left in the block-buffered
            # sys.stdout/sys.stderr while the fds still point at devnull,
            # or the first forked child would inherit and flush it into the
            # tool's captured output.
            try:
                sys.stdout.flush()
                sys.stderr.flush()
            except Exception:
                pass
        finally:
            os.dup2(saved_out, 1)
            os.dup2(saved_err, 2)
            os.close(devnull)
            os.close(saved_out)
            os.close(saved_err)
            sys.argv = [tool]
    write_all(1, READY)

    while True:
        try:
            line = read_request_line(0)
        except (OSError, ValueError) as exc:
            log("request read failed: %r" % (exc,))
            return
        if line is None:
            return  # zals closed the pipe: normal shutdown
        try:
            request = json.loads(line.decode("utf-8"))
            argv = [str(a) for a in request["argv"]]
            env = request.get("env")
            if env is not None:
                env = {str(k): str(v) for k, v in env.items()}
            cwd = request.get("cwd")
        except (ValueError, KeyError, TypeError) as exc:
            write_all(1, REPLY_ERROR + struct.pack("<I", len(repr(exc))) + repr(exc).encode())
            continue

        out_r, out_w = os.pipe()
        err_r, err_w = os.pipe()
        try:
            pid = os.fork()
        except OSError as exc:
            os.close(out_r)
            os.close(out_w)
            os.close(err_r)
            os.close(err_w)
            msg = ("fork: %s" % exc).encode()
            write_all(1, REPLY_ERROR + struct.pack("<I", len(msg)) + msg)
            continue
        if pid == 0:
            os.close(out_r)
            os.close(err_r)
            os.dup2(out_w, 1)
            os.dup2(err_w, 2)
            os.close(out_w)
            os.close(err_w)
            stdin = os.open(os.devnull, os.O_RDONLY)
            os.dup2(stdin, 0)
            os.close(stdin)
            run_tool(script, argv, env, cwd)  # never returns
        os.close(out_w)
        os.close(err_w)
        chunks = drain((out_r, err_r))
        _, status = os.waitpid(pid, 0)
        if os.WIFEXITED(status):
            code = os.WEXITSTATUS(status)
        elif os.WIFSIGNALED(status):
            code = -os.WTERMSIG(status)
        else:
            code = -127
        stdout = bytes(chunks[out_r])
        stderr = bytes(chunks[err_r])
        write_all(
            1,
            REPLY_RESULT + struct.pack("<iQQ", code, len(stdout), len(stderr)) + stdout + stderr,
        )


def main():
    # Own a process group so zals can cancel a whole call (daemon + tool
    # child) with one killpg. Before any fork, so every child inherits it.
    try:
        os.setpgid(0, 0)
    except OSError:
        pass
    script = None
    preload = []
    warmup = True
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--script" and i + 1 < len(args):
            script = args[i + 1]
            i += 2
        elif args[i] == "--preload" and i + 1 < len(args):
            preload = [m for m in args[i + 1].split(",") if m]
            i += 2
        elif args[i] == "--no-warmup":
            warmup = False
            i += 1
        else:
            sys.stderr.write("zals-warm: bad argument %r\n" % (args[i],))
            return 2
    if not script or not os.path.isfile(script):
        sys.stderr.write("zals-warm: --script PATH required\n")
        return 2
    for module in preload:
        try:
            __import__(module)
        except BaseException as exc:
            # Preload is an optimization; a module that cannot import now may
            # still import in the child (or fail there exactly like native).
            log("preload %s failed: %r" % (module, exc))
    serve(script, warmup)
    return 0


if __name__ == "__main__":
    sys.exit(main())

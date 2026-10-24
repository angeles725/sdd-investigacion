"""Parity driver for internal/core/fsx: runs the REAL Python helpers and prints one JSON object.

usage: python3 -I parity_driver.py <toolbelt-dir> <op> [args...]

The Go parity test runs the same operation on the same fixture and compares.
Ops: identity, identity_append, stage, publish, exchange, write, open_ro,
open_wo_new, sha256_fd.
"""
import errno
import json
import os
import stat
import sys

toolbelt = sys.argv[1]
sys.path.insert(0, toolbelt)
sys.path.insert(0, os.path.join(toolbelt, "lib"))
import adapter_core  # noqa: E402
import corroborate_java  # noqa: E402
from pathlib import Path  # noqa: E402
import niagara_hdb_read  # noqa: E402

op, args = sys.argv[2], sys.argv[3:]


def fail(exc):
    out = {"ok": False, "class": type(exc).__name__, "msg": str(exc)}
    if isinstance(exc, OSError) and exc.errno is not None:
        out["errno"] = exc.errno
    elif isinstance(exc.__cause__, OSError):
        out["errno"] = exc.__cause__.errno
    return out


def run():
    if op == "identity":
        cap = int(args[1]) if len(args) > 1 else None
        resolved, size, digest = adapter_core.identity(__import__("pathlib").Path(args[0]), cap)
        return {"ok": True, "resolved": str(resolved), "size": size, "sha256": digest}
    if op == "identity_append":
        real_read, state = os.read, {"n": 0}

        def hooked(fd, n):
            data = real_read(fd, n)
            state["n"] += 1
            if state["n"] == 1:
                with open(args[0], "ab") as f:
                    f.write(b"more")
            return data

        os.read = hooked
        try:
            resolved, size, digest = adapter_core.identity(__import__("pathlib").Path(args[0]))
        finally:
            os.read = real_read
        return {"ok": True, "resolved": str(resolved), "size": size, "sha256": digest}
    if op == "open_ro":
        fd = niagara_hdb_read._open_ro(args[0])
        try:
            st = os.fstat(fd)
            return {"ok": True, "regular": stat.S_ISREG(st.st_mode), "size": st.st_size}
        finally:
            os.close(fd)
    if op == "open_wo_new":
        fd = niagara_hdb_read._open_wo_new(args[0])
        try:
            os.write(fd, b"x")
            return {"ok": True, "mode": stat.S_IMODE(os.fstat(fd).st_mode)}
        finally:
            os.close(fd)
    if op == "sha256_fd":
        fd = os.open(args[0], os.O_RDONLY)
        try:
            os.read(fd, 1000)
            return {"ok": True, "sha256": niagara_hdb_read._sha256_fd(fd)}
        finally:
            os.close(fd)
    if op == "publish":
        adapter_core.publish(Path(args[0]), Path(args[1]))
        return {"ok": True}
    if op == "exchange":
        corroborate_java.renameat2(Path(args[0]), Path(args[1]), 2)
        return {"ok": True}
    if op == "write":
        adapter_core.write(Path(args[0]), json.loads(args[1]))
        return {"ok": True, "mode": stat.S_IMODE(os.stat(args[0]).st_mode)}
    if op in ("stage", "stage_append"):
        src, dst, logical, mode = args[0], args[1], args[2], int(args[3], 8)
        cap = int(args[4]) if len(args) > 4 else None
        real_read, state = os.read, {"n": 0}

        def hooked(fd, n):
            data = real_read(fd, n)
            state["n"] += 1
            if state["n"] == 1 and op == "stage_append":
                with open(src, "ab") as f:
                    f.write(b"more")
            return data

        os.read = hooked
        try:
            s_rec, d_rec = adapter_core.stage_file(Path(src), Path(dst), logical, mode, cap)
        finally:
            os.read = real_read
        return {"ok": True, "src": s_rec, "staged": d_rec, "mode": stat.S_IMODE(os.stat(dst).st_mode)}
    raise SystemExit("unknown op " + op)


try:
    result = run()
except Exception as exc:  # noqa: BLE001 - the driver reports every failure class
    result = fail(exc)
print(json.dumps(result, sort_keys=True))

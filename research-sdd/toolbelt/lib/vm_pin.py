#!/usr/bin/env python3
"""Plan-identity pin for VM executors (#2078 / #2090): bind exec to the bytes the plan hashed.

Executors that hand a host file to bwrap by PATH (qemu kernel, detonate/trace sample) are open to a
plan->exec swap: the plan recorded sha256/size, exec never re-checks, and the path can change in
between.  pin_file() opens the path ONCE (O_NOFOLLOW), fstat-checks it, copies those exact bytes into
a private stage dir while hashing, and refuses unless sha256/size equal the plan's.  rebind_source()
then rewrites the single `--ro-bind <path> <dest>` source to the verified copy.
"""
from __future__ import annotations
import hashlib, os, stat
from typing import Any

from gate import GateError


def pin_file(path: str, want_sha: Any, want_size: Any, stage: str, what: str, action: str,
             name: str = "target") -> str:
    """Copy *path* into *stage* (file 0400, O_EXCL) and return the copy's path.

    GateError when the path cannot be opened without following symlinks, is not a regular file, or
    its size/sha256 differ from the plan's.  *what* names the object ("kernel/target", "sample");
    *action* completes "refusing to <action> <path>"; *name* is the copy's file name in *stage*.
    """
    cloexec = getattr(os, "O_CLOEXEC", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, os.O_RDONLY | nofollow | cloexec)
    except OSError as exc:
        raise GateError(f"{what} cannot be opened without following symlinks: {exc}") from exc
    dest = os.path.join(stage, name)
    h = hashlib.sha256(); size = 0

    def _changed(detail: str) -> GateError:
        return GateError(f"{what} changed since plan ({detail}); refusing to {action} {path!r}")

    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise GateError(f"{what} is not a regular file: {path!r}")
        if want_size is not None and st.st_size != want_size:
            raise _changed(f"size {st.st_size} != planned {want_size}")
        try:
            out = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow | cloexec, 0o400)
        except OSError as exc:
            raise GateError(f"cannot create the private copy of {what}: {exc}") from exc
        try:
            while True:
                chunk = os.read(fd, 1 << 16)
                if not chunk:
                    break
                h.update(chunk); size += len(chunk)
                view = memoryview(chunk)
                while view:
                    view = view[os.write(out, view):]
        finally:
            os.close(out)
    finally:
        os.close(fd)
    want = str(want_sha or "").removeprefix("sha256:")
    if not want or h.hexdigest() != want or (want_size is not None and size != want_size):
        raise _changed(f"identity mismatch: sha256 {h.hexdigest()}, size {size}")
    return dest


def rebind_source(argv: list[str], path: str, dest: str) -> list[str]:
    """Rewrite the `--ro-bind <path> ...` source to *dest*; exactly one substitution or GateError."""
    out = [dest if (a == path and i > 0 and argv[i - 1] == "--ro-bind") else a
           for i, a in enumerate(argv)]
    n_sub = sum(1 for a, b in zip(argv, out) if a != b)
    if n_sub != 1:
        raise GateError(f"expected exactly one --ro-bind source {path!r} in planned_argv, found {n_sub}")
    return out

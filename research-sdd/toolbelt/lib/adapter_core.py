#!/usr/bin/env python3
"""Shared adapter-core primitives for Research-SDD toolbelt adapters.

All primitives that were duplicated across corroborate_*.py are centralised
here so that item-24 can migrate adapters via pure deletion + import.

Hardening invariants (correcting known weaknesses in the shipped adapters):
- require_private() is a WHITELIST (fail-closed): unlisted / unknown FS types
  are rejected, not silently accepted.  This upgrades corroborate_native.py
  (blacklist) and corroborate_ghidra.py (blacklist) to whitelist semantics.
- sandbox() / isolation_prefix() ALWAYS includes --cap-drop ALL and
  --unshare-pid.  This fixes the omissions in corroborate_native.py and
  corroborate_java.py.
- Malformed /proc/self/mountinfo lines raise AdapterError (no raw traceback).
"""
from __future__ import annotations

import ctypes
import hashlib
import json
import os
import resource
import shutil
import signal
import stat
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Known-private Linux filesystem types (whitelist, fail-closed).
# Anything NOT in this set is rejected by require_private().
# ---------------------------------------------------------------------------
PRIVATE_FS: frozenset[str] = frozenset({
    "btrfs", "ext2", "ext3", "ext4", "f2fs", "jfs", "nilfs2",
    "overlay", "ramfs", "reiserfs", "tmpfs", "ubifs", "xfs", "zfs",
})


# ---------------------------------------------------------------------------
# Base exception
# ---------------------------------------------------------------------------

class AdapterError(ValueError):
    """Base exception for all Research-SDD adapter errors (fail-closed).

    Adapters may subclass this for adapter-specific names:

        class NativeError(AdapterError): pass
    """


# ---------------------------------------------------------------------------
# Canonical serialisation
# ---------------------------------------------------------------------------

def canonical_bytes(value: Any) -> bytes:
    """Deterministic canonical JSON: sort_keys, no spaces, UTF-8 newline."""
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


# Alias: corroborate_firmware.py / corroborate_ghidra.py call this `canonical`.
canonical = canonical_bytes


# ---------------------------------------------------------------------------
# File identity
# ---------------------------------------------------------------------------

def identity(path: Path, max_bytes: int | None = None) -> tuple[Path, int, str]:
    """Open *path* with O_NOFOLLOW, hash it, and return (resolved, size, sha256).

    Raises AdapterError on:
    - symlinks (O_NOFOLLOW)
    - non-regular files
    - TOCTOU change (pre/post-read fstat mismatch)
    - size exceeding max_bytes
    """
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise AdapterError(f"cannot open regular non-symlink file: {path}") from exc
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise AdapterError(f"not a regular file: {path}")
        if max_bytes is not None and before.st_size > max_bytes:
            raise AdapterError("input exceeds max-input-bytes")
        resolved = Path(f"/proc/self/fd/{fd}").resolve()
        digest = hashlib.sha256()
        total = 0
        chunk_size = 1024 * 1024
        while chunk := os.read(fd, chunk_size if max_bytes is None else min(chunk_size, max_bytes - total + 1)):
            total += len(chunk)
            if max_bytes is not None and total > max_bytes:
                raise AdapterError("input exceeds max-input-bytes")
            digest.update(chunk)
        after = os.fstat(fd)
        fields = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
        if fields(before) != fields(after) or total != before.st_size:
            raise AdapterError(f"file changed while hashing: {path}")
        return resolved, total, "sha256:" + digest.hexdigest()
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# Trusted staging
# ---------------------------------------------------------------------------

def stage_file(
    source: Path,
    target: Path,
    logical: str,
    mode: int,
    max_bytes: int | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Copy *source* → *target* with O_NOFOLLOW + O_EXCL, verify TOCTOU, confirm
    staged identity.

    Returns ``(source_record, staged_record)`` dicts with path/size/sha256.
    Raises AdapterError on symlinks, TOCTOU changes, or identity mismatch.
    """
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        src = os.open(source, flags)
    except OSError as exc:
        raise AdapterError("source cannot be opened safely") from exc
    digest = hashlib.sha256()
    total = 0
    chunk_size = 1024 * 1024
    try:
        before = os.fstat(src)
        if not stat.S_ISREG(before.st_mode):
            raise AdapterError("source is not a regular file")
        if max_bytes is not None and before.st_size > max_bytes:
            raise AdapterError("input exceeds max-input-bytes")
        resolved = Path(f"/proc/self/fd/{src}").resolve()
        out = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0), 0o600)
        try:
            while chunk := os.read(src, chunk_size if max_bytes is None else min(chunk_size, max_bytes - total + 1)):
                total += len(chunk)
                if max_bytes is not None and total > max_bytes:
                    raise AdapterError("input exceeds max-input-bytes")
                digest.update(chunk)
                view = memoryview(chunk)
                while view:
                    view = view[os.write(out, view):]
            os.fsync(out)
        finally:
            os.close(out)
        after = os.fstat(src)
        fields = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
        if fields(before) != fields(after) or total != before.st_size:
            raise AdapterError("source changed while staging")
    finally:
        os.close(src)
    digest_text = "sha256:" + digest.hexdigest()
    _, staged_size, staged_digest = identity(target, max_bytes)
    if (staged_size, staged_digest) != (total, digest_text):
        raise AdapterError("staged identity mismatch")
    target.chmod(mode)
    return (
        {"path": str(resolved), "size": total, "sha256": digest_text},
        {"path": logical, "size": staged_size, "sha256": staged_digest},
    )


# ---------------------------------------------------------------------------
# Executable resolution
# ---------------------------------------------------------------------------

def executable(name: str, configured: str | None, search: str) -> tuple[Path, dict[str, Any]]:
    """Resolve a trusted executable by PATH and optional configured override.

    When *configured* is None the PATH-selected binary is used directly.
    Raises AdapterError if the binary is missing or the paths disagree.

    Signature accepts ``configured: str | None`` (corroborate_native.py style)
    which is a superset of the ``configured: str`` style in corroborate_firmware.py.
    """
    selected = shutil.which(name, path=search)
    if selected is None:
        raise AdapterError(f"PATH-selected {name} is missing")
    candidate = Path(configured or selected).resolve(strict=True)
    selected_path = Path(selected).resolve(strict=True)
    if (
        not candidate.is_file()
        or not os.access(candidate, os.X_OK)
        or not os.path.samefile(candidate, selected_path)
    ):
        raise AdapterError(f"configured {name} does not match PATH-selected executable")
    resolved, size, digest = identity(candidate)
    return resolved, {"path": str(resolved), "size": size, "sha256": digest}


# ---------------------------------------------------------------------------
# Private-filesystem guard (fail-closed whitelist)
# ---------------------------------------------------------------------------

def require_private(path: Path, mountinfo: str | None = None) -> None:
    """Verify *path* resides on a Linux-private filesystem.

    Policy: WHITELIST (fail-closed).  Any filesystem type NOT in PRIVATE_FS
    is rejected, including unknown types.  This is stricter than the blacklist
    in corroborate_native.py and corroborate_ghidra.py.

    *mountinfo*: optional string content for testability (default: read
    /proc/self/mountinfo).  Malformed lines raise AdapterError with a
    descriptive message — raw ValueError/IndexError never propagate.
    """
    if mountinfo is None:
        mountinfo = Path("/proc/self/mountinfo").read_text()

    selected: tuple[int, str] = (-1, "")

    for line in mountinfo.splitlines():
        try:
            left, right = line.split(" - ", 1)
        except ValueError as exc:
            raise AdapterError(f"malformed mountinfo line (missing ' - ' separator): {line!r}") from exc

        try:
            left_fields = left.split()
            if len(left_fields) < 5:
                raise AdapterError(f"malformed mountinfo line (too few left fields): {line!r}")
            encoded = left_fields[4]
            mount = Path(
                encoded.replace("\\040", " ").replace("\\011", "\t").replace("\\134", "\\")
            )
            right_fields = right.split()
            if not right_fields:
                raise AdapterError(f"malformed mountinfo line (empty right side): {line!r}")
            fs = right_fields[0]
        except AdapterError:
            raise
        except (IndexError, ValueError) as exc:
            raise AdapterError(f"malformed mountinfo line: {line!r}") from exc

        try:
            path.relative_to(mount)
        except ValueError:
            continue

        if len(mount.parts) > selected[0]:
            selected = (len(mount.parts), fs)

    if selected[1] not in PRIVATE_FS:
        raise AdapterError("output must reside on a Linux-private filesystem")


# ---------------------------------------------------------------------------
# Bubblewrap sandbox (hardened isolation prefix)
# ---------------------------------------------------------------------------

def sandbox(bwrap: Path, env: dict[str, str]) -> list[str]:
    """Build a hardened bwrap argv with the full isolation profile.

    Required flags (fixing weaknesses in corroborate_native.py / _java.py):
      --cap-drop ALL     drop all Linux capabilities
      --unshare-pid      new PID namespace
      --unshare-net      network isolation
      --die-with-parent  child dies when parent exits
      --new-session      detach from terminal

    Raises AdapterError if /tmp/rsdd is unsafe (symlink, wrong owner, world-writable).
    """
    root = Path("/tmp/rsdd")
    root.mkdir(mode=0o700, exist_ok=True)
    meta = root.lstat()
    if stat.S_ISLNK(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o077:
        raise AdapterError("unsafe Bubblewrap mountpoint")
    command = [
        str(bwrap),
        "--die-with-parent", "--new-session",
        "--unshare-net", "--unshare-pid",
        "--cap-drop", "ALL",
        "--ro-bind", "/", "/",
        "--proc", "/proc",
        "--dev", "/dev",
        "--tmpfs", "/tmp/rsdd",
        "--dir", "/tmp/rsdd/home",
        "--dir", "/tmp/rsdd/cache",
        "--dir", "/tmp/rsdd/config",
        "--dir", "/tmp/rsdd/data",
        "--dir", "/tmp/rsdd/work",
        "--ro-bind", ".", "/tmp/rsdd/work",
    ]
    for key, value in env.items():
        command += ["--setenv", key, value]
    return command + ["--chdir", "/tmp/rsdd/work", "--"]


# Alias: corroborate_native.py calls the sandbox builder ``isolation_prefix``.
# Item-24 migration renames the call site; until then this alias is the bridge.
isolation_prefix = sandbox


# ---------------------------------------------------------------------------
# Process-tree utilities (used by run_bounded)
# ---------------------------------------------------------------------------

def tree_size(root: int) -> int:
    """Count live descendants of PID *root* (inclusive) via /proc."""
    parents: dict[int, int] = {}
    for p in Path("/proc").glob("[0-9]*/stat"):
        try:
            raw = p.read_text().rsplit(")", 1)[1].split()
            parents[int(p.parent.name)] = int(raw[1])
        except (OSError, IndexError, ValueError):
            pass
    descendants = {root}
    while True:
        expanded = descendants | {pid for pid, ppid in parents.items() if ppid in descendants}
        if expanded == descendants:
            return len(descendants & parents.keys())
        descendants = expanded


def stop_group(group: int) -> None:
    """SIGTERM then SIGKILL the process group and wait for all descendants."""
    for sig, delay in ((signal.SIGTERM, 0.5), (signal.SIGKILL, 0.5)):
        try:
            os.killpg(group, sig)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + delay
        while time.monotonic() < deadline and tree_size(group):
            time.sleep(0.01)


# ---------------------------------------------------------------------------
# Bounded subprocess execution
# ---------------------------------------------------------------------------

def run_bounded(
    command: list[str],
    cwd: Path,
    env: dict[str, str],
    timeout: int,
    max_bytes: int,
    max_processes: int = 0,
) -> tuple[dict[str, Any], list[str]]:
    """Run *command* under wall-clock timeout, output-cap, and optional process cap.

    Output is written to ``cwd/engine/stdout.txt`` and ``cwd/engine/stderr.txt``.
    Returns ``(run_record, error_list)``.

    Enforced limits:
    - ``timeout`` seconds wall-clock  → error ``"timeout"``
    - combined stdout+stderr > ``max_bytes`` → error ``"output-cap"``
    - process-tree depth > ``max_processes`` (when > 0) → error ``"process-cap"``
    - RLIMIT_FSIZE preexec (defense-in-depth, best-effort)

    When a cap fires, both output files are jointly truncated to ``max_bytes``.
    """
    out_path = cwd / "engine/stdout.txt"
    err_path = cwd / "engine/stderr.txt"
    wall_start = datetime.now(timezone.utc)
    mono_start = time.monotonic()
    reason = ""

    def _preexec() -> None:
        try:
            hard = resource.getrlimit(resource.RLIMIT_FSIZE)[1]
            cap = max_bytes if hard == resource.RLIM_INFINITY else min(max_bytes, hard)
            resource.setrlimit(resource.RLIMIT_FSIZE, (cap, cap))
        except Exception:
            pass  # best-effort; polling loop is the primary enforcement

    with out_path.open("wb") as stdout, err_path.open("wb") as stderr:
        process = subprocess.Popen(
            command, cwd=cwd, env=env,
            stdout=stdout, stderr=stderr,
            start_new_session=True, preexec_fn=_preexec,
        )
        while process.poll() is None:
            if time.monotonic() - mono_start >= timeout:
                reason = "timeout"
            elif out_path.stat().st_size + err_path.stat().st_size >= max_bytes:
                reason = "output-cap"
            elif max_processes > 0 and max(0, tree_size(process.pid) - 1) > max_processes:
                reason = "process-cap"
            if reason:
                break
            time.sleep(0.02)
        stop_group(process.pid)
        returncode = process.wait()

    if not reason and out_path.stat().st_size + err_path.stat().st_size >= max_bytes:
        reason = "output-cap"

    if reason:
        budget = max_bytes
        for path in (out_path, err_path):
            with path.open("r+b") as stream:
                data = stream.read(budget)
                stream.seek(0)
                stream.write(data)
                stream.truncate()
            budget -= len(data)

    wall_end = datetime.now(timezone.utc)
    run_record: dict[str, Any] = {
        "started_at": wall_start.isoformat().replace("+00:00", "Z"),
        "ended_at": wall_end.isoformat().replace("+00:00", "Z"),
        "duration_ms": int((time.monotonic() - mono_start) * 1000),
        "exit_code": returncode if returncode >= 0 else None,
        "signal": -returncode if returncode < 0 else None,
    }
    errors: list[str] = (
        ([reason] if reason else [])
        + ([f"analyzer-exit:{returncode}"] if returncode and not reason else [])
    )
    return run_record, errors


# ---------------------------------------------------------------------------
# Atomic write
# ---------------------------------------------------------------------------

def write(path: Path, value: Any) -> None:
    """Write *value* as canonical JSON with fsync + os.replace (atomic)."""
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_bytes(canonical_bytes(value))
    with tmp.open("rb") as stream:
        os.fsync(stream.fileno())
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# Atomic collision-safe publication
# ---------------------------------------------------------------------------

def publish(stage: Path, destination: Path) -> None:
    """Rename *stage* → *destination* using renameat2 RENAME_NOREPLACE.

    Raises AdapterError if renameat2 is unavailable on this kernel.
    Raises OSError (errno EEXIST) if *destination* already exists.
    """
    libc = ctypes.CDLL(None, use_errno=True)
    fn = getattr(libc, "renameat2", None)
    if fn is None:
        raise AdapterError("atomic no-replace publication is unavailable (no renameat2)")
    if fn(-100, os.fsencode(stage), -100, os.fsencode(destination), 1):
        raise OSError(ctypes.get_errno(), "atomic publication failed", destination)

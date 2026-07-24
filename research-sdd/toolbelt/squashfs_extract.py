#!/usr/bin/env python3
"""Safe SquashFS extraction with post-extraction tree validation."""
from __future__ import annotations

import argparse, hashlib, json, mmap, os, resource, shutil, signal, stat, struct, subprocess, sys, threading, time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent / "lib"))
from adapter_core import AdapterError, canonical_bytes, refuse_privileged_execution, require_private, publish, stage_file
from isolation_profile import PROFILE_BWRAP_UNSQUASHFS

SCHEMA = "squashfs-extract.v1"
SQFS_MAGIC = b"hsqs"                 # SquashFS v4 LE magic (0x73717368 little-endian)
SQFS_SB_FMT = "<5I6H8Q"             # 5×uint32 + 6×uint16 + 8×uint64 = 96 bytes
SQFS_SB_SIZE = struct.calcsize(SQFS_SB_FMT)  # 96
SQFS_FLAG_EXPORTABLE = 0x80                  # superblock flags bit 7: export table present


class SquashExtractError(AdapterError): pass


def find_squashfs_offset(data: mmap.mmap) -> int:
    """Return offset of first valid SquashFS v4 LE superblock in *data*.

    Mirrors firmware_carve.py validation: magic + struct fields + bounds.
    """
    offset = 0
    while True:
        offset = data.find(SQFS_MAGIC, offset)
        if offset < 0: raise SquashExtractError("no valid SquashFS v4 LE superblock found in input")
        if offset + SQFS_SB_SIZE <= len(data):
            try:
                _, inodes, _, block, fragments, compression, log, flags, ids, major, minor, _, used, id_table, xattr, inode_table, directory_table, fragment_table, export_table = struct.unpack_from(SQFS_SB_FMT, data, offset)
                end = offset + used
                valid_table = lambda x: x == 0xffffffffffffffff or SQFS_SB_SIZE <= x < used  # sentinel or in-range
                required = (id_table, inode_table, directory_table) + ((fragment_table,) if fragments else ()) + ((export_table,) if flags & SQFS_FLAG_EXPORTABLE else ())
                if (inodes and ids and major == 4 and minor == 0 and compression in range(1, 7)
                        and block == (1 << log) and 4096 <= block <= 1048576 and used >= SQFS_SB_SIZE
                        and end <= len(data)
                        and all(valid_table(x) for x in (id_table, xattr, inode_table, directory_table, fragment_table, export_table))
                        and all(x != 0xffffffffffffffff for x in required)):
                    return offset
            except struct.error: pass
        offset += 1


def run_unsquashfs(bwrap: Path, unsquashfs: Path, stage: Path, sqfs_offset: int, timeout: int, max_extracted_bytes: int) -> None:
    """Run unsquashfs inside minimal bwrap (wall-clock timeout + RLIMIT_FSIZE cap)."""
    cmd = [str(bwrap), "--die-with-parent", "--new-session", "--unshare-net", "--unshare-pid", "--cap-drop", "ALL"]
    for d in ("/usr", "/bin", "/sbin", "/lib", "/lib64"):
        if os.path.exists(d): cmd += ["--ro-bind", d, d]
    for etc in ("/etc/ld.so.cache", "/etc/ld.so.conf", "/etc/ld.so.conf.d"):
        cmd += ["--ro-bind-try", etc, etc]
    cmd += ["--dir", "/work", "--bind", str(stage), "/work", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
            "--setenv", "PATH", "/usr/bin:/usr/sbin:/bin:/sbin", "--setenv", "HOME", "/tmp", "--setenv", "TMPDIR", "/tmp", "--"]
    sqfs_args = [str(unsquashfs), "-no-progress", "-quiet", "-d", "/work/extracted"]
    if sqfs_offset > 0: sqfs_args += ["-offset", str(sqfs_offset)]  # skip N bytes before header
    cmd += sqfs_args + ["/work/input.sqfs"]

    def _preexec() -> None:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        try: resource.setrlimit(resource.RLIMIT_FSIZE, (max_extracted_bytes, max_extracted_bytes))  # per-file disk cap
        except Exception: os.write(2, b"squashfs-extract: warning: RLIMIT_FSIZE unavailable; relying on size watchdog\n")

    # Size watchdog: kills unsquashfs process group if aggregate on-disk bytes breach
    # max_extracted_bytes during extraction (~250 ms poll interval).
    watchdog_fired = threading.Event()
    watchdog_stop = threading.Event()
    proc_ref: list = [None]

    def _watchdog() -> None:
        extracted = stage / "extracted"
        while not watchdog_stop.wait(timeout=0.25):
            total = 0
            try:
                for dp, _dirs, fnames in os.walk(extracted, followlinks=False):
                    for fn in fnames:
                        try: total += os.lstat(os.path.join(dp, fn)).st_size
                        except OSError: pass
                    if total > max_extracted_bytes: break
            except OSError: pass
            if total > max_extracted_bytes:
                watchdog_fired.set()
                proc = proc_ref[0]
                if proc is not None:
                    try: os.killpg(proc.pid, signal.SIGKILL)
                    except (ProcessLookupError, OSError): pass
                return

    wd = threading.Thread(target=_watchdog, daemon=True, name="sqfs-size-watchdog")
    wd.start()
    with (stage / "stderr.txt").open("wb") as stderr_f:
        proc = subprocess.Popen(cmd, cwd=stage, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=stderr_f, start_new_session=True, preexec_fn=_preexec)
        proc_ref[0] = proc
        started = time.monotonic(); reason = ""
        while proc.poll() is None:
            if time.monotonic() - started >= timeout: reason = "timeout"; break
            time.sleep(0.02)
    watchdog_stop.set(); wd.join(timeout=1.0)
    if reason or watchdog_fired.is_set():
        try: os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, OSError): pass
    code = proc.wait()
    if watchdog_fired.is_set():
        raise SquashExtractError(f"extraction killed: on-disk size exceeded max-extracted-bytes ({max_extracted_bytes}) during extraction")
    if reason or code:
        snippet = (stage / "stderr.txt").read_text(errors="replace")[:512].strip()
        raise SquashExtractError(reason or "unsquashfs failed" + (f": {snippet}" if snippet else ""))


def walk_tree(root: Path, max_entries: int, max_bytes: int) -> list[dict[str, Any]]:
    """Walk extracted tree with O_NOFOLLOW; reject symlinks, specials, hardlinks; compute sha256.

    Returns sorted entry list: {path, type, mode, size?, sha256?} relative to *root*.
    """
    NOFOLLOW = getattr(os, "O_NOFOLLOW", 0); CLOEXEC = getattr(os, "O_CLOEXEC", 0)
    entries: list[dict[str, Any]] = []; total_bytes = 0
    for dirpath_str, _, filenames in os.walk(root, followlinks=False):
        dirpath = Path(dirpath_str); rel_dir = dirpath.relative_to(root)
        if str(rel_dir) != ".":  # add directory entry (skip the root itself)
            if len(entries) >= max_entries: raise SquashExtractError(f"entries exceed max-entries ({max_entries})")
            entries.append({"path": str(rel_dir), "type": "directory", "mode": stat.S_IMODE(dirpath.lstat().st_mode)})
        for name in sorted(filenames):  # sorted for determinism
            if len(entries) >= max_entries: raise SquashExtractError(f"entries exceed max-entries ({max_entries})")
            full = dirpath / name; rel = str(rel_dir / name) if str(rel_dir) != "." else name
            try: meta = full.lstat()
            except OSError as exc: raise SquashExtractError(f"cannot stat: {rel}") from exc
            if stat.S_ISLNK(meta.st_mode): raise SquashExtractError(f"symlink in extracted tree (rejected): {rel}")
            elif stat.S_ISREG(meta.st_mode):
                if meta.st_nlink != 1: raise SquashExtractError(f"hardlinked file in extracted tree: {rel}")
                total_bytes += meta.st_size
                if total_bytes > max_bytes: raise SquashExtractError(f"extracted bytes exceed max-extracted-bytes ({max_bytes})")
                fd = os.open(full, os.O_RDONLY | NOFOLLOW | CLOEXEC)
                try:
                    before = os.fstat(fd); digest = hashlib.sha256()
                    while chunk := os.read(fd, 1 << 20): digest.update(chunk)
                    after = os.fstat(fd); fields = lambda x: (x.st_dev, x.st_ino, x.st_size, x.st_mtime_ns)
                    if fields(before) != fields(after): raise SquashExtractError(f"file changed while hashing: {rel}")
                finally: os.close(fd)
                entries.append({"path": rel, "type": "file", "mode": stat.S_IMODE(meta.st_mode), "size": meta.st_size, "sha256": "sha256:" + digest.hexdigest()})
            else: raise SquashExtractError(f"special file in extracted tree (rejected): {rel}")
    return sorted(entries, key=lambda e: e["path"])


def validate_closed(stage: Path, expected_files: set[str], expected_dirs: set[str]) -> None:
    """Verify stage/ is exactly expected_files + expected_dirs; check ownership + modes."""
    seen_files: set[str] = set(); seen_dirs: set[str] = set()
    for p in stage.rglob("*"):
        meta = p.lstat(); rel = str(p.relative_to(stage))
        mode = 0o700 if stat.S_ISDIR(meta.st_mode) else 0o400
        if meta.st_uid != os.getuid() or stat.S_IMODE(meta.st_mode) != mode: raise SquashExtractError(f"output mode/ownership violation: {rel}")
        if stat.S_ISREG(meta.st_mode):
            if meta.st_nlink != 1: raise SquashExtractError(f"hardlinked output file: {rel}")
            seen_files.add(rel)
        elif stat.S_ISDIR(meta.st_mode): seen_dirs.add(rel)
        else: raise SquashExtractError(f"unexpected type in output tree: {rel}")
    if seen_files != expected_files or seen_dirs != expected_dirs: raise SquashExtractError("output tree is not closed")


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="squashfs-extract")
    p.add_argument("--input", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    p.add_argument("--manifest-cli", type=Path, required=True, help=argparse.SUPPRESS)
    p.add_argument("--max-input-bytes", type=int, default=512 * 1024 * 1024)      # 512 MiB
    p.add_argument("--max-extracted-bytes", type=int, default=256 * 1024 * 1024)  # 256 MiB extracted cap
    p.add_argument("--max-entries", type=int, default=10_000)                     # max tree entries
    p.add_argument("--timeout-seconds", type=int, default=120)                    # unsquashfs wall-clock
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv); stage: Path | None = None
    started_at = datetime.now(timezone.utc)
    try:
        refuse_privileged_execution()
        caps = {"max_input_bytes": args.max_input_bytes, "max_extracted_bytes": args.max_extracted_bytes, "max_entries": args.max_entries, "timeout_seconds": args.timeout_seconds}
        if min(caps.values()) < 1: raise SquashExtractError("caps must be positive")
        if ".." in args.output.parts or "\\" in str(args.output): raise SquashExtractError("output must be a canonical path")
        lexical = Path(os.path.abspath(args.output.parent)); probe = Path(lexical.anchor)
        for part in lexical.parts[1:]:
            probe /= part
            if probe.is_symlink(): raise SquashExtractError("output parent links are not allowed")
        parent = lexical.resolve(strict=True); require_private(parent); meta = parent.stat(); destination = parent / args.output.name
        if not stat.S_ISDIR(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o022 or args.output.name in ("", ".", "..") or destination.exists() or destination.is_symlink(): raise SquashExtractError("unsafe output destination")
        manifest_cli = args.manifest_cli.resolve(strict=True)
        bwrap_path = shutil.which("bwrap", path="/usr/bin:/bin")
        if not bwrap_path: raise SquashExtractError("bwrap is required")
        bwrap = Path(bwrap_path).resolve(strict=True)
        unsquashfs_path = shutil.which("unsquashfs", path="/usr/bin:/usr/sbin:/bin:/sbin")
        if not unsquashfs_path: raise SquashExtractError("unsquashfs is required")
        unsquashfs = Path(unsquashfs_path).resolve(strict=True)
        stage = parent / f".{args.output.name}.stage"; stage.mkdir(mode=0o700)
        source_rec, _ = stage_file(args.input, stage / "input.sqfs", "input.sqfs", 0o400, args.max_input_bytes)
        # Validate superblock in staged copy — closes TOCTOU gap
        ifd = os.open(stage / "input.sqfs", os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
        try:
            if os.fstat(ifd).st_size < SQFS_SB_SIZE: raise SquashExtractError("input too small for a SquashFS superblock")
            sqfs_data = mmap.mmap(ifd, 0, access=mmap.ACCESS_READ)
            try: sqfs_offset = find_squashfs_offset(sqfs_data)
            finally: sqfs_data.close()
        finally: os.close(ifd)
        run_unsquashfs(bwrap, unsquashfs, stage, sqfs_offset, args.timeout_seconds, args.max_extracted_bytes)
        (stage / "input.sqfs").unlink()
        entries = walk_tree(stage / "extracted", args.max_entries, args.max_extracted_bytes)
        file_entries = [e for e in entries if e["type"] == "file"]
        dir_entries = [e for e in entries if e["type"] == "directory"]
        report = {"schema": SCHEMA, "input": source_rec, "squashfs_offset": sqfs_offset, "entries": entries,
                  "entry_counts": {"files": len(file_entries), "directories": len(dir_entries)},
                  "total_extracted_bytes": sum(e["size"] for e in file_entries), "caps": caps,
                  "isolation": {"bubblewrap": True, "network_access": False, "payload_execution": False, "static_only": True},
                  "limitations": ["Tree validation rejects symlinks, special files, and hardlinks; semantic content is not analyzed.", "Bubblewrap is defense in depth; use a disposable VM for actively hostile firmware."],
                  "validation_verdict": "pass"}
        rfd = os.open(stage / f"{SCHEMA}.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o400)
        try: os.write(rfd, canonical_bytes(report)); os.fsync(rfd)
        finally: os.close(rfd)
        sfd = os.open(stage / "stdout.txt", os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o400); os.close(sfd)
        ended_at = datetime.now(timezone.utc); launcher = str(Path(sys.executable).resolve()); script = str(Path(__file__).resolve())
        outputs = [f"extracted/{e['path']}" for e in file_entries]
        spec = {"schema_version": "analysis-manifest.v1",
                "input": {"path": f"{SCHEMA}.json", "detected_type": "SquashFS v4 LE extraction report with source SHA-256"},
                "tool": {"name": "squashfs-extract", "version": "1", "executable": launcher, "artifacts": [{"path": script, "argv_index": 1}]},
                "argv": [launcher, script, "--input", source_rec["path"], "--output", str(destination), "--manifest-cli", str(manifest_cli)],
                "environment": {},
                "run": {"started_at": started_at.isoformat().replace("+00:00", "Z"), "ended_at": ended_at.isoformat().replace("+00:00", "Z"),
                        "duration_ms": int((ended_at - started_at).total_seconds() * 1000), "exit_code": 0, "signal": None},
                "stdout_path": "stdout.txt", "stderr_path": "stderr.txt", "outputs": outputs, "findings": [],
                "limitations": report["limitations"], "errors": [], "completeness": "complete",
                "isolation_profile": PROFILE_BWRAP_UNSQUASHFS}
        spec_path = stage / "manifest-spec.json"
        spfd = os.open(spec_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o400)
        try: os.write(spfd, canonical_bytes(spec)); os.fsync(spfd)
        finally: os.close(spfd)
        manifest_path = stage / "analysis-manifest.v1.json"
        subprocess.run([sys.executable, str(manifest_cli), "create", "--root", str(stage), "--spec", str(spec_path), "--output", str(manifest_path)], check=True, timeout=60)
        spec_path.unlink()
        subprocess.run([sys.executable, str(manifest_cli), "verify", "--root", str(stage), str(manifest_path)], check=True, timeout=60)
        for p in stage.rglob("*"): p.chmod(0o700 if p.is_dir() else 0o400)
        expected_files = {f"{SCHEMA}.json", "analysis-manifest.v1.json", "stdout.txt", "stderr.txt"} | {f"extracted/{e['path']}" for e in file_entries}
        expected_dirs = {"extracted"} | {f"extracted/{e['path']}" for e in dir_entries}
        validate_closed(stage, expected_files, expected_dirs)
        publish(stage, destination); stage = None; return 0
    except SquashExtractError as exc: print(f"squashfs-extract: {exc}", file=sys.stderr); return 2
    except (OSError, ValueError, KeyError, struct.error, json.JSONDecodeError, subprocess.SubprocessError) as exc: print(f"squashfs-extract: {exc}", file=sys.stderr); return 2
    finally:
        if stage is not None and stage.exists(): shutil.rmtree(stage)


if __name__ == "__main__": sys.exit(main())

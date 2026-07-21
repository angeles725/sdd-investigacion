#!/usr/bin/env python3
"""Deterministically carve only validated uImage and SquashFS byte ranges."""
from __future__ import annotations

import argparse, binascii, ctypes, hashlib, json, mmap, os, resource, shutil, signal, stat, struct, subprocess, sys, time
from pathlib import Path
from typing import Any

SCHEMA = "firmware-carve.v1"
PRIVATE_FS = {"btrfs", "ext2", "ext3", "ext4", "f2fs", "jfs", "nilfs2", "overlay", "ramfs", "reiserfs", "tmpfs", "ubifs", "xfs", "zfs"}


class CarveError(ValueError): pass


class PublishedUnsynced(CarveError): pass


def canonical(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def hash_file(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256(); total = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024): digest.update(chunk); total += len(chunk)
    return total, "sha256:" + digest.hexdigest()


def read_staged(path: Path) -> bytes:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o400: raise CarveError("staged input type, owner, or mode changed")
        chunks = []
        while chunk := os.read(fd, 1024 * 1024): chunks.append(chunk)
        after = os.fstat(fd); stable = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
        if stable(before) != stable(after): raise CarveError("staged input changed while reading")
        return b"".join(chunks)
    finally: os.close(fd)


def copy_input(source: Path, target: Path, limit: int) -> dict[str, Any]:
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: src = os.open(source, flags)
    except OSError as exc: raise CarveError("input must be a regular non-symlink file") from exc
    digest = hashlib.sha256(); total = 0
    try:
        before = os.fstat(src)
        if not stat.S_ISREG(before.st_mode): raise CarveError("input is not a regular file")
        if before.st_size > limit: raise CarveError("input exceeds max-input-bytes")
        resolved = str(Path(f"/proc/self/fd/{src}").resolve())
        out = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
        try:
            while chunk := os.read(src, min(1024 * 1024, limit - total + 1)):
                total += len(chunk)
                if total > limit: raise CarveError("input exceeds max-input-bytes")
                digest.update(chunk); view = memoryview(chunk)
                while view: view = view[os.write(out, view):]
            os.fsync(out)
        finally: os.close(out)
        after = os.fstat(src); stable = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
        if stable(before) != stable(after) or total != before.st_size: raise CarveError("input changed while staging")
    finally: os.close(src)
    return {"path": resolved, "size": total, "sha256": "sha256:" + digest.hexdigest()}


def private_fs(path: Path) -> None:
    selected = (-1, "")
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        try: left, right = line.split(" - ", 1); mount, kind = Path(left.split()[4]), right.split()[0]; path.relative_to(mount)
        except (IndexError, ValueError): continue
        if len(mount.parts) > selected[0]: selected = (len(mount.parts), kind)
    if selected[1] not in PRIVATE_FS: raise CarveError("output must reside on a Linux-private filesystem")


def trusted_bwrap() -> tuple[Path, str]:
    selected = shutil.which("bwrap", path="/usr/bin:/bin")
    if not selected: raise CarveError("Bubblewrap is required")
    path = Path(selected).resolve(strict=True); meta = path.stat()
    if not stat.S_ISREG(meta.st_mode) or meta.st_uid != 0 or meta.st_mode & 0o022: raise CarveError("Bubblewrap must be root-owned and non-writable")
    return path, hash_file(path)[1]


def candidates(data: mmap.mmap, max_carves: int, max_files: int, max_output: int) -> list[tuple[int, int, str]]:
    found: list[tuple[int, int, str]] = []
    output_bytes = 0
    def add(item: tuple[int, int, str]) -> None:
        nonlocal output_bytes
        output_bytes += item[1] - item[0]
        if len(found) >= max_carves or len(found) + 2 > max_files: raise CarveError("candidate count exceeds output caps")
        if output_bytes > max_output: raise CarveError("carved bytes exceed max-output-bytes")
        found.append(item)
    start = 0
    while (offset := data.find(b"\x27\x05\x19\x56", start)) >= 0:
        start = offset + 1
        if offset + 64 > len(data): continue
        header = bytearray(data[offset:offset + 64]); recorded = struct.unpack_from(">I", header, 4)[0]; header[4:8] = b"\0" * 4
        size, payload_crc = struct.unpack_from(">I8xI", header, 12); end = offset + 64 + size
        if end <= len(data) and binascii.crc32(header) & 0xffffffff == recorded and binascii.crc32(memoryview(data)[offset + 64:end]) & 0xffffffff == payload_crc:
            add((offset, end, "uimage"))
    start = 0
    while (offset := data.find(b"hsqs", start)) >= 0:
        start = offset + 1
        if offset + 96 > len(data): continue
        values = struct.unpack_from("<5I6H8Q", data, offset); _, inodes, _, block, fragments, compression, log, flags, ids, major, minor, _, used, id_table, xattr, inode_table, directory_table, fragment_table, export_table = values
        end = offset + used; table = lambda x: x == 0xffffffffffffffff or 96 <= x < used
        required = (id_table, inode_table, directory_table) + ((fragment_table,) if fragments else ()) + ((export_table,) if flags & 0x80 else ())
        if inodes and ids and major == 4 and minor == 0 and compression in range(1, 7) and block == 1 << log and 4096 <= block <= 1048576 and used >= 96 and end <= len(data) and all(table(x) for x in (id_table, xattr, inode_table, directory_table, fragment_table, export_table)) and all(x != 0xffffffffffffffff for x in required):
            add((offset, end, "squashfs-v4-le"))
    return sorted(found, key=lambda item: (item[0], item[2], item[1]))


def worker(args: argparse.Namespace) -> int:
    stage = args.stage.resolve(); source = stage / "input.bin"; input_record = json.loads(args.input_record)
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)); meta = os.fstat(source_fd)
    if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid() or stat.S_IMODE(meta.st_mode) != 0o400: raise CarveError("staged input type, owner, or mode changed")
    data = mmap.mmap(source_fd, 0, access=mmap.ACCESS_READ); digest = hashlib.sha256()
    for offset in range(0, len(data), 1024 * 1024): digest.update(memoryview(data)[offset:offset + 1024 * 1024])
    if (len(data), "sha256:" + digest.hexdigest()) != (input_record["size"], input_record["sha256"]): raise CarveError("staged input identity mismatch")
    found = candidates(data, args.max_carves, args.max_files, args.max_output_bytes)
    if not found: raise CarveError("no validated supported image found")
    output = stage / "carves"; output.mkdir(mode=0o700); records = []
    for start, end, kind in found:
        relative = f"carves/{start:08x}-{kind}.bin"; path = stage / relative; carved = hashlib.sha256()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
        try:
            for offset in range(start, end, 1024 * 1024):
                view = memoryview(data)[offset:min(end, offset + 1024 * 1024)]; carved.update(view)
                while view: view = view[os.write(fd, view):]
            del view
            os.fsync(fd)
        finally: os.close(fd)
        records.append({"kind": kind, "offset": start, "size": end - start, "path": relative, "sha256": "sha256:" + carved.hexdigest()})
    report = {"schema": SCHEMA, "input": json.loads(args.input_record), "carves": records,
        "caps": {"max_input_bytes": args.max_input_bytes, "max_output_bytes": args.max_output_bytes, "max_carves": args.max_carves, "max_files": args.max_files, "timeout_seconds": args.timeout_seconds, "max_processes": args.max_processes, "max_memory_bytes": args.max_memory_bytes},
        "isolation": {"bubblewrap": True, "network_access": False, "payload_execution": False, "static_only": True, "vm_boundary": False},
        "isolation_artifact": {"path": args.bwrap_path, "sha256": args.bwrap_sha256},
        "limitations": ["Bubblewrap is defense in depth, not a hostile-parser security boundary; use a disposable VM for hostile firmware.", "Carving validates only uImage CRCs and the SquashFS v4 little-endian structural byte range; it does not validate filesystem contents."]}
    path = stage / f"{SCHEMA}.json"; fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
    try: os.write(fd, canonical(report)); os.fsync(fd)
    finally: os.close(fd)
    stable = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
    if stable(meta) != stable(os.fstat(source_fd)): raise CarveError("staged input changed while carving")
    data.close(); os.close(source_fd)
    return 0


def tree_size(root: int) -> int:
    parents = {}
    for path in Path("/proc").glob("[0-9]*/stat"):
        try: fields = path.read_text().rsplit(")", 1)[1].split(); parents[int(path.parent.name)] = int(fields[1])
        except (OSError, IndexError, ValueError): pass
    descendants = {root}
    while True:
        expanded = descendants | {pid for pid, parent in parents.items() if parent in descendants}
        if expanded == descendants: return len(descendants & parents.keys())
        descendants = expanded


def run_worker(command: list[str], stage: Path, timeout: int, processes: int, memory: int = 1342177280) -> None:
    def limits() -> None:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); resource.setrlimit(resource.RLIMIT_AS, (memory, memory))
    started = time.monotonic(); child = subprocess.Popen(command, cwd=stage, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True, preexec_fn=limits)
    reason = ""
    while child.poll() is None:
        if time.monotonic() - started >= timeout: reason = "timeout"
        elif max(0, tree_size(child.pid) - 1) > processes: reason = "process cap"
        if reason:
            try: os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            break
        time.sleep(.01)
    code = child.wait(); detail = child.stderr.read(4096).decode(errors="replace").strip() if child.stderr else ""
    if reason or code: raise CarveError(reason or "isolated worker failed" + (f": {detail}" if detail else ""))


def validate_tree(stage: Path, report: dict[str, Any], source: Path) -> None:
    expected = {f"{SCHEMA}.json", "input.bin"}; records = report["carves"]
    if records != sorted(records, key=lambda x: (x["offset"], x["kind"], x["size"])): raise CarveError("manifest carve order is invalid")
    for item in records:
        relative = f'carves/{item["offset"]:08x}-{item["kind"]}.bin'
        if item["kind"] not in {"uimage", "squashfs-v4-le"} or item["path"] != relative or item["size"] < 1: raise CarveError("manifest carve record is invalid")
        path = stage / relative; flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        carved_fd, source_fd = os.open(path, flags), os.open(source, flags); before = os.fstat(carved_fd); digest_value = hashlib.sha256(); size = 0
        try:
            os.lseek(source_fd, item["offset"], os.SEEK_SET)
            while chunk := os.read(carved_fd, 1024 * 1024):
                if os.read(source_fd, len(chunk)) != chunk: raise CarveError("carve source range mismatch")
                digest_value.update(chunk); size += len(chunk)
            after = os.fstat(carved_fd)
        finally: os.close(carved_fd); os.close(source_fd)
        digest = "sha256:" + digest_value.hexdigest()
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns): raise CarveError("carve changed while validating")
        if (size, digest) != (item["size"], item["sha256"]): raise CarveError("carve identity mismatch")
        expected.add(relative)
    seen = set()
    for path in stage.rglob("*"):
        meta = path.lstat()
        if meta.st_uid != os.getuid() or stat.S_IMODE(meta.st_mode) != (0o700 if stat.S_ISDIR(meta.st_mode) else 0o400): raise CarveError("output ownership or mode violation")
        if stat.S_ISREG(meta.st_mode):
            if meta.st_nlink != 1: raise CarveError("output regular file has external hardlinks")
            seen.add(str(path.relative_to(stage)))
        elif not stat.S_ISDIR(meta.st_mode): raise CarveError("output tree contains a link or special file")
    if seen != expected or (stage / f"{SCHEMA}.json").read_bytes() != canonical(report): raise CarveError("output tree or canonical manifest mismatch")
    (stage / "input.bin").unlink()
    for directory in (stage / "carves", stage):
        fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)); os.fsync(fd); os.close(fd)


def publish(stage: Path, destination: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True); rename = getattr(libc, "renameat2", None)
    if rename is None or rename(-100, os.fsencode(stage), -100, os.fsencode(destination), 1): raise CarveError("atomic no-replace publication failed")
    try:
        parent = os.open(destination.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try: os.fsync(parent)
        finally: os.close(parent)
    except OSError as exc: raise PublishedUnsynced(f"output exists at {destination}, but parent-directory sync failed") from exc


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(); p.add_argument("--input", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    p.add_argument("--max-input-bytes", type=int, default=1073741824); p.add_argument("--max-output-bytes", type=int, default=1073741824); p.add_argument("--max-carves", type=int, default=16); p.add_argument("--max-files", type=int, default=17); p.add_argument("--timeout-seconds", type=int, default=30); p.add_argument("--max-processes", type=int, default=4); p.add_argument("--max-memory-bytes", type=int, default=1342177280)
    p.add_argument("--worker", action="store_true", help=argparse.SUPPRESS); p.add_argument("--stage", type=Path, help=argparse.SUPPRESS); p.add_argument("--input-record", help=argparse.SUPPRESS); p.add_argument("--bwrap-path", help=argparse.SUPPRESS); p.add_argument("--bwrap-sha256", help=argparse.SUPPRESS); return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv); stage: Path | None = None
    try:
        if args.worker: return worker(args)
        if os.geteuid() == 0 or os.getuid() != os.geteuid() or os.getgid() != os.getegid(): raise CarveError("refusing root or set-id execution")
        if min(args.max_input_bytes, args.max_output_bytes, args.max_carves, args.max_files, args.timeout_seconds, args.max_processes, args.max_memory_bytes) < 1: raise CarveError("caps must be positive")
        if ".." in args.output.parts or "\\" in str(args.output): raise CarveError("output must be a new canonical path")
        lexical = Path(os.path.abspath(args.output.parent)); probe = Path(lexical.anchor)
        for part in lexical.parts[1:]:
            probe /= part
            if probe.is_symlink(): raise CarveError("output parent links are not allowed")
        parent = lexical.resolve(strict=True); private_fs(parent); destination = parent / args.output.name; parent_meta = parent.stat()
        if not stat.S_ISDIR(parent_meta.st_mode) or parent_meta.st_uid != os.getuid() or parent_meta.st_mode & 0o022 or args.output.name in ("", ".", "..") or destination.exists() or destination.is_symlink(): raise CarveError("output must be a new canonical path in a private owned directory")
        candidate = parent / f".{destination.name}.stage"; candidate.mkdir(mode=0o700); stage = candidate; record = copy_input(args.input, stage / "input.bin", args.max_input_bytes)
        bwrap, digest = trusted_bwrap(); script = Path(__file__).resolve(); env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "TZ": "UTC", "HOME": "/tmp/home", "TMPDIR": "/tmp"}
        command = [str(bwrap), "--die-with-parent", "--new-session", "--unshare-net", "--unshare-pid", "--cap-drop", "ALL", "--ro-bind", "/", "/", "--tmpfs", "/tmp", "--dir", "/tmp/home", "--dir", "/tmp/work", "--bind", str(stage), "/tmp/work", "--proc", "/proc", "--dev", "/dev"]
        for key, value in env.items(): command += ["--setenv", key, value]
        inner = [sys.executable, str(script), "--worker", "--input", "/tmp/work/input.bin", "--output", "/tmp/work/output", "--stage", "/tmp/work", "--input-record", json.dumps(record, sort_keys=True), "--bwrap-path", str(bwrap), "--bwrap-sha256", digest]
        for name in ("max-input-bytes", "max-output-bytes", "max-carves", "max-files", "timeout-seconds", "max-processes", "max-memory-bytes"): inner += ["--" + name, str(getattr(args, name.replace("-", "_")))]
        run_worker(command + ["--", *inner], stage, args.timeout_seconds, args.max_processes, args.max_memory_bytes)
        report = json.loads(read_staged(stage / f"{SCHEMA}.json")); expected_caps = {name.replace("-", "_"): getattr(args, name.replace("-", "_")) for name in ("max-input-bytes", "max-output-bytes", "max-carves", "max-files", "timeout-seconds", "max-processes", "max-memory-bytes")}
        isolation = {"bubblewrap": True, "network_access": False, "payload_execution": False, "static_only": True, "vm_boundary": False}
        if set(report) != {"schema", "input", "carves", "caps", "isolation", "isolation_artifact", "limitations"} or report["schema"] != SCHEMA or report["input"] != record or report["caps"] != expected_caps or report["isolation"] != isolation or report["isolation_artifact"] != {"path": str(bwrap), "sha256": digest}: raise CarveError("manifest contract mismatch")
        validate_tree(stage, report, stage / "input.bin")
        try: publish(stage, destination)
        except PublishedUnsynced: stage = None; raise
        stage = None; return 0
    except PublishedUnsynced as exc:
        print(f"firmware-carve: published with uncertain durability: {exc}", file=sys.stderr); return 3
    except (CarveError, OSError, ValueError, KeyError, TypeError, json.JSONDecodeError, subprocess.SubprocessError) as exc:
        print(f"firmware-carve: {exc}", file=sys.stderr); return 2
    finally:
        if stage is not None and stage.exists(): shutil.rmtree(stage)


if __name__ == "__main__": sys.exit(main())

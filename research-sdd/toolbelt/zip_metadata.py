#!/usr/bin/env python3
"""Inventory classic ZIP central-directory metadata without reading entries."""
from __future__ import annotations

import argparse, ctypes, hashlib, json, os, re, shutil, stat, struct, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA = "zip-metadata.v1"
PRIVATE_FS = {"btrfs", "ext2", "ext3", "ext4", "f2fs", "jfs", "nilfs2", "overlay", "ramfs", "reiserfs", "tmpfs", "ubifs", "xfs", "zfs"}


class ZipMetadataError(ValueError): pass


def canonical(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def ensure_stable(before: os.stat_result, after: os.stat_result) -> None:
    fields = lambda x: (x.st_dev, x.st_ino, x.st_mode, x.st_size, x.st_mtime_ns, x.st_ctime_ns)
    if fields(before) != fields(after): raise ZipMetadataError("input changed while reading metadata")


def pread(fd: int, size: int, offset: int) -> bytes:
    data = os.pread(fd, size, offset)
    if len(data) != size: raise ZipMetadataError("truncated ZIP structure")
    return data


def dos_timestamp(date: int, time: int) -> str | None:
    year, month, day, hour, minute, second = 1980 + (date >> 9), (date >> 5) & 15, date & 31, time >> 11, (time >> 5) & 63, (time & 31) * 2
    if not (1 <= month <= 12 and 1 <= day <= 31 and hour < 24 and minute < 60 and second < 60): return None
    return f"{year:04d}-{month:02d}-{day:02d}T{hour:02d}:{minute:02d}:{second:02d}"


def find_eocd(fd: int, size: int) -> tuple[int, bytes]:
    if size < 22: raise ZipMetadataError("truncated EOCD")
    fixed = pread(fd, 22, size - 22)
    if fixed[:4] == b"PK\x05\x06" and struct.unpack_from("<H", fixed, 20)[0] == 0: return size - 22, fixed
    length = min(size, 65557); tail = pread(fd, length, size - length); start = len(tail)
    while True:
        start = tail.rfind(b"PK\x05\x06", 0, start)
        if start < 0: raise ZipMetadataError("EOCD not found")
        if start + 22 <= len(tail) and start + 22 + struct.unpack_from("<H", tail, start + 20)[0] == len(tail):
            return size - length + start, tail[start:]


def inventory(fd: int, size: int, max_cd: int, max_entries: int, max_field: int, max_report: int = 16777216) -> tuple[dict[str, Any], bytes]:
    eocd_offset, eocd = find_eocd(fd, size)
    disk, cd_disk, disk_entries, entries, cd_size, cd_offset, comment = struct.unpack_from("<4H2IH", eocd, 4)
    if disk or cd_disk or disk_entries != entries: raise ZipMetadataError("multi-disk or spanned ZIP is unsupported")
    if 0xffff in (disk_entries, entries) or 0xffffffff in (cd_size, cd_offset): raise ZipMetadataError("ZIP64 is unsupported")
    if eocd_offset >= 20 and pread(fd, 4, eocd_offset - 20) == b"PK\x06\x07": raise ZipMetadataError("ZIP64 is unsupported")
    if entries > max_entries: raise ZipMetadataError("entry count exceeds max-entries")
    if cd_size > max_cd: raise ZipMetadataError("central directory exceeds max-central-directory-bytes")
    if comment > max_field: raise ZipMetadataError("EOCD comment exceeds max-field-bytes")
    prefix = eocd_offset - cd_size - cd_offset
    if prefix < 0 or cd_offset + prefix < 0 or cd_offset + prefix + cd_size != eocd_offset: raise ZipMetadataError("impossible central-directory range")
    actual = cd_offset + prefix; position = actual; records: list[dict[str, Any]] = []; report_bytes = 0
    for index in range(entries):
        if position + 46 > eocd_offset: raise ZipMetadataError("truncated central-directory header")
        header = pread(fd, 46, position)
        values = struct.unpack("<4s6H3I5H2I", header)
        if values[0] != b"PK\x01\x02": raise ZipMetadataError("invalid central-directory signature")
        _, made, needed, flags, method, mtime, mdate, crc, compressed, uncompressed, nlen, xlen, clen, start_disk, internal, external, local = values
        if max(nlen, xlen, clen) > max_field: raise ZipMetadataError("central-directory field exceeds max-field-bytes")
        end = position + 46 + nlen + xlen + clen
        if end > eocd_offset: raise ZipMetadataError("central-directory field exceeds declared range")
        fields = pread(fd, nlen + xlen + clen, position + 46); raw, extra = fields[:nlen], fields[nlen:nlen + xlen]
        cursor = 0
        while cursor < len(extra):
            if cursor + 4 > len(extra): raise ZipMetadataError("malformed extra field")
            kind, length = struct.unpack_from("<HH", extra, cursor); cursor += 4
            if cursor + length > len(extra): raise ZipMetadataError("malformed extra field")
            if kind == 1: raise ZipMetadataError("ZIP64 is unsupported")
            cursor += length
        if start_disk or 0xffffffff in (compressed, uncompressed, local): raise ZipMetadataError("ZIP64 or spanned entry is unsupported")
        if local + prefix < 0 or local + prefix >= actual: raise ZipMetadataError("impossible local-header offset")
        encoding = "utf-8" if flags & 0x800 else "cp437"; name = raw.decode(encoding, errors="replace")
        parts = re.split(r"[\\/]", name)
        records.append({"index": index, "name": name, "name_encoding": encoding, "name_raw_hex": raw.hex(), "method": method,
            "flags": flags, "encrypted": bool(flags & 1), "crc32": f"{crc:08x}", "compressed_size": compressed,
            "uncompressed_size": uncompressed, "internal_attributes": internal, "external_attributes": external,
            "version_made_by": made, "version_needed": needed, "dos_date": mdate, "dos_time": mtime,
            "timestamp": dos_timestamp(mdate, mtime), "declared_local_header_offset": local,
            "safety": {"absolute": name.startswith(("/", "\\")) or bool(re.match(r"^[A-Za-z]:[\\/]", name)),
            "traversal": ".." in parts, "backslash": b"\\" in raw, "nul": b"\0" in raw, "duplicate": False}})
        report_bytes += len(canonical(records[-1]))
        if report_bytes > max_report: raise ZipMetadataError("canonical report exceeds max-report-bytes")
        position = end
    if position != eocd_offset: raise ZipMetadataError("central-directory size or entry count mismatch")
    counts: dict[str, int] = {}
    for item in records: counts[item["name"]] = counts.get(item["name"], 0) + 1
    for item in records: item["safety"]["duplicate"] = counts[item["name"]] > 1
    metadata = pread(fd, cd_size, actual) + eocd
    return {"entries": records, "archive_prefix_bytes": prefix, "central_directory_offset": actual,
            "central_directory_size": cd_size, "eocd_offset": eocd_offset, "eocd_comment_raw_hex": eocd[22:].hex()}, metadata


def private_fs(path: Path) -> None:
    selected = (-1, "")
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        try: left, right = line.split(" - ", 1); mount = Path(left.split()[4]); path.relative_to(mount)
        except (IndexError, ValueError): continue
        if len(mount.parts) > selected[0]: selected = (len(mount.parts), right.split()[0])
    if selected[1] not in PRIVATE_FS: raise ZipMetadataError("output must reside on a Linux-private filesystem")


def publish(stage: Path, destination: Path) -> None:
    rename = getattr(ctypes.CDLL(None, use_errno=True), "renameat2", None)
    if rename is None or rename(-100, os.fsencode(stage), -100, os.fsencode(destination), 1): raise ZipMetadataError("atomic no-replace publication failed")
    parent = os.open(destination.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try: os.fsync(parent)
    finally: os.close(parent)


def write(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
    try: os.write(fd, data); os.fsync(fd)
    finally: os.close(fd)


def validate_tree(stage: Path) -> None:
    expected = {"input/central-directory.bin", "stdout.txt", "stderr.txt", f"{SCHEMA}.json", "analysis-manifest.v1.json"}; seen = set()
    for path in stage.rglob("*"):
        meta = path.lstat(); mode = 0o700 if stat.S_ISDIR(meta.st_mode) else 0o400
        if meta.st_uid != os.getuid() or stat.S_IMODE(meta.st_mode) != mode: raise ZipMetadataError("output ownership or mode violation")
        if stat.S_ISREG(meta.st_mode):
            if meta.st_nlink != 1: raise ZipMetadataError("output file has external hardlinks")
            seen.add(str(path.relative_to(stage)))
        elif not stat.S_ISDIR(meta.st_mode): raise ZipMetadataError("output tree contains a link or special file")
    if seen != expected: raise ZipMetadataError("output tree is not closed")
    for directory in (stage / "input", stage):
        descriptor = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)); os.fsync(descriptor); os.close(descriptor)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(); p.add_argument("--input", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    p.add_argument("--max-input-bytes", type=int, default=1073741824); p.add_argument("--max-central-directory-bytes", type=int, default=16777216)
    p.add_argument("--max-entries", type=int, default=10000); p.add_argument("--max-field-bytes", type=int, default=65536); p.add_argument("--max-report-bytes", type=int, default=16777216)
    p.add_argument("--manifest-cli", type=Path, required=True, help=argparse.SUPPRESS); args = p.parse_args(argv); stage: Path | None = None
    try:
        if min(args.max_input_bytes, args.max_central_directory_bytes, args.max_entries, args.max_field_bytes, args.max_report_bytes) < 1: raise ZipMetadataError("caps must be positive")
        if os.getuid() != os.geteuid() or os.getgid() != os.getegid(): raise ZipMetadataError("set-id execution is unsupported")
        lexical = Path(os.path.abspath(args.output.parent)); probe = Path(lexical.anchor)
        for part in lexical.parts[1:]:
            probe /= part
            if probe.is_symlink(): raise ZipMetadataError("output parent links are unsupported")
        parent = lexical.resolve(strict=True); private_fs(parent); destination = parent / args.output.name; parent_meta = parent.stat()
        if args.output.name in ("", ".", "..") or destination.exists() or destination.is_symlink() or parent_meta.st_uid != os.getuid() or parent_meta.st_mode & 0o022: raise ZipMetadataError("output must be a new path in an owned non-writable directory")
        fd = os.open(args.input, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode): raise ZipMetadataError("input must be a regular non-symlink file")
            if before.st_size > args.max_input_bytes: raise ZipMetadataError("input exceeds max-input-bytes")
            source = str(Path(f"/proc/self/fd/{fd}").resolve()); parsed, metadata = inventory(fd, before.st_size, args.max_central_directory_bytes, args.max_entries, args.max_field_bytes, args.max_report_bytes)
            ensure_stable(before, os.fstat(fd))
        finally: os.close(fd)
        candidate = parent / f".{destination.name}.stage"; candidate.mkdir(mode=0o700); stage = candidate; (stage / "input").mkdir(mode=0o700)
        metadata_digest = "sha256:" + hashlib.sha256(metadata).hexdigest(); write(stage / "input/central-directory.bin", metadata); write(stage / "stdout.txt", b""); write(stage / "stderr.txt", b"")
        caps = {"max_input_bytes": args.max_input_bytes, "max_central_directory_bytes": args.max_central_directory_bytes, "max_entries": args.max_entries, "max_field_bytes": args.max_field_bytes, "max_report_bytes": args.max_report_bytes}
        report = {"schema": SCHEMA, "input": {"path": source, "size": before.st_size, "metadata_sha256": metadata_digest}, **parsed,
            "caps": caps, "payload_bytes_read": 0, "limitations": ["ZIP64, multi-disk archives, recovery, payload CRC validation, passwords, and extraction are unsupported."]}
        payload = canonical(report)
        if len(payload) > args.max_report_bytes: raise ZipMetadataError("canonical report exceeds max-report-bytes")
        write(stage / f"{SCHEMA}.json", payload); now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"); script = str(Path(__file__).resolve()); launcher = str(Path(sys.executable).resolve())
        spec = {"schema_version":"analysis-manifest.v1","input":{"path":"input/central-directory.bin","detected_type":"ZIP central directory and EOCD metadata"},
            "tool":{"name":"zip-metadata","version":"1","executable":launcher,"artifacts":[{"path":script,"argv_index":1}]},"argv":[launcher,script,"--input",source,"--output",str(destination)],
            "environment":{},"run":{"started_at":now,"ended_at":now,"duration_ms":0,"exit_code":0,"signal":None},"stdout_path":"stdout.txt","stderr_path":"stderr.txt",
            "outputs":[f"{SCHEMA}.json"],"findings":[],"limitations":report["limitations"],"errors":[],"completeness":"complete",
            "isolation_profile":{"name":"in-process-metadata-only","static_only":True,"network_access":False,"target_execution":False}}
        spec_path = stage / "manifest-spec.json"; write(spec_path, canonical(spec)); manifest = stage / "analysis-manifest.v1.json"
        subprocess.run([sys.executable,str(args.manifest_cli),"create","--root",str(stage),"--spec",str(spec_path),"--output",str(manifest)],check=True); spec_path.unlink()
        subprocess.run([sys.executable,str(args.manifest_cli),"verify","--root",str(stage),str(manifest)],check=True)
        for path in stage.rglob("*"):
            path.chmod(0o700 if path.is_dir() else 0o400)
        validate_tree(stage); publish(stage,destination); stage=None; return 0
    except (ZipMetadataError, OSError, ValueError, struct.error, subprocess.SubprocessError) as exc:
        print(f"zip-metadata: {exc}",file=sys.stderr); return 2
    finally:
        if stage is not None and stage.exists(): shutil.rmtree(stage)


if __name__ == "__main__": sys.exit(main())

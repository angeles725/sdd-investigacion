#!/usr/bin/env python3
"""serial-frame-analyze — offline analysis of serial frame captures (serial-frame.v1).

Reads a text log of serial frames in ``t_rel  len=N  hexbytes`` format and
emits structured evidence as key-sorted JSON.  No hardware, no serial I/O,
no network — strictly read-only offline analysis.

Input format (one frame per line):
  <timestamp>  len=<N>  <hex_byte> <hex_byte> ...
Lines starting with ``#`` and blank lines are ignored.

Subcommands:

  stats     --input <log> --output <json>
            Frame-length histogram + per-byte-position variability for the
            most common frame length (useful for identifying header bytes vs
            data / counter / checksum fields).

  diff      --input-a <logA> --input-b <logB> --output <json>
            Align frames by (length, first_byte) key and report which byte
            positions differ between two captures taken under different known
            conditions (e.g. running vs idle).  Those positions carry the
            value that changed.

  checksum  --input <log> --output <json>
            Brute-force common single- and two-byte checksum algorithms
            (sum8, twos-comp8, xor8, CRC16-Modbus LE/BE, CRC16-CCITT BE)
            over the last 1 or 2 bytes of each frame.  Reports any algorithm
            that validates across all frames of a given length.

Exit codes:
  0  complete — analysis finished (may have 0 frames if log is empty)
  1  parse error — malformed frame data prevents analysis (status:failed)
  2  I/O error — absent, unreadable, or symlink input/output (no JSON)
"""
import argparse
import errno
import hashlib
import json
import os
import re
import sys
from collections import defaultdict

SCHEMA = "serial-frame.v1"
FRAME_RE = re.compile(r'len=\s*(\d+)\s+([0-9a-fA-F ]+)\s*$')

# Read and frame caps — bound memory on large or crafted log files
_MAX_READ_BYTES = 10 * 1024 * 1024   # 10 MB read cap per input file
_MAX_FRAMES = 10_000                   # maximum frames loaded per file

# O_NOFOLLOW / O_CLOEXEC are Linux-specific; getattr guards for portability
_O_NOFOLLOW = getattr(os, 'O_NOFOLLOW', 0)
_O_CLOEXEC  = getattr(os, 'O_CLOEXEC', 0)


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def _open_ro(path: str) -> int:
    """Open *path* read-only, rejecting symlinks via O_NOFOLLOW."""
    try:
        return os.open(path, os.O_RDONLY | _O_NOFOLLOW)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise OSError(errno.ELOOP, "is a symbolic link (rejected)", path) from exc
        raise


def _open_wo_new(path: str) -> int:
    """Open *path* write-only for a new file; refuse symlinks and pre-existing files.

    Uses O_CREAT|O_EXCL|O_NOFOLLOW so a pre-existing symlink or regular file
    at *path* causes the open to fail (ELOOP / EEXIST → OSError → exit 2).
    Pattern from zip_stored.py, squashfs_extract.py, qnx6_read.py.
    """
    return os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW | _O_CLOEXEC,
        0o600,
    )


def _sha256_fd(fd: int) -> str:
    """Compute SHA-256 of all bytes in *fd* (seeks to 0 first)."""
    h = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        h.update(chunk)
    return h.hexdigest()


def _write_json(path: str, data: dict) -> None:
    """Write *data* as key-sorted JSON to *path*, refusing symlinks (O_NOFOLLOW)."""
    content = (json.dumps(data, indent=2, sort_keys=True) + '\n').encode('utf-8')
    fd = _open_wo_new(path)
    try:
        os.write(fd, content)
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# Frame loader
# ---------------------------------------------------------------------------

def _load_frames(path: str) -> tuple:
    """Load serial frames from a log file.

    Returns ``(frames, truncated, sha256, parse_errors, non_blank_count)`` where:
    - ``frames``          list of ``bytes`` objects, one per valid parsed frame
    - ``truncated``       ``True`` when read-byte cap or frame cap was hit
    - ``sha256``          hex digest of the full file
    - ``parse_errors``    list of error strings for lines that fail to parse as
                          a valid frame (no ``len=`` token, len mismatch, or bad hex)
    - ``non_blank_count`` count of non-blank, non-comment lines seen; used to
                          distinguish empty-input (0) from garbage-input (>0,
                          all lines failed) — §7 three-state honesty

    Raises ``OSError`` on absent/unreadable/symlink input (caller handles exit 2).
    """
    frames: list = []
    parse_errors: list = []
    non_blank_count = 0
    truncated = False

    fd = _open_ro(path)
    try:
        sha256 = _sha256_fd(fd)
        os.lseek(fd, 0, os.SEEK_SET)
        st = os.fstat(fd)
        to_read = min(st.st_size, _MAX_READ_BYTES)
        if st.st_size > _MAX_READ_BYTES:
            truncated = True
        buf = bytearray()
        remaining = to_read
        while remaining > 0:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            buf += chunk
            remaining -= len(chunk)
        text = buf.decode('utf-8', errors='replace')
    finally:
        os.close(fd)

    for line_num, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        non_blank_count += 1
        m = FRAME_RE.search(stripped)
        if not m:
            # §7: non-blank, non-comment line that does not match the canonical
            # ``t_rel  len=N  HH HH ...`` format is a parse error, not a silent skip.
            parse_errors.append(
                f"line {line_num}: unrecognized format: {stripped[:60]!r}"
            )
            continue
        declared_len = int(m.group(1))
        hexs = m.group(2).split()
        actual_len = len(hexs)
        if declared_len != actual_len:
            parse_errors.append(
                f"line {line_num}: len mismatch: declared {declared_len}, "
                f"got {actual_len} bytes"
            )
            continue
        try:
            frames.append(bytes(int(h, 16) for h in hexs))
        except ValueError as exc:
            parse_errors.append(f"line {line_num}: bad hex: {exc}")
            continue
        if len(frames) >= _MAX_FRAMES:
            truncated = True
            break

    return frames, truncated, sha256, parse_errors, non_blank_count


# ---------------------------------------------------------------------------
# Checksum algorithms (byte-level)
# ---------------------------------------------------------------------------

def _crc16_modbus(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def _crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


# ---------------------------------------------------------------------------
# stats subcommand
# ---------------------------------------------------------------------------

def _cmd_stats(args: argparse.Namespace) -> int:
    try:
        frames, truncated, sha256, parse_errors, non_blank_count = _load_frames(args.input)
    except OSError as exc:
        sys.stderr.write(f"serial-frame-analyze: {args.input}: {exc.strerror}\n")
        return 2

    # §7 / BLOCKER-1: ≥1 non-blank line but 0 valid frames → status:failed / exit 1.
    # Distinguishes GARBAGE-input (non_blank_count>0, no frames) from
    # EMPTY-input (non_blank_count==0, no frames → status:complete below).
    if non_blank_count > 0 and not frames:
        result = {
            "errors": parse_errors,
            "line_count": non_blank_count,
            "mode": "stats",
            "schema": SCHEMA,
            "skipped_line_count": len(parse_errors),
            "status": "failed",  # sweep-all-fail
            "tool": "serial-frame-analyze",
        }
        try:
            _write_json(args.output, result)
        except OSError as exc:
            sys.stderr.write(f"serial-frame-analyze: {args.output}: {exc.strerror}\n")
            return 2
        return 1

    length_counts: dict = defaultdict(int)
    for fr in frames:
        length_counts[len(fr)] += 1

    histogram = sorted(
        [{"count": c, "length": L} for L, c in length_counts.items()],
        key=lambda x: (-x["count"], x["length"]),
    )

    most_common_len = max(length_counts, key=length_counts.__getitem__) \
        if length_counts else None

    variability = []
    if most_common_len is not None:
        group = [fr for fr in frames if len(fr) == most_common_len]
        for i in range(most_common_len):
            vals = sorted(set(fr[i] for fr in group))
            variability.append({
                "distinct_count": len(vals),
                "is_constant": len(vals) == 1,
                "position": i,
                "sample_hex": [f"{v:02x}" for v in vals[:6]],
            })

    result = {
        "input": {
            "frame_count": len(frames),
            "line_count": non_blank_count,
            "path": args.input,
            "sha256": sha256,
            "skipped_line_count": len(parse_errors),
        },
        "mode": "stats",
        "results": {
            "length_histogram": histogram,
            "most_common_length": most_common_len,
            "variability": variability,
        },
        "schema": SCHEMA,
        "status": "complete",
        "summary": {
            "distinct_lengths": len(length_counts),
            "frame_count": len(frames),
            "line_count": non_blank_count,
            "skipped_line_count": len(parse_errors),
            "truncated": truncated,
        },
        "tool": "serial-frame-analyze",
        "truncated": truncated,
    }
    if parse_errors:
        result["errors"] = parse_errors

    try:
        _write_json(args.output, result)
    except OSError as exc:
        sys.stderr.write(f"serial-frame-analyze: {args.output}: {exc.strerror}\n")
        return 2

    return 0


# ---------------------------------------------------------------------------
# diff subcommand
# ---------------------------------------------------------------------------

def _cmd_diff(args: argparse.Namespace) -> int:
    try:
        frames_a, trunc_a, sha_a, errors_a, nbl_a = _load_frames(args.input_a)
    except OSError as exc:
        sys.stderr.write(f"serial-frame-analyze: {args.input_a}: {exc.strerror}\n")
        return 2

    try:
        frames_b, trunc_b, sha_b, errors_b, nbl_b = _load_frames(args.input_b)
    except OSError as exc:
        sys.stderr.write(f"serial-frame-analyze: {args.input_b}: {exc.strerror}\n")
        return 2

    # §7 / BLOCKER-1: either input has ≥1 non-blank line but 0 valid frames → failed.
    # Uses non_blank_count to distinguish GARBAGE (>0 non-blank, 0 valid) from
    # EMPTY (0 non-blank, 0 valid → diff of two empty logs is a valid complete result).
    combined_errors = errors_a + errors_b
    if (nbl_a > 0 and not frames_a) or (nbl_b > 0 and not frames_b):
        result = {
            "errors": combined_errors,
            "line_count_a": nbl_a,
            "line_count_b": nbl_b,
            "mode": "diff",
            "schema": SCHEMA,
            "skipped_line_count_a": len(errors_a),
            "skipped_line_count_b": len(errors_b),
            "status": "failed",  # sweep-all-fail
            "tool": "serial-frame-analyze",
        }
        try:
            _write_json(args.output, result)
        except OSError as exc:
            sys.stderr.write(f"serial-frame-analyze: {args.output}: {exc.strerror}\n")
            return 2
        return 1

    def _frame_key(fr: bytes) -> tuple:
        return (len(fr), fr[0] if fr else -1)

    groups_a: dict = defaultdict(list)
    groups_b: dict = defaultdict(list)
    for fr in frames_a:
        groups_a[_frame_key(fr)].append(fr)
    for fr in frames_b:
        groups_b[_frame_key(fr)].append(fr)

    shared_keys = sorted(set(groups_a) & set(groups_b))

    shared_types = []
    for k in shared_keys:
        length, first_byte = k

        def _representative(group: list) -> bytes:
            counts: dict = defaultdict(int)
            for fr in group:
                counts[fr] += 1
            return max(counts, key=counts.__getitem__)

        rep_a = _representative(groups_a[k])
        rep_b = _representative(groups_b[k])
        changed = [i for i in range(length) if rep_a[i] != rep_b[i]]
        shared_types.append({
            "changed_positions": changed,
            "first_byte_hex": f"{first_byte:02x}" if first_byte >= 0 else "??",
            "length": length,
        })

    result = {
        "input_a": {
            "frame_count": len(frames_a),
            "line_count": nbl_a,
            "path": args.input_a,
            "sha256": sha_a,
            "skipped_line_count": len(errors_a),
            "truncated": trunc_a,
        },
        "input_b": {
            "frame_count": len(frames_b),
            "line_count": nbl_b,
            "path": args.input_b,
            "sha256": sha_b,
            "skipped_line_count": len(errors_b),
            "truncated": trunc_b,
        },
        "mode": "diff",
        "results": {"shared_types": shared_types},
        "schema": SCHEMA,
        "status": "complete",
        "summary": {
            "frame_count_a": len(frames_a),
            "frame_count_b": len(frames_b),
            "line_count_a": nbl_a,
            "line_count_b": nbl_b,
            "shared_type_count": len(shared_types),
            "skipped_line_count_a": len(errors_a),
            "skipped_line_count_b": len(errors_b),
        },
        "tool": "serial-frame-analyze",
    }
    # MINOR-1: surface parse errors on the complete path (consistent with stats mode).
    if combined_errors:
        result["errors"] = combined_errors

    try:
        _write_json(args.output, result)
    except OSError as exc:
        sys.stderr.write(f"serial-frame-analyze: {args.output}: {exc.strerror}\n")
        return 2

    return 0


# ---------------------------------------------------------------------------
# checksum subcommand
# ---------------------------------------------------------------------------

def _cmd_checksum(args: argparse.Namespace) -> int:
    try:
        frames, truncated, sha256, parse_errors, non_blank_count = _load_frames(args.input)
    except OSError as exc:
        sys.stderr.write(f"serial-frame-analyze: {args.input}: {exc.strerror}\n")
        return 2

    # §7 / BLOCKER-1: ≥1 non-blank line but 0 valid frames → status:failed / exit 1.
    if non_blank_count > 0 and not frames:
        result = {
            "errors": parse_errors,
            "line_count": non_blank_count,
            "mode": "checksum",
            "schema": SCHEMA,
            "skipped_line_count": len(parse_errors),
            "status": "failed",  # sweep-all-fail
            "tool": "serial-frame-analyze",
        }
        try:
            _write_json(args.output, result)
        except OSError as exc:
            sys.stderr.write(f"serial-frame-analyze: {args.output}: {exc.strerror}\n")
            return 2
        return 1

    useful = [fr for fr in frames if len(fr) >= 3]
    total = len(useful)

    algorithms: list = []
    if total > 0:
        def _test_1byte(fn, name: str, skip: int = 0) -> dict:
            frames_used = sum(1 for fr in useful if len(fr) > skip + 1)
            ok = sum(1 for fr in useful if len(fr) > skip + 1 and fn(fr[skip:-1]) == fr[-1])
            return {
                "candidate": frames_used > 0 and ok == frames_used,
                "hit_count": ok,
                "hit_rate": round(ok / frames_used, 4) if frames_used else 0.0,
                "name": name,
                "skip_first": skip,
                "total_frames": frames_used,
            }

        def _test_2byte(fn, name: str, little_endian: bool, skip: int = 0) -> dict:
            ok = 0
            frames_used = 0
            for fr in useful:
                if len(fr) < skip + 3:
                    continue
                frames_used += 1
                body = fr[skip:-2]
                got = fn(body)
                want = (fr[-2] | (fr[-1] << 8)) if little_endian else ((fr[-2] << 8) | fr[-1])
                if got == want:
                    ok += 1
            return {
                "candidate": frames_used > 0 and ok == frames_used,
                "hit_count": ok,
                "hit_rate": round(ok / frames_used, 4) if frames_used else 0.0,
                "little_endian": little_endian,
                "name": name,
                "skip_first": skip,
                "total_frames": frames_used,
            }

        for skip in (0, 1):
            algorithms.append(_test_1byte(lambda b: sum(b) & 0xFF, "sum8", skip))
            algorithms.append(_test_1byte(lambda b: (-sum(b)) & 0xFF, "twos-comp8", skip))
            algorithms.append(_test_1byte(
                lambda b: __import__('functools').reduce(
                    lambda a, c: a ^ c, b, 0), "xor8", skip))
            algorithms.append(_test_2byte(_crc16_modbus, "crc16-modbus", True, skip))
            algorithms.append(_test_2byte(_crc16_modbus, "crc16-modbus", False, skip))
            algorithms.append(_test_2byte(_crc16_ccitt, "crc16-ccitt", False, skip))

        algorithms.sort(key=lambda x: (-x["hit_count"], x["name"], x["skip_first"]))

    result = {
        "input": {
            "frame_count": len(frames),
            "line_count": non_blank_count,
            "path": args.input,
            "sha256": sha256,
            "skipped_line_count": len(parse_errors),
            "useful_frame_count": total,
        },
        "mode": "checksum",
        "results": {"algorithms": algorithms},
        "schema": SCHEMA,
        "status": "complete",
        "summary": {
            "distinct_lengths": len(set(len(fr) for fr in frames)),
            "frame_count": len(frames),
            "line_count": non_blank_count,
            "skipped_line_count": len(parse_errors),
            "truncated": truncated,
            "useful_frame_count": total,
        },
        "tool": "serial-frame-analyze",
        "truncated": truncated,
    }
    # MINOR-1: surface parse errors on the complete path (consistent with stats mode).
    if parse_errors:
        result["errors"] = parse_errors

    try:
        _write_json(args.output, result)
    except OSError as exc:
        sys.stderr.write(f"serial-frame-analyze: {args.output}: {exc.strerror}\n")
        return 2

    return 0


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog='serial-frame-analyze',
        description=(
            'Offline analysis of serial frame captures (serial-frame.v1). '
            'Read-only; no hardware or network required.'
        ),
    )
    sub = p.add_subparsers(dest='cmd', required=True)

    st = sub.add_parser(
        'stats',
        help='frame-length histogram and per-byte-position variability',
    )
    st.add_argument(
        '--input', required=True, metavar='LOG',
        help='serial frame log file (regular file, not a symlink)',
    )
    st.add_argument(
        '--output', required=True, metavar='JSON',
        help='output JSON evidence file (must not already exist)',
    )

    df = sub.add_parser(
        'diff',
        help='byte-position diff between two captures taken under different conditions',
    )
    df.add_argument(
        '--input-a', required=True, metavar='LOG_A',
        help='baseline capture log file',
    )
    df.add_argument(
        '--input-b', required=True, metavar='LOG_B',
        help='comparison capture log file',
    )
    df.add_argument(
        '--output', required=True, metavar='JSON',
        help='output JSON evidence file (must not already exist)',
    )

    ck = sub.add_parser(
        'checksum',
        help='brute-force common checksum algorithms (sum8, xor8, CRC16-Modbus, CRC16-CCITT)',
    )
    ck.add_argument(
        '--input', required=True, metavar='LOG',
        help='serial frame log file (regular file, not a symlink)',
    )
    ck.add_argument(
        '--output', required=True, metavar='JSON',
        help='output JSON evidence file (must not already exist)',
    )

    return p


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    args = _build_parser().parse_args()
    if args.cmd == 'stats':
        return _cmd_stats(args)
    elif args.cmd == 'diff':
        return _cmd_diff(args)
    else:
        return _cmd_checksum(args)


if __name__ == '__main__':
    sys.exit(main())

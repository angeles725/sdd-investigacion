#!/usr/bin/env python3
"""Shared higher-level adapter helpers for Research-SDD toolbelt adapters.

Built on top of adapter_core primitives.  New adapters (unblob, floss, capa,
kaitai) import from here instead of re-deriving the evidence envelope, the
manifest-CLI tail, and the format parsers that are duplicated across the
three modern adapters (corroborate_pcap.py, pcap_flows.py, squashfs_extract.py).

Item-24 will migrate the existing adapters by replacing inline duplications
with imports from this module.  This unit only ADDS; no existing adapter is
modified here.

Dependency direction: adapter_helpers → adapter_core (never the reverse).
"""
from __future__ import annotations

import os
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Sibling import: adapter_core lives in the same lib/ directory.
# spec_from_file_location is used by the test harness, which does not insert
# lib/ into sys.path.  We do it ourselves to make `import adapter_core` work
# regardless of how this module was loaded.
# ---------------------------------------------------------------------------
_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import adapter_core as ac  # noqa: E402 (after sys.path fixup)
from adapter_core import AdapterError  # re-exported for callers that want one import

# ---------------------------------------------------------------------------
# pcap / pcapng magic-byte constants
# Duplicated in corroborate_pcap.py and pcap_flows.py — item-24 migrates both
# to import _PCAP_MAGIC and _PCAPNG_MAGIC from here.
# ---------------------------------------------------------------------------
# libpcap variants: little-endian microsecond, big-endian microsecond,
#                   little-endian nanosecond, big-endian nanosecond.
_PCAP_MAGIC: frozenset[bytes] = frozenset([
    b'\xd4\xc3\xb2\xa1',  # LE microsecond (most common)
    b'\xa1\xb2\xc3\xd4',  # BE microsecond
    b'\x4d\x3c\xb2\xa1',  # LE nanosecond
    b'\xa1\xb2\x3c\x4d',  # BE nanosecond
])
_PCAPNG_MAGIC: bytes = b'\x0a\x0d\x0d\x0a'  # pcapng Section Header Block type

# ---------------------------------------------------------------------------
# SquashFS v4 LE superblock constants
# Duplicated in squashfs_extract.py and firmware_carve.py — item-24 migrates
# both to import SQFS_* from here.
# ---------------------------------------------------------------------------
SQFS_SB_FMT: str = "<5I6H8Q"                    # 5×uint32 + 6×uint16 + 8×uint64
SQFS_SB_SIZE: int = struct.calcsize(SQFS_SB_FMT) # 96 bytes
SQFS_FLAG_EXPORTABLE: int = 0x80                 # superblock flags bit 7
_SQFS_MAGIC_BYTES: bytes = b"hsqs"               # LE on-disk representation
_SQFS_SENTINEL: int = 0xFFFFFFFFFFFFFFFF         # absent-table sentinel value


# ---------------------------------------------------------------------------
# Named error classes
# ---------------------------------------------------------------------------

class ManifestError(AdapterError):
    """Raised when any manifest-CLI step (create/validate/verify) or publish fails.

    Fail-closed: callers must handle this; there is no silent fallback.
    """


class PcapMagicError(AdapterError):
    """Raised when a file fails pcap/pcapng magic-byte validation.

    Also raised for symlinks (O_NOFOLLOW enforcement) and unreadable files.
    """


# ---------------------------------------------------------------------------
# HELPER A — emit_evidence
# ---------------------------------------------------------------------------

def emit_evidence(
    *,
    stage: Path,
    schema: str,
    domain: dict[str, Any],
    input_identity: dict[str, Any],
    isolation: dict[str, Any],
    limitations: list[str],
    errors: list[str],
    manifest_spec: dict[str, Any],
    manifest_cli: Path,
    destination: Path,
    timeout: int = 60,
) -> None:
    """Assemble the standard evidence envelope and run the manifest-CLI tail.

    This is the common "tail" shared by all three modern adapters.  It
    centralises the timeout= omission that was a recurring 4R finding.

    Steps (all fail-closed; raises ManifestError on any failure):

    1. Assemble standard envelope:
         {schema, status, input, isolation, limitations, errors, **domain}
       status is "complete" when errors=[] else "failed".
    2. Write envelope as stage/{schema}.json via adapter_core.write (atomic).
    3. Write manifest_spec as stage/engine/manifest-spec.json.
    4. Run manifest_cli create  --root stage --spec … --output …  (timeout=)
    5. Unlink spec.
    6. Run manifest_cli validate …                                 (timeout=)
    7. Run manifest_cli verify  --root stage …                     (timeout=)
    8. adapter_core.publish(stage, destination).

    Parameters
    ----------
    stage:          Staging directory (already populated by the caller).
    schema:         Schema identifier string, e.g. "pcap-evidence.v1".
    domain:         Adapter-specific evidence fields merged into the envelope.
    input_identity: {"source": record, "staged": record} from stage_file().
    isolation:      {"launcher": record, "profile": dict}.
    limitations:    Human-readable limitation strings (passed through).
    errors:         Tool error strings collected during the analysis run.
    manifest_spec:  Full analysis-manifest spec dict (built by the adapter).
    manifest_cli:   Absolute path to analysis_manifest.py.
    destination:    Final publish path (must not exist).
    timeout:        Seconds applied to EVERY manifest-CLI subprocess.run call.
                    Mandatory; default 60. Raise ManifestError on expiry.
    """
    status = "failed" if errors else "complete"
    envelope: dict[str, Any] = {
        "errors": errors,
        "input": input_identity,
        "isolation": isolation,
        "limitations": limitations,
        "schema": schema,
        "status": status,
        **domain,  # domain fields last so adapter can override envelope defaults
    }
    ac.write(stage / f"{schema}.json", envelope)

    spec_path = stage / "engine" / "manifest-spec.json"
    ac.write(spec_path, manifest_spec)

    manifest_path = stage / "engine" / "analysis-manifest.v1.json"
    cli_base = [sys.executable, str(manifest_cli)]

    def _run_cli(verb: str, extra: list[str]) -> None:
        """Run one manifest-CLI verb.  Always passes timeout=.  Fail-closed."""
        try:
            subprocess.run(cli_base + [verb] + extra, check=True, timeout=timeout)
        except subprocess.CalledProcessError as exc:
            raise ManifestError(
                f"manifest-cli '{verb}' failed (exit {exc.returncode})"
            ) from exc
        except subprocess.TimeoutExpired as exc:
            raise ManifestError(
                f"manifest-cli '{verb}' timed out after {timeout}s"
            ) from exc

    _run_cli("create", [
        "--root", str(stage),
        "--spec", str(spec_path),
        "--output", str(manifest_path),
    ])
    spec_path.unlink()
    _run_cli("validate", [str(manifest_path)])
    _run_cli("verify", ["--root", str(stage), str(manifest_path)])

    try:
        ac.publish(stage, destination)
    except (AdapterError, OSError) as exc:
        raise ManifestError(f"publish failed: {exc}") from exc


# ---------------------------------------------------------------------------
# HELPER B — pcap_magic_check
# ---------------------------------------------------------------------------

def pcap_magic_check(path: Path) -> None:
    """Open *path* with O_NOFOLLOW and validate pcap/pcapng magic bytes.

    Accepts:
    - libpcap: LE/BE × microsecond/nanosecond (four variants in _PCAP_MAGIC)
    - pcapng: Section Header Block magic (_PCAPNG_MAGIC)

    Raises PcapMagicError on:
    - Symlinks (O_NOFOLLOW enforced at the kernel level).
    - Unreadable or non-regular files.
    - Bad magic bytes (first 4 bytes do not match any known variant).

    Does not raise AdapterError subclasses other than PcapMagicError so that
    callers can narrow their except clauses.
    """
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise PcapMagicError(
            f"cannot open (symlink or unreadable): {path}"
        ) from exc
    try:
        magic = os.read(fd, 4)
    finally:
        os.close(fd)
    if magic not in _PCAP_MAGIC and magic != _PCAPNG_MAGIC:
        raise PcapMagicError(
            f"not a pcap/pcapng file (magic 0x{magic.hex()}): {path}"
        )


# ---------------------------------------------------------------------------
# HELPER C — squashfs_superblock
# ---------------------------------------------------------------------------

def squashfs_superblock(
    data: bytes | memoryview,
    offset: int = 0,
) -> dict[str, Any] | None:
    """Parse and validate a SquashFS v4 LE superblock at *offset* in *data*.

    Returns a dict of parsed fields when the superblock at *offset* is a
    structurally valid SquashFS v4 LE superblock; returns None otherwise
    (wrong magic, failed validation, or insufficient bytes at *offset*).

    Struct layout (SQFS_SB_FMT = "<5I6H8Q"):
      uint32: magic, inodes, mtime, block_size, fragments
      uint16: compression, block_log, flags, ids, major, minor
      uint64: root_inode, bytes_used, id_table, xattr_table,
              inode_table, directory_table, fragment_table, export_table

    Validation rules (mirrors squashfs_extract.py and firmware_carve.py):
    - magic == b'hsqs'  (0x73717368 packed as LE uint32)
    - major == 4, minor == 0
    - compression in 1..6  (ZLIB=1, LZMA=2, LZO=3, XZ=4, LZ4=5, ZSTD=6)
    - block_size == 1 << block_log, 4096 ≤ block_size ≤ 1048576
    - inodes > 0, ids > 0
    - bytes_used ≥ SQFS_SB_SIZE, offset+bytes_used ≤ len(data)
    - table pointers: sentinel (0xfff…f) or SQFS_SB_SIZE ≤ ptr < bytes_used
    - required tables (id, inode, directory; fragment if fragments>0;
      export if SQFS_FLAG_EXPORTABLE set) must NOT be sentinel
    """
    data_len = len(data)
    if offset + SQFS_SB_SIZE > data_len:
        return None
    if bytes(data[offset:offset + 4]) != _SQFS_MAGIC_BYTES:
        return None
    try:
        fields = struct.unpack_from(SQFS_SB_FMT, data, offset)
    except struct.error:
        return None
    (_, inodes, mtime, block_size, fragments,
     compression, block_log, flags, ids, major, minor,
     root_inode, bytes_used,
     id_table, xattr_table, inode_table, directory_table,
     fragment_table, export_table) = fields

    end = offset + bytes_used

    def _valid_table(ptr: int) -> bool:
        return ptr == _SQFS_SENTINEL or (SQFS_SB_SIZE <= ptr < bytes_used)

    required = (
        [id_table, inode_table, directory_table]
        + ([fragment_table] if fragments else [])
        + ([export_table] if flags & SQFS_FLAG_EXPORTABLE else [])
    )

    if not (
        inodes > 0
        and ids > 0
        and major == 4
        and minor == 0
        and compression in range(1, 7)
        and block_size == (1 << block_log)
        and 4096 <= block_size <= 1048576
        and bytes_used >= SQFS_SB_SIZE
        and end <= data_len
        and all(_valid_table(x) for x in (
            id_table, xattr_table, inode_table,
            directory_table, fragment_table, export_table,
        ))
        and all(x != _SQFS_SENTINEL for x in required)
    ):
        return None

    return {
        "block_log": block_log,
        "block_size": block_size,
        "bytes_used": bytes_used,
        "compression": compression,
        "directory_table": directory_table,
        "export_table": export_table,
        "flags": flags,
        "fragment_table": fragment_table,
        "fragments": fragments,
        "id_table": id_table,
        "ids": ids,
        "inode_table": inode_table,
        "inodes": inodes,
        "major": major,
        "minor": minor,
        "mtime": mtime,
        "root_inode": root_inode,
        "xattr_table": xattr_table,
    }

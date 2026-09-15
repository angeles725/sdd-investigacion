#!/usr/bin/env python3
"""Niagara N4 .hdb history file reader.

Reads a Niagara N4 binary history file (.hdb), extracts the embedded HistoryConfig
XML schema, and emits key-sorted JSON evidence.  Read-only; no writes to the input
file, no subprocesses, no external dependencies.

On-disk format (confirmed against real Niagara N4 .hdb history files):
  [0:4]    magic 0xA106F11E (big-endian)
  [4:8]    version (big-endian uint32; observed 2)
  [8:12]   config XML length (big-endian uint32)
  [12:12+len]  embedded HistoryConfig XML (cleartext when
               reversibleEncodingKeySource="none")
  [12+len:]    record region (binary; never decoded by this reader)

Exit codes:
  0  complete  -- valid .hdb, schema extracted successfully
  1  parse error -- bad magic, corrupt header, or XML length mismatch
                    (status:failed JSON is emitted to --output)
  2  I/O error -- absent, unreadable, or symlink input/output (no JSON emitted)

Anti-silent-zero (S7): three states are always distinguishable:
  absent-or-unreadable  -- missing, unreadable, non-regular, or symlink -> exit 2, no JSON
  parse-error           -- bad magic, cap exceeded, or corrupt header -> exit 1, status:failed JSON
  valid                 -- correct header + XML -> exit 0, status:complete JSON
"""
import argparse
import errno
import hashlib
import json
import os
import re
import stat as _stat
import struct
import sys

SCHEMA = "niagara-hdb.v1"
_MAGIC = b'\xa1\x06\xf1\x1e'   # 0xA106F11E big-endian
_HEADER_SIZE = 12               # magic(4) + version(4) + config_xml_len(4)

# Absolute cap on config XML length to bound memory and regex CPU.
# Fleet files use ~1600 B; 1 MiB is generous.  Any declared clen above this
# constant is rejected with a parse error rather than read into memory.
_MAX_CONFIG_BYTES = 1 << 20     # 1 MiB

# O_NOFOLLOW / O_NONBLOCK / O_CLOEXEC are Linux-specific; getattr guards for other OSes
_O_NOFOLLOW  = getattr(os, 'O_NOFOLLOW', 0)
_O_NONBLOCK  = getattr(os, 'O_NONBLOCK', 0)
_O_CLOEXEC   = getattr(os, 'O_CLOEXEC', 0)


class _HdbError(Exception):
    """Parse-level error: invalid or unsupported .hdb structure."""


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def _open_ro(path):
    """Open path read-only, rejecting symlinks via O_NOFOLLOW.

    O_NONBLOCK is also set so that opening a non-regular file (e.g. a FIFO)
    does not block; the S_ISREG check in cmd_read rejects it immediately after.
    For regular files O_NONBLOCK has no effect on read() behaviour.
    """
    try:
        return os.open(str(path), os.O_RDONLY | _O_NOFOLLOW | _O_NONBLOCK)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise OSError(errno.ELOOP, "is a symbolic link (rejected)", str(path)) from exc
        raise


def _open_wo_new(path):
    """Open path write-only for a new file; refuse symlinks and pre-existing files.

    Uses O_CREAT|O_EXCL|O_NOFOLLOW so a pre-existing symlink or regular file at
    *path* causes the open to fail (ELOOP / EEXIST -> OSError -> exit 2).
    """
    return os.open(
        str(path),
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW | _O_CLOEXEC,
        0o600,
    )


def _sha256_fd(fd):
    h = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        h.update(chunk)
    return h.hexdigest()


def _write_json(path, data):
    """Write *data* as key-sorted JSON to *path*, refusing symlinks (O_NOFOLLOW)."""
    content = (json.dumps(data, indent=2, sort_keys=True) + '\n').encode('utf-8')
    fd = _open_wo_new(path)
    try:
        os.write(fd, content)
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# XML config parser (no external deps)
# ---------------------------------------------------------------------------

def _parse_xml_config(xml_text):
    """Extract HistoryConfig fields from the embedded XML.

    Returns a dict with keys: history_id, record_type, reversible_encoding,
    schema_fields, source, time_zone.  Missing attributes default to None or [].
    Never raises; invalid XML yields None/empty defaults.
    """
    result = {
        'history_id': None,
        'record_type': None,
        'reversible_encoding': None,
        'schema_fields': [],
        'source': None,
        'time_zone': None,
    }

    # history_id: <p n="id" ... v="..."/>
    m = re.search(r'n="id"[^>]*v="([^"]*)"', xml_text)
    if m:
        result['history_id'] = m.group(1)

    # record_type: <p n="recordType" ... v="..."/>
    m = re.search(r'n="recordType"[^>]*v="([^"]*)"', xml_text)
    if m:
        result['record_type'] = m.group(1)

    # schema_fields: v="timestamp,baja:AbsTime;value,baja:Double"
    m = re.search(r'n="schema"[^>]*v="([^"]*)"', xml_text)
    if m:
        fields = []
        for pair in m.group(1).split(';'):
            pair = pair.strip()
            if ',' in pair:
                name, typ = pair.split(',', 1)
                fields.append({'name': name.strip(), 'type': typ.strip()})
        result['schema_fields'] = fields

    # time_zone: <p n="timeZone" ... v="..."/>
    m = re.search(r'n="timeZone"[^>]*v="([^"]*)"', xml_text)
    if m:
        result['time_zone'] = m.group(1)

    # source: <p n="source" ... v="..."/>
    m = re.search(r'n="source"[^>]*v="([^"]*)"', xml_text)
    if m:
        result['source'] = m.group(1)

    # reversibleEncodingKeySource from the root element attribute
    m = re.search(r'reversibleEncodingKeySource="([^"]*)"', xml_text)
    if m:
        result['reversible_encoding'] = m.group(1)

    return result


# ---------------------------------------------------------------------------
# Main command
# ---------------------------------------------------------------------------

def cmd_read(args):
    fd = None
    try:
        # --- Open input -------------------------------------------------------
        try:
            fd = _open_ro(args.input)
        except OSError as exc:
            sys.stderr.write(f"niagara-hdb-read: {args.input}: {exc.strerror}\n")
            return 2

        stat_result = os.fstat(fd)
        file_size = stat_result.st_size

        # Reject non-regular files (FIFOs, device files, sockets, directories).
        # Checked before hashing so a FIFO does not cause a hang in _sha256_fd.
        if not _stat.S_ISREG(stat_result.st_mode):
            sys.stderr.write(
                f"niagara-hdb-read: {args.input}: not a regular file\n"
            )
            return 2

        sha256 = _sha256_fd(fd)

        # --- Parse header and XML --------------------------------------------
        errors = []
        history_config = {
            'history_id': None,
            'record_type': None,
            'reversible_encoding': None,
            'schema_fields': [],
            'source': None,
            'time_zone': None,
        }
        summary = {
            'config_xml_bytes': None,
            'field_count': 0,
            'record_region_bytes': None,
            'version': None,
        }

        try:
            if file_size < _HEADER_SIZE:
                raise _HdbError(
                    f"file too small to contain an .hdb header "
                    f"({file_size} bytes, need at least {_HEADER_SIZE})"
                )

            os.lseek(fd, 0, os.SEEK_SET)
            header = os.read(fd, _HEADER_SIZE)
            if len(header) < _HEADER_SIZE:
                raise _HdbError("short read on header")

            if header[:4] != _MAGIC:
                raise _HdbError(
                    f"bad magic 0x{header[:4].hex().upper()} "
                    f"(expected 0x{_MAGIC.hex().upper()}); not a Niagara .hdb file"
                )

            version, = struct.unpack(">I", header[4:8])
            clen, = struct.unpack(">I", header[8:12])
            summary['version'] = version

            # Absolute cap on config XML length: prevents OOM and O(n²) regex
            # cost on crafted files regardless of declared file size.
            # Fleet files use ~1600 B; 1 MiB is generous.
            if clen > _MAX_CONFIG_BYTES:
                raise _HdbError(
                    f"config_xml_len {clen} exceeds absolute cap "
                    f"({_MAX_CONFIG_BYTES}); refusing to read"
                )

            # Read config XML
            os.lseek(fd, _HEADER_SIZE, os.SEEK_SET)
            xml_bytes = os.read(fd, clen)
            if len(xml_bytes) < clen:
                raise _HdbError(
                    f"short read on config XML: expected {clen} bytes, "
                    f"got {len(xml_bytes)}"
                )

            xml_text = xml_bytes.decode('utf-8', 'replace')
            history_config = _parse_xml_config(xml_text)

            record_region_bytes = max(0, file_size - _HEADER_SIZE - clen)
            summary['config_xml_bytes'] = clen
            summary['field_count'] = len(history_config['schema_fields'])
            summary['record_region_bytes'] = record_region_bytes

        except (_HdbError, struct.error) as exc:
            errors.append(str(exc))

        result = {
            'errors': errors,
            'history_config': history_config,
            'input': {
                'sha256': sha256,
                'size_bytes': file_size,
            },
            'limitations': [
                'Record binary region is not decoded; '
                'only the embedded XML schema is extracted.',
                'Encrypted record regions '
                '(reversibleEncodingKeySource != "none") are not decrypted.',
            ],
            'schema': SCHEMA,
            'status': 'failed' if errors else 'complete',
            'summary': summary,
        }

        _write_json(args.output, result)
        return 1 if errors else 0

    except OSError as exc:
        sys.stderr.write(f"niagara-hdb-read: I/O error: {exc}\n")
        return 2
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def _build_parser():
    p = argparse.ArgumentParser(
        prog='niagara-hdb-read',
        description='Read-only Niagara N4 .hdb history file reader.',
    )
    p.add_argument('--input', required=True, metavar='FILE',
                   help='Niagara N4 .hdb file (regular file, not a symlink)')
    p.add_argument('--output', required=True, metavar='JSON',
                   help='output JSON evidence file path (must not already exist)')
    return p


def main():
    args = _build_parser().parse_args()
    sys.exit(cmd_read(args))


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""QNX6 Power-Safe filesystem reader.

Reads a raw QNX6 (Power-Safe) disk image, enumerates the filesystem tree,
and emits key-sorted JSON evidence.  Read-only; no writes, no subprocesses,
no external dependencies.

Exit codes for `list`:
  0  complete — valid QNX6, walk finished
  1  parse or walk error — invalid structure (status:failed JSON emitted)
  2  I/O error — absent, unreadable, or symlink input/output (no JSON emitted)

Exit codes for `extract`:
  0  extraction successful
  1  parse error — not a valid QNX6 image, or path not found in filesystem
  2  I/O error — absent/unreadable input, symlink input or output, or other I/O

Anti-silent-zero (§7): three states are always distinguishable:
  absent-input   — missing or unreadable file → exit 2, no JSON
  empty-input    — valid QNX6 with no entries → exit 0, total_entries=0
  parse-error    — bad magic or corrupt structure → exit 1, status:failed
"""
import argparse
import errno
import hashlib
import json
import os
import stat
import struct
import sys
from pathlib import Path

SCHEMA = "qnx6-evidence.v1"
_SUPERBLOCK_OFFSET = 0x2000  # superblock is always at partition_offset + 0x2000
_MAGIC = 0x68191122
_INODE_SIZE = 128
_DIRENT_SIZE = 32
_LONGNAME_SENTINEL = 0xFF
_MAX_DEPTH = 40

# O_NOFOLLOW / O_CLOEXEC / O_NONBLOCK are Linux-specific; getattr guards for other OSes.
# O_NONBLOCK is required so that opening a FIFO, socket, or block device does not block
# indefinitely; the S_ISREG check below then rejects non-regular inputs.
_O_NOFOLLOW  = getattr(os, 'O_NOFOLLOW',  0)
_O_CLOEXEC   = getattr(os, 'O_CLOEXEC',   0)
_O_NONBLOCK  = getattr(os, 'O_NONBLOCK',  0)


# ---------------------------------------------------------------------------
# QNX6 binary reader (stdlib only, read-only)
# ---------------------------------------------------------------------------

class _QNX6Error(Exception):
    """Parse-level error: invalid or unsupported QNX6 structure."""


def _parse_rn(sb, off):
    """Return (size, ptrs, levels) root-node tuple from superblock bytes."""
    size, = struct.unpack_from('<Q', sb, off)
    ptrs = list(struct.unpack_from('<16I', sb, off + 8))
    levels = sb[off + 72]
    return size, ptrs, levels


class QNX6Reader:
    """Read-only QNX6 filesystem reader operating on an open file descriptor."""

    def __init__(self, fd, partition_offset=0):
        self._fd = fd
        self._poff = partition_offset
        self._bs = 512
        self._off = 0          # block offset (auto-detected)
        self._inode_table = b''
        self._longfile = b''
        self.block_size = 0
        self.num_inodes = 0
        self.num_blocks = 0

    def parse(self):
        """Parse superblock and load index tables.  Raises _QNX6Error on failure."""
        os.lseek(self._fd, self._poff + _SUPERBLOCK_OFFSET, os.SEEK_SET)
        sb = os.read(self._fd, 0x1000)
        if len(sb) < 0x131:
            raise _QNX6Error("image too small to contain a QNX6 superblock")
        magic, = struct.unpack_from('<I', sb, 0)
        if magic != _MAGIC:
            raise _QNX6Error(
                f"bad magic 0x{magic:08x} (expected 0x{_MAGIC:08x}); "
                "not a QNX6 Power-Safe image"
            )
        bs, num_inodes, _free, num_blocks = struct.unpack_from('<IIII', sb, 48)
        if bs < 512:
            raise _QNX6Error(f"invalid block size {bs} in superblock")
        self._bs = bs
        self.block_size = bs
        self.num_inodes = num_inodes
        self.num_blocks = num_blocks
        self._inode_rn = _parse_rn(sb, 72)
        self._longfile_rn = _parse_rn(sb, 232)
        self._off = self._detect_off()
        self._inode_table = self._read_rn_file(*self._inode_rn)
        self._longfile = self._read_rn_file(*self._longfile_rn)

    def _rawblk(self, blk):
        pos = self._poff + (blk + self._off) * self._bs
        os.lseek(self._fd, pos, os.SEEK_SET)
        return os.read(self._fd, self._bs)

    def _leaf_blks(self, ptrs, levels):
        for p in ptrs:
            if p == 0xFFFFFFFF:
                continue
            if levels == 0:
                yield p
            else:
                raw = self._rawblk(p)
                sub = struct.unpack_from(f'<{self._bs // 4}I', raw)
                yield from self._leaf_blks(sub, levels - 1)

    def _read_rn_file(self, size, ptrs, levels):
        if size == 0:
            return b''
        # Cap reads at real (st_size - partition_offset) so a crafted superblock
        # with inflated size or num_blocks cannot drive an unbounded accumulation.
        # This bounds the bytearray regardless of what the untrusted superblock claims.
        try:
            real_file_bytes = max(0, os.fstat(self._fd).st_size - self._poff)
        except OSError:
            real_file_bytes = size  # fstat failed; fall back to declared size
        cap = min(size, real_file_bytes) if real_file_bytes > 0 else size
        buf = bytearray()
        for blk in self._leaf_blks(ptrs, levels):
            buf += self._rawblk(blk)
            if len(buf) >= cap:
                break
        return bytes(buf[:size])

    def _detect_off(self):
        """Try candidate block offsets until the root inode looks like a directory."""
        size, ptrs, levels = self._inode_rn
        if size == 0:
            return 0
        saved = self._off
        for cand in range(40):
            self._off = cand
            try:
                for blk in self._leaf_blks(ptrs, levels):
                    raw = self._rawblk(blk)
                    if len(raw) >= 34:
                        di_size, = struct.unpack_from('<Q', raw, 0)
                        di_mode, = struct.unpack_from('<H', raw, 32)
                        if (di_mode & 0xF000) == 0x4000 and 0 < di_size < 50_000_000:
                            return cand
                    break
            except OSError:
                pass
        self._off = saved
        raise _QNX6Error(
            "cannot locate block offset; image may be corrupt or use an unsupported layout"
        )

    def inode(self, ino):
        off = (ino - 1) * _INODE_SIZE
        e = self._inode_table[off:off + _INODE_SIZE]
        if len(e) < _INODE_SIZE:
            raise _QNX6Error(f"inode {ino} out of range")
        return {
            'levels': e[100],
            'mode': struct.unpack_from('<H', e, 32)[0],
            'ptrs': list(struct.unpack_from('<16I', e, 36)),
            'size': struct.unpack_from('<Q', e, 0)[0],
        }

    def _longname(self, idx):
        off = idx * self._bs
        if off + 2 > len(self._longfile):
            raise _QNX6Error(f"longname index {idx} out of range")
        ln, = struct.unpack_from('<H', self._longfile, off)
        return self._longfile[off + 2:off + 2 + ln].decode('latin-1', errors='replace')

    def listdir(self, ino):
        node = self.inode(ino)
        data = self._read_rn_file(node['size'], node['ptrs'], node['levels'])
        # Distinguish truncated read from genuinely-empty directory (§7 anti-silent-zero).
        # If the returned data is shorter than the declared directory size, the data
        # block is past EOF or the image is cut mid-dirent — that is a parse error,
        # not an empty directory.
        if node['size'] > 0 and len(data) < node['size']:
            raise _QNX6Error(
                f"directory data truncated: inode {ino} declared {node['size']} bytes"
                f" but only {len(data)} were readable (image truncated or block past EOF)"
            )
        entries = []
        for o in range(0, len(data), _DIRENT_SIZE):
            e = data[o:o + _DIRENT_SIZE]
            if len(e) < _DIRENT_SIZE:
                break
            de_ino, = struct.unpack_from('<I', e, 0)
            de_sz = e[4]
            if de_ino == 0:
                continue
            if de_sz == _LONGNAME_SENTINEL:
                lidx, = struct.unpack_from('<I', e, 8)
                name = self._longname(lidx)
            else:
                name = e[5:5 + de_sz].decode('latin-1', errors='replace')
            if name in ('.', '..'):
                continue
            entries.append((name, de_ino))
        return entries

    def walk(self, ino=1, base='', depth=0, visited=None, truncated=None):
        """Yield (path, mode, size, is_dir) for every entry reachable from ino.

        visited  — mutable set of already-descended inode numbers; a repeated
                   inode is not re-descended (prevents cyclic-dir OOM).
        truncated — single-element list [bool]; set to True when the depth cap
                    fires so callers can surface visibility (§7 truncation).
        """
        if visited is None:
            visited = set()
        if truncated is None:
            truncated = [False]
        if depth > _MAX_DEPTH:
            truncated[0] = True
            return
        if ino in visited:
            return
        visited.add(ino)
        for name, child in sorted(self.listdir(ino)):
            path = base + '/' + name
            node = self.inode(child)
            is_dir = (node['mode'] & 0xF000) == 0x4000
            yield path, node['mode'], node['size'], is_dir
            if is_dir:
                yield from self.walk(child, path, depth + 1, visited, truncated)

    def resolve(self, fs_path):
        """Resolve an absolute fs_path.  Returns (ino, node) or None."""
        ino = 1
        for part in [p for p in fs_path.split('/') if p]:
            found = next((c for n, c in self.listdir(ino) if n == part), None)
            if found is None:
                return None
            ino = found
        return ino, self.inode(ino)


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def _open_ro(path):
    """Open path read-only, rejecting symlinks via O_NOFOLLOW.

    O_NONBLOCK is included so that opening a FIFO or other special file does not
    block waiting for a writer.  The caller must check S_ISREG immediately after
    and reject non-regular inputs.  On regular files O_NONBLOCK has no effect.
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
    *path* causes the open to fail (ELOOP / EEXIST → OSError → exit 2).
    This matches the pattern used in zip_stored.py and squashfs_extract.py.
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
# Subcommands
# ---------------------------------------------------------------------------

def cmd_list(args):
    fd = None
    try:
        try:
            fd = _open_ro(args.input)
        except OSError as exc:
            sys.stderr.write(f"qnx6-read: {args.input}: {exc.strerror}\n")
            return 2

        stat_result = os.fstat(fd)
        if not stat.S_ISREG(stat_result.st_mode):
            sys.stderr.write(
                f"qnx6-read: {args.input}: not a regular file (rejected)\n"
            )
            return 2
        sha256 = _sha256_fd(fd)

        rdr = QNX6Reader(fd, args.partition_offset)
        errors = []
        try:
            rdr.parse()
        except (_QNX6Error, struct.error) as exc:
            errors.append(str(exc))

        entries = []
        dirs = files = 0
        truncated_flag = [False]
        if not errors:
            try:
                for path, mode, size, is_dir in rdr.walk(truncated=truncated_flag):
                    entries.append({
                        'mode': mode,
                        'path': path,
                        'size_bytes': size,
                        'type': 'dir' if is_dir else 'file',
                    })
                    if is_dir:
                        dirs += 1
                    else:
                        files += 1
            except (_QNX6Error, struct.error) as exc:
                errors.append(f"walk error: {exc}")

        result = {
            'entries': entries,
            'errors': errors,
            'filesystem': {
                'block_size': rdr.block_size if not errors else None,
                'filesystem_type': 'QNX6 Power-Safe',
                'num_blocks': rdr.num_blocks if not errors else None,
                'num_inodes': rdr.num_inodes if not errors else None,
            },
            'input': {
                'partition_offset': args.partition_offset,
                'sha256': sha256,
                'size_bytes': stat_result.st_size,
            },
            'limitations': [
                'Directory tree enumerated recursively up to depth 40.',
                'Filenames decoded as latin-1 with replacement on error.',
            ],
            'schema': SCHEMA,
            'status': 'failed' if errors else 'complete',
            'summary': {'dirs': dirs, 'files': files, 'total_entries': dirs + files},
            'truncated': truncated_flag[0],
        }
        _write_json(args.output, result)
        return 1 if errors else 0

    except OSError as exc:
        sys.stderr.write(f"qnx6-read: I/O error: {exc}\n")
        return 2
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass


def cmd_extract(args):
    fd = None
    try:
        try:
            fd = _open_ro(args.input)
        except OSError as exc:
            sys.stderr.write(f"qnx6-read: {args.input}: {exc.strerror}\n")
            return 2

        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            sys.stderr.write(
                f"qnx6-read: {args.input}: not a regular file (rejected)\n"
            )
            return 2

        rdr = QNX6Reader(fd, args.partition_offset)
        try:
            rdr.parse()
        except (_QNX6Error, struct.error) as exc:
            sys.stderr.write(f"qnx6-read: parse error: {exc}\n")
            return 1

        result = rdr.resolve(args.fs_path)
        if result is None:
            sys.stderr.write(f"qnx6-read: {args.fs_path}: path not found in image\n")
            return 1

        ino, node = result
        data = rdr._read_rn_file(node['size'], node['ptrs'], node['levels'])
        out_fd = _open_wo_new(args.output)
        try:
            os.write(out_fd, data)
        finally:
            os.close(out_fd)
        return 0

    except OSError as exc:
        sys.stderr.write(f"qnx6-read: I/O error: {exc}\n")
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
        prog='qnx6-read',
        description='Read-only QNX6 Power-Safe filesystem reader.',
    )
    sub = p.add_subparsers(dest='cmd', required=True)

    lst = sub.add_parser('list', help='enumerate filesystem tree to JSON evidence')
    lst.add_argument('--input', required=True, metavar='IMAGE',
                     help='raw disk image file (regular file, not a symlink)')
    lst.add_argument('--partition-offset', type=int, default=0, metavar='BYTES',
                     help='byte offset of the QNX6 partition within the image (default: 0)')
    lst.add_argument('--output', required=True, metavar='JSON',
                     help='output JSON evidence file path (must not already exist)')

    ext = sub.add_parser('extract', help='extract a single file from the filesystem')
    ext.add_argument('--input', required=True, metavar='IMAGE',
                     help='raw disk image file (regular file, not a symlink)')
    ext.add_argument('--fs-path', required=True, metavar='PATH',
                     help='absolute path of the file within the QNX6 filesystem')
    ext.add_argument('--partition-offset', type=int, default=0, metavar='BYTES',
                     help='byte offset of the QNX6 partition within the image (default: 0)')
    ext.add_argument('--output', required=True, metavar='FILE',
                     help='destination path for the extracted file (must not already exist)')

    return p


def main():
    args = _build_parser().parse_args()
    if args.cmd == 'list':
        sys.exit(cmd_list(args))
    else:
        sys.exit(cmd_extract(args))


if __name__ == '__main__':
    main()

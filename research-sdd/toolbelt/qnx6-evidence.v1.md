# `qnx6-evidence.v1`

`qnx6-read.sh list --input <image> [--partition-offset N] --output <evidence.json>`
reads a raw QNX6 Power-Safe filesystem disk image, walks the directory tree,
and emits a deterministic key-sorted JSON evidence envelope.

Uses only Python stdlib; no external tools or network access required.
Read-only: no writes, no subprocesses, no extraction to disk (use the `extract`
subcommand separately when file content is needed).

## Trust Boundary And Accepted Input

Any regular, non-symlink file containing a QNX6 Power-Safe filesystem.

- **Symlink input**: rejected via `O_NOFOLLOW`; exit 2, no evidence emitted.
- **Absent or unreadable file**: exit 2, no evidence emitted.
- **Not a QNX6 image (wrong magic)**: `status: failed`; exit 1; JSON emitted
  with `errors` populated and `entries: []`.
- **Valid QNX6 with no entries**: `status: complete`; exit 0; `total_entries: 0`
  proves the reader opened and walked the filesystem and found no entries —
  never returned when the parse failed.
- **Valid QNX6 with entries**: `status: complete`; exit 0; `entries` list populated.
- **Corrupt structure during walk** (dangling inode, struct truncation): `status:
  failed`; exit 1; JSON emitted with `errors` populated and partial `entries`.
- **Multi-partition images**: pass `--partition-offset BYTES` to locate the
  QNX6 superblock at a non-zero offset within the image.

## Exit Codes

### `list` subcommand

| Code | Meaning |
|---|---|
| 0 | Complete — valid QNX6, walk finished |
| 1 | Parse or walk error — invalid structure (`status:failed` JSON emitted) |
| 2 | I/O error — absent/unreadable input or symlink input/output (no JSON) |

### `extract` subcommand

| Code | Meaning |
|---|---|
| 0 | Extraction successful |
| 1 | Parse error (bad image) or path not found in filesystem |
| 2 | I/O error — absent/unreadable input, symlink input or output, or other I/O |

## Evidence Schema (`qnx6-evidence.v1.json`)

| Field | Content |
|---|---|
| `schema` | `"qnx6-evidence.v1"` |
| `status` | `"complete"` or `"failed"` |
| `truncated` | `true` when the depth cap (40 levels) was hit; `false` otherwise |
| `input.partition_offset` | Byte offset of the QNX6 partition within the image |
| `input.sha256` | SHA-256 hex digest of the full image file |
| `input.size_bytes` | Byte size of the full image file |
| `filesystem.block_size` | QNX6 block size in bytes (from superblock), or `null` on parse failure |
| `filesystem.filesystem_type` | `"QNX6 Power-Safe"` |
| `filesystem.num_blocks` | Total block count from superblock, or `null` on parse failure |
| `filesystem.num_inodes` | Total inode count from superblock, or `null` on parse failure |
| `entries` | Sorted list of filesystem entries (see Entry fields below) |
| `summary.dirs` | Count of directory entries in the walk |
| `summary.files` | Count of regular-file entries in the walk |
| `summary.total_entries` | Sum of dirs + files |
| `limitations` | Static disclaimer strings |
| `errors` | Parse-level or walk-level error strings; non-empty iff `status: failed` |

### Entry fields

| Field | Content |
|---|---|
| `mode` | Raw inode mode word (integer); use `mode & 0xF000` to classify: `0x4000` = directory, `0x8000` = regular file, `0xA000` = symbolic link |
| `path` | Absolute path within the filesystem (e.g. `/bin/sh`) |
| `size_bytes` | File or directory size in bytes from the inode |
| `type` | `"file"` or `"dir"` (symlink inodes report as `"file"` with mode `0xA000`) |

## Anti-Silent-Zero (§7 Compliance)

Three states are always distinguishable:

| State | Indicator |
|---|---|
| absent-input | Exit 2; no JSON file written; error on stderr |
| empty-input | `status: complete`; `total_entries: 0`; `entries: []`; exit 0 |
| parse-error | `status: failed`; `errors` list non-empty; exit 1 |

A `total_entries: 0` result proves the reader walked a valid QNX6 root
directory and found no entries.  It is never produced when the parse failed.

## Caps And Truncation

| Cap | Default |
|---|---|
| Maximum recursion depth | 40 levels |

When the depth cap fires, the `truncated` field in the JSON output is set to
`true`.  Entries at depths greater than
40 are not enumerated.  The cap protects against pathological or crafted
directory trees; normal QNX6 images do not reach this depth.

Cyclic directory references are also handled: each inode is descended at most
once (visited-inode set), preventing exponential memory growth on crafted
images.

## Non-Goals

- File content is never read or published in the `list` output.
- The `extract` subcommand writes a single named file; it does not create
  output directories or walk subtrees.
- No QNX6 filesystem writes are performed.
- Partition detection / partition table parsing is out of scope; the caller
  supplies `--partition-offset` explicitly.
- Power-Safe journal recovery is not performed; the reader uses the primary
  superblock at offset `0x2000` from the partition start.

## Output Layout

```
evidence.json      # key-sorted JSON (this schema)
```

The `list` subcommand writes a single JSON file to `--output`.  The output
path must not already exist (symlinks and pre-existing files are refused with
exit 2 via `O_CREAT|O_EXCL|O_NOFOLLOW`).  There is no output directory; the
path is the file itself.

## Invocation Examples

```bash
# List all entries from a raw image (partition starts at byte 0)
qnx6-read.sh list --input disk.img --output evidence.json

# List from a multi-partition image (supply the QNX6 partition offset)
qnx6-read.sh list --input disk.img --partition-offset <OFFSET_BYTES> --output evidence.json

# Extract a single file
qnx6-read.sh extract --input disk.img --fs-path /etc/passwd --output passwd.txt
```

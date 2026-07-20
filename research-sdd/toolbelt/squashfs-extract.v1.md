# squashfs-extract.v1

`squashfs-extract.sh --input <file> --output <new-out-dir> [caps]` safely
extracts a SquashFS filesystem into a private staging tree, validates the
tree before publication, and emits a deterministic evidence report.

## Accepted Input

Raw SquashFS blobs (header at offset 0) and firmware images containing an
embedded SquashFS (non-zero offset).  The input is scanned for the first valid
SquashFS v4 little-endian superblock: magic bytes `hsqs`, version 4.0,
valid compression identifier (1–6), power-of-two block size (4 KiB–1 MiB),
non-zero inode/ID counts, required table offsets within `bytes_used`, and
`bytes_used` wholly within the input.  An input without a valid superblock is
rejected with a clean error before any extraction is attempted.

## Extraction Sandbox

`unsquashfs` runs inside a minimal Bubblewrap sandbox:
  - Capabilities: all dropped (`--cap-drop ALL`)
  - Network: isolated (`--unshare-net`)
  - PID namespace: new (`--unshare-pid`)
  - Filesystem: only OS runtime dirs (`/usr`, `/bin`, `/lib`, …) bound
    read-only; the staging directory bound writable at `/work`; no home,
    /run, /etc credentials, or user data exposed
  - Signal: `--die-with-parent` ensures cleanup on parent exit

The wall-clock timeout (`--timeout-seconds`, default 120 s) kills the
process group on breach.  A background size watchdog polls the staging
extraction directory every ~250 ms; if aggregate on-disk bytes exceed
`--max-extracted-bytes`, the process group receives SIGKILL and extraction
fails closed — preventing disk exhaustion during extraction, before
post-extraction tree validation.  `RLIMIT_FSIZE` is retained as a per-file
defense-in-depth backup; if unavailable, a warning is emitted to stderr.

## Post-Extraction Tree Validation

After extraction, every entry in the tree is inspected with `O_NOFOLLOW`:
  - **Symlinks**: any symlink (including absolute-path or traversal) is
    **rejected** — the entire extraction fails closed.
  - **Special files** (devices, pipes, sockets): rejected.
  - **Hardlinks** (`st_nlink > 1`): rejected.
  - **Per-file sha256**: computed with O_NOFOLLOW + TOCTOU guard.
  - **Entry and byte caps**: `--max-entries` (default 10 000) and
    `--max-extracted-bytes` (default 256 MiB) — breach rejects without
    publication.  Truncation is never silent.

## Evidence and Publication

`squashfs-extract.v1.json` is canonical sorted JSON containing:
  - `schema`, `input` (path + size + sha256), `squashfs_offset`
  - `entries`: sorted list of `{path, type, mode, size?, sha256?}`
  - `entry_counts`, `total_extracted_bytes`, `caps`, `isolation`,
    `limitations`, `validation_verdict: "pass"`

The extracted files reside under `extracted/` inside the output directory,
alongside `squashfs-extract.v1.json`, `analysis-manifest.v1.json`,
`stdout.txt`, and `stderr.txt`.

All files and directories are synced, the tree is validated as a closed set
(no extras, no symlinks, mode 0400/0700, single-link regular files), and
published by Linux `renameat2(RENAME_NOREPLACE)` followed by parent-directory
sync.  Existing destinations are never replaced.  On any error, only owned
staging is removed; the destination is never partially published.

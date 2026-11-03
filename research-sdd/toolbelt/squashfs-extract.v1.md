# squashfs-extract.v1

`squashfs-extract.sh --input <file> --output <new-out-dir> [caps]` safely
extracts a SquashFS filesystem into a private staging tree, validates the
tree before publication, and emits a deterministic evidence report.

`squashfs-extract.sh` is a compatibility shim over `rsdd formats squashfs-extract`
(Go, kit issue #2417; the Python `squashfs_extract.py` is gone).  The shim hands every
argument to it unchanged and passes no manifest tool path (`--manifest-cli` is optional, accepted and
ignored: the manifest is created and verified in process, so `python3` is not needed); exit codes and stderr pass through unchanged (0 published, 2 any
refusal or failure).  The guard-to-test table is at the head of
`rsdd/internal/formats/squashfs_test.go`; the legacy script is kept as the
differential oracle under `rsdd/internal/formats/testdata/squashfs/legacy/`.

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
defense-in-depth backup, set by re-executing the binary as the rlimit helper
(`rsdd __exec`); a limit the kernel refuses fails the run ("unsquashfs failed")
instead of printing a warning and relying on the watchdog alone.

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

## Intended Differences From The Python Implementation

Behavior is held against the legacy script by `TestSquashfsParity*` (same
exit code, same stderr text, same published tree and evidence bytes, same
manifest apart from the fields below).  The differences are all stricter or
crash-free:

| Area | Python script | `rsdd formats squashfs-extract` |
|---|---|---|
| Symlink to a directory | `os.walk` filed it under `dirnames`, so `walk_tree` never saw it; the refusal came later from a `chmod` through the link (`Operation not permitted`, Python-version dependent) | refused where it first appears: `symlink in extracted tree (rejected): <path>` |
| Unlistable directory, missing `extracted/` | skipped silently (`os.walk` ignores errors): an incomplete tree could be published as complete | an error, nothing published |
| Pre-existing `.<name>.stage` | the failed `mkdir` was followed by `rmtree(stage)`, deleting another run's stage | the error `[Errno 17] File exists: ...`; a stage this run did not create is never deleted |
| FIFO as `--input` | blocks forever in `open` | `source is not a regular file` |
| Manifest `tool` / `argv` | launcher = python, artifact = `squashfs_extract.py`, argv `[python, script, ...]` | launcher = the rsdd binary, no script artifact, argv `[rsdd, formats, squashfs-extract, ...]`; every other manifest field is identical |
| Sandbox environment | the caller's environment | `PATH` only (the sandbox sets its own `PATH`, `HOME`, `TMPDIR` as before) |
| Manifest tool failure | Python `CalledProcessError` text | the tool's own stderr, then `squashfs-extract: manifest create failed (exit N)` (or `verify`) |
| Extracted name that is not valid UTF-8 | escaped as `\udcXX` in the JSON | refused: `extracted path is not valid UTF-8` |
| Usage errors | argparse text, exit 2 | Go flag text, exit 2; `-h` prints the usage to stdout and exits 0 |
| Cwd | process cwd | the injected working directory (identical for the real binary) |

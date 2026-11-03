# `zip-stored.v1`

`zip-stored.sh --input archive.zip --output new-directory [caps]` extracts only an
entire classic, single-disk ZIP made exclusively of descriptor-free, unencrypted
STORED regular files and consistent directories. It builds on the verified
`zip-metadata.v1` central-directory parser but independently authorizes every
local header and payload. Parsing is in-process as an unprivileged user, not a
hostile-parser boundary; use a disposable VM for actively hostile archives.

## Acceptance And Output

Central and local raw names, flags, method, needed version, DOS timestamps,
CRC32, and sizes must match. ZIP64 extras/sentinels, multi-disk records, data
descriptors, encryption, non-STORED methods, unequal STORED sizes, overlapping
entry ranges, payloads crossing the central directory, CRC failures, and
recovery inputs fail closed. Unix links/special modes and inconsistent DOS
directory attributes are rejected.

Names must be strictly decodable, NFC, relative POSIX paths with no backslash,
NUL/control byte, drive prefix, empty, dot, or traversal component. Duplicate,
file-directory, and ancestor conflicts are rejected before extraction. Caps for
input, metadata, entries, path bytes, depth, each entry, total extracted bytes,
and canonical report are positive and enforced incrementally.

The canonical `zip-stored.v1.json` records the stable complete-archive SHA-256,
caps, exact payload offsets, CRC32, sizes, and extracted-file SHA-256 values. A
verified `analysis-manifest.v1.json` binds the report, extracted files and
launcher (the `rsdd` binary) with truthful static-only, no-network, no-target-execution
claims. `stdout.txt` and `stderr.txt` are empty. The staged archive is removed.

The exact closed tree contains only those artifacts and declared output paths:
owned `0700` directories and owned, single-link `0400` regular files. Staging and
file creation are no-follow/exclusive and descriptor-relative. Outputs are synced,
then published with Linux `renameat2(RENAME_NOREPLACE)` and parent sync. Exit `0`
means durable success; exit `2` means no publication; exit `3` alone means rename
succeeded but parent sync failed, so the destination exists with uncertain durability.

## Non-Goals

There is no decompression, password/decryption support, partial mixed extraction,
restoration, recursion, mounting, content analysis, target execution, or network
access. ZIP64, spanning, damaged-archive recovery, and unknown methods are unsupported.

## Intended differences from the Python tool

The tool is now `rsdd formats zip-stored` (Go, kit issue #2416); `zip-stored.sh` is a compatibility shim. Outputs are
byte-identical to the former `zip_stored.py` for the report, the staged files and the modes; the legacy parser, frozen under `rsdd/internal/formats/testdata/zip/legacy/`, is the
oracle of the Go parity tests over every fixture and every single-byte corruption of them. The differences:

- Flags are parsed by Go's `flag` package: full flag names only (argparse accepted unambiguous prefixes), `-h`
  prints the usage on stderr and exits `0`, a bad value or an unknown flag is a usage error (exit `2`). The hidden
  `--manifest-cli` stays required; the Go command checks that the file exists (otherwise it fails as the
  interpreter did) and creates and verifies the manifest in process, so `python3` is not needed.
- `--metadata-parser` is gone: the Python tool checked that the parser module it was handed was the module it had
  imported, which has no meaning in one binary. Passing it is a usage error.
- Exit `3` prints `DEGRADED: zip-stored: published with uncertain durability: <reason>` (the `rsdd` contract
  requires the `DEGRADED:` prefix on exit `3`); the Python tool printed the same text without the prefix.
- The unreachable "file-directory path conflict" check of the Python `inspect` was not ported: the earlier
  "duplicate or ancestor path conflict" check always fires first for the same input.
- Integer caps are `int64`: a value beyond it (Python's unbounded `int`) is a usage error.
- The analysis manifest names the `rsdd` binary as `tool.executable` and `argv[0]` (argv is
  `rsdd formats zip-stored --input ... --output ...`) and carries no `tool.artifacts`: the script files no longer
  exist as separate artifacts, the launcher hash covers the code. `run.started_at` / `ended_at` come from the
  injected clock in the same `isoformat()` shape.
- Operating-system failures (open, mkdir, fsync) print Go's wording instead of Python's `[Errno N] ...`; the exit
  code is unchanged. Structural messages (`truncated EOCD`, `unsafe entry path`, ...) are unchanged.
- The output tree is created through `os.Root` (descriptor-relative, cannot leave the stage directory) instead of
  per-component `O_NOFOLLOW`; creation stays exclusive and the stage name is still never adopted.
- Unicode normalization and legacy code-page decoding use tables generated from Python's own `unicodedata` and
  `cp437` codec (`internal/formats/zipdata_gen.go`, regenerated by `testdata/zip/gen_tables.py`).

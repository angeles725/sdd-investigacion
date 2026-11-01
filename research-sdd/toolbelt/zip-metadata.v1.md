# `zip-metadata.v1`

`zip-metadata.sh --input archive.zip --output new-directory [caps]` inventories classic ZIP
central-directory metadata without reading local headers or entry payloads,
decompressing data, extracting files, or executing archive content.

## Trust Boundary And Accepted Input

The Go parser (`rsdd formats zip-metadata`) processes the untrusted archive in-process as the invoking unprivileged,
non-set-id user; it is not sandboxed or a hostile-parser security boundary. It performs no
network access. Use a disposable VM for actively hostile archives. The trusted local
manifest CLI runs only after the metadata report has been staged.

The accepted subset is a structurally consistent classic single-disk ZIP whose
central directory ends at the terminal EOCD. Empty archives, EOCD comments,
self-extracting prefixes, encrypted entries, unknown compression methods, and
non-ZIP64 extra fields are metadata-only inputs and are accepted. Entry names
use UTF-8 when general-purpose flag 11 is set and CP437 otherwise; undecodable
bytes are replaced while `name_raw_hex` preserves the original bytes.

ZIP64 sentinels, ZIP64 locator/extra records, multi-disk or spanned archives,
truncation, malformed extra fields, impossible offsets, and declared
central-directory size/count mismatches fail closed.

## Outputs And Determinism

The closed output tree contains `input/central-directory.bin`, empty
`stdout.txt` and `stderr.txt`, `zip-metadata.v1.json`, and a verified
`analysis-manifest.v1.json`. Directories are owned mode `0700`; regular files
are owned, single-link mode `0400`. The staged input is only the central
directory plus EOCD, so its manifest identity does not hash the complete ZIP.

`zip-metadata.v1.json` is canonical, key-sorted compact JSON with one trailing
newline. For the same resolved input path, stable metadata bytes, and caps, its
fields are deterministic:

| Object | Fields |
|---|---|
| top level | `schema`, `input`, ordered `entries`, `archive_prefix_bytes`, `central_directory_offset`, `central_directory_size`, `eocd_offset`, `eocd_comment_raw_hex`, `caps`, `payload_bytes_read`, `limitations` |
| `input` | resolved `path`, archive `size`, SHA-256 of the staged central-directory-plus-EOCD bytes |
| each entry | `index`, decoded `name`, `name_encoding`, `name_raw_hex`, `method`, `flags`, `encrypted`, declared `crc32`, compressed/uncompressed sizes, internal/external attributes, versions, DOS date/time, derived `timestamp`, and declared local-header offset |
| `safety` | `absolute`, `traversal`, `backslash`, `nul`, `duplicate` |

Danger markers report metadata; they never authorize extraction. `absolute`
marks leading slash/backslash or drive-root syntax, `traversal` marks a `..`
component split on either separator, `backslash` and `nul` inspect raw name
bytes, and `duplicate` marks repeated decoded names.

The analysis manifest records a complete, static, no-network, no-target-execution
run and binds the report and staged metadata. Its run timestamps vary between
runs; do not treat the complete output directory as byte-reproducible.

## Caps, Stability, And Publication

All caps must be positive. Defaults are 1 GiB input, 16 MiB central directory,
10,000 entries, 65,536 bytes per name/extra/comment field, and 16 MiB canonical
report. A descriptor-opened regular non-symlink input must retain device, inode,
mode, size, mtime, and ctime throughout metadata reads. `payload_bytes_read` is
always `0`: local headers and entry payload ranges are never read or validated.

The output must be a new path below an existing owned, non-group/world-writable
directory on an allowlisted Linux-private filesystem, with no symlinked parent
component. Owned staging is synced and validated before Linux
`renameat2(RENAME_NOREPLACE)` publication, then the parent is synced. Existing
destinations and colliding stage paths are never adopted, removed, or replaced.

Success exits `0` without console output. Invalid arguments, rejected input,
cap/stability/path violations, manifest failure, and publication failure exit
`2`; handled failures print `zip-metadata: <reason>` to stderr. Failures before
rename publish nothing. If rename succeeds but parent sync fails, exit `2` may
coexist with the new destination and uncertain durability; retry is no-replace.

## Non-Goals

ZIP64, multi-disk/spanned ZIPs, damaged-archive recovery, passwords or
decryption, payload CRC validation, and STORED or compressed payload extraction
are unsupported. Declared CRCs, sizes, methods, flags, and local-header offsets
are inventory data, not payload-integrity or extractability claims.

## Intended differences from the Python tool

The tool is now `rsdd formats zip-metadata` (Go, kit issue #2416); `zip-metadata.sh` is a compatibility shim. Outputs are
byte-identical to the former `zip_metadata.py` for the report, the staged files and the modes; the legacy parser is the
oracle of the Go parity tests over every fixture and every single-byte corruption of them. The differences:

- Flags are parsed by Go's `flag` package: full flag names only (argparse accepted unambiguous prefixes), `-h`
  prints the usage on stderr and exits `0`, a bad value or an unknown flag is a usage error (exit `2`). The hidden
  `--manifest-cli` stays required; the Go command runs it with `python3` from `PATH` and a 10-minute bound, and
  relays its output when it ends.
- A `/proc/self/mountinfo` line with an empty right side is an error (exit `2`); the Python tool died with a
  traceback there (exit `1`). A line without ` - ` or with fewer than five left fields is skipped, as before.
- Integer caps are `int64`: a value beyond it (Python's unbounded `int`) is a usage error.
- The analysis manifest names the `rsdd` binary as `tool.executable` and `argv[0]` (argv is
  `rsdd formats zip-metadata --input ... --output ...`) and carries no `tool.artifacts`: the script files no longer
  exist as separate artifacts, the launcher hash covers the code. `run.started_at` / `ended_at` come from the
  injected clock in the same `isoformat()` shape.
- Operating-system failures (open, mkdir, fsync) print Go's wording instead of Python's `[Errno N] ...`; the exit
  code is unchanged. Structural messages (`truncated EOCD`, `unsafe entry path`, ...) are unchanged.
- The output tree is created through `os.Root` (descriptor-relative, cannot leave the stage directory) instead of
  per-component `O_NOFOLLOW`; creation stays exclusive and the stage name is still never adopted.
- Unicode normalization and legacy code-page decoding use tables generated from Python's own `unicodedata` and
  `cp437` codec (`internal/formats/zipdata_gen.go`, regenerated by `testdata/zip/gen_tables.py`).

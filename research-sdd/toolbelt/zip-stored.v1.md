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
verified `analysis-manifest.v1.json` binds the report, extracted files, launcher,
and both parser modules with truthful static-only, no-network, no-target-execution
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

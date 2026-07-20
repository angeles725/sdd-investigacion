# firmware-carve.v1

`scan-firmware.sh carve <file> <new-out-dir> [caps]` performs deterministic,
static byte carving. It never decompresses, extracts archives or filesystems,
recurses into a carve, mounts data, invokes a content analyzer, or executes the
input or carved payload.

## Accepted ranges

- U-Boot legacy uImage: the 64-byte big-endian header magic is present, the
  header CRC-32 validates with its CRC field zeroed, the declared payload is
  wholly inside the input, and the payload CRC-32 validates. The exact header
  plus declared payload is copied.
- SquashFS v4 little-endian: the 96-byte superblock is present; version,
  compression identifier, block size/log, counts, `bytes_used`, required table
  offsets, optional table sentinels, and input bounds are structurally valid.
  The exact `bytes_used` range is copied. Filesystem contents are not parsed or
  validated.

Candidates are sorted by input offset, kind, and end offset. Outputs are named
`carves/<eight-hex-offset>-<kind>.bin`; overlaps are not interpreted or
recursed. No candidate is a fail-closed error.

## Safety And Bounds

The caller must be an unprivileged, non-set-id user. Input is opened by
descriptor with no final symlink following, must be regular, is copied once,
and must remain stable. The destination must be absent, canonical, on an
allowlisted Linux-private filesystem, and beneath an owned non-writable
existing directory. A colliding staging path is never adopted or removed.

Positive caps are enforced during traversal for input bytes, carved bytes,
candidates, published files, worker address space, processes, and wall time. Any cap or validation failure removes
only owned staging and publishes nothing. The closed output tree contains only
mode `0700` directories and owned mode `0400` regular files; links, devices,
foreign ownership, extra files, and mode drift fail before publication.

The parser runs as the same script inside authenticated, root-owned,
non-writable Bubblewrap with a read-only host, writable staging only, synthetic
state, no network namespace, new PID/session namespaces, and all capabilities
dropped. The bounded process tree is killed on timeout or process-cap breach.
Bubblewrap is defense in depth, not a VM security boundary; use a disposable VM
for actively hostile firmware.

## Manifest And Publication

`firmware-carve.v1.json` is canonical sorted JSON with stable input identity,
ordered carve offsets/ranges/digests, all effective caps, Bubblewrap identity,
isolation claims, and limitations. It contains no timestamps or random values.
Files and directories are synced, validated as a closed tree, and published by
Linux `renameat2(RENAME_NOREPLACE)` followed by parent-directory sync. Existing
destinations are never replaced.
If rename succeeds but parent sync fails, exit `3` truthfully reports the
existing destination with uncertain durability; retry remains no-replace.

Legacy `extract` always exits `2` with migration guidance. Unsafe Binwalk
extraction and root fallback behavior are no longer reachable.

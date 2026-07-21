# `pcap-evidence.v1`

`corroborate-pcap.sh --input capture.pcap --output new-directory [caps]`
produces offline, read-only evidence from a `.pcap` or `.pcapng` file.
No live capture, traffic replay, or network access occurs.

## Trust Boundary And Accepted Input

The adapter stages the capture file read-only and runs `capinfos` and `tshark`
inside a network-denied Bubblewrap sandbox (`--unshare-net --cap-drop ALL`).
Neither tool executes the captured traffic or contacts external hosts.

Accepted input: any regular non-symlink `.pcap` or `.pcapng` file whose first
four bytes match a known libpcap magic value (`0xa1b2c3d4`, `0xd4c3b2a1`,
`0x4d3cb2a1`, `0xa1b23c4d`) or the pcapng block-type sentinel
(`0x0a0d0d0a`). Non-pcap files fail closed before any tool is invoked.

## Tool Invocations

| Tool | Command | Purpose |
|---|---|---|
| `capinfos` | `capinfos input/capture.pcap` | File summary (packet count, duration, encapsulation, sizes) |
| `tshark` | `tshark -q -z io,phs -r input/capture.pcap` | Protocol hierarchy statistics |

Both commands run inside the Bubblewrap sandbox with a read-only bind of the
staged capture file.  The environment is minimal: `HOME`, `LANG`, `LC_ALL`,
`PATH=/usr/bin:/usr/sbin:/bin:/sbin`, `TMPDIR`, `TZ=UTC`, and `XDG_*` dirs.

## Evidence Schema (`pcap-evidence.v1.json`)

| Field | Content |
|---|---|
| `schema` | `"pcap-evidence.v1"` |
| `status` | `"complete"` or `"failed"` |
| `input.source` | Source path, byte size, SHA-256 |
| `input.staged` | Staged logical path, byte size, SHA-256 |
| `isolation.launcher` | bwrap path, size, SHA-256 |
| `isolation.profile` | `bubblewrap-pcap-offline`, network/static/execution flags |
| `capinfos.argv` | Full bwrap-prefixed capinfos command |
| `capinfos.tool` | capinfos path, size, SHA-256 |
| `capinfos.summary` | `packet_count`, `capture_duration_s`, `file_size_bytes`, `data_size_bytes`, `encapsulation` |
| `protocol_hierarchy.argv` | Full bwrap-prefixed tshark command |
| `protocol_hierarchy.tool` | tshark path, size, SHA-256 |
| `protocol_hierarchy.protocols` | Sorted list of `{level, protocol, frames, bytes}` |
| `limitations` | Static disclaimer list |
| `errors` | Tool error codes, timeouts, output-cap events |

## Determinism

For the same input file and tool binaries, `pcap-evidence.v1.json` is
byte-reproducible.  Timestamps (`started_at`, `ended_at`, `duration_ms`)
are only recorded inside the `analysis-manifest.v1.json` and are excluded
from the manifest identity hash per the manifest contract.

## Output Layout

```
output-dir/
  pcap-evidence.v1.json      # canonical evidence (key-sorted JSON)
  engine/
    analysis-manifest.v1.json
    stdout.txt               # tshark -z io,phs output
    stderr.txt               # tshark stderr
  input/
    capture.pcap             # staged copy (mode 0400)
```

## Caps And Publication

Default caps: 30 s timeout, 1 MiB combined output.  The output must be a new
path below an existing owned directory on an allowlisted Linux-private
filesystem.  Publication uses `renameat2 RENAME_NOREPLACE` (atomic,
no-replace).  Failures before rename publish nothing and clean the stage.

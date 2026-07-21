# `pcap-flows.v1`

`pcap-flows.sh --input capture.pcap --output new-directory [--max-streams N] [caps]`
reconstructs transport-layer flows offline from a `.pcap` or `.pcapng` file.
No live capture, traffic replay, or network access occurs.

## Trust Boundary And Accepted Input

Stages the capture file read-only, runs `tshark` inside a network-denied
Bubblewrap sandbox (`--unshare-net --cap-drop ALL`).  Accepted input: any
regular non-symlink file whose first four bytes match a known libpcap magic
value or the pcapng block-type sentinel (`0x0a0d0d0a`).

## Relationship To `pcap-evidence.v1`

Additive to `corroborate-pcap.sh`.  That adapter provides capinfos summary
and protocol hierarchy; this adapter adds conversation enumeration and
per-stream payload digests.

## Tool Invocations (all inside Bubblewrap)

| Run | Command | Purpose |
|---|---|---|
| Fields | `tshark -T fields -e tcp.stream -r input/capture.pcap` | Unique TCP stream indices |
| Follow N | `tshark -q -z follow,tcp,raw,N -r input/capture.pcap` | Reassemble stream N payload |
| Conv (primary/manifested) | `tshark -q -z conv,tcp -z conv,udp -r input/capture.pcap` | TCP+UDP conversation stats |

## Evidence Schema (`pcap-flows.v1.json`)

| Field | Content |
|---|---|
| `schema` | `"pcap-flows.v1"` |
| `status` | `"complete"` or `"failed"` |
| `conversations.argv` | Full bwrap-prefixed tshark conv command |
| `conversations.tcp` | Sorted list of `{endpoint_a, endpoint_b, frames_b2a, bytes_b2a, frames_a2b, bytes_a2b, frames_total, bytes_total}`. Endpoints are canonicalized smallest-first; directional counts follow the endpoint swap so `a2b` always means traffic from `endpoint_a` toward `endpoint_b`. |
| `conversations.udp` | Same structure for UDP conversations |
| `conversations.tool` | tshark executable path, byte-size, and SHA-256 digest |
| `tcp_stream_follows` | List of `{stream_index, client, server, payload_sha256, payload_bytes, client_bytes, server_bytes, payload_complete}`. `payload_complete: false` when any hex-decode failure occurred during reassembly — the SHA-256 digest then covers only the bytes that decoded successfully. |
| `stream_count_total` | Total distinct TCP stream indices found in the capture |
| `streams_analyzed` | Number of streams for which follow output was collected (≤ `stream_count_total`) |
| `streams_truncated` | `true` when `stream_count_total` exceeded `--max-streams`; truncation is always visible here and in stderr |
| `isolation.launcher` | bwrap path, size, SHA-256 |
| `errors` | Tool error codes, timeouts, output-cap events |

## Payload Digest Policy

Per-stream reassembled payloads are stored as SHA-256 digests **only** —
raw bytes are never written to the evidence directory.

## Determinism And Output Layout

`pcap-flows.v1.json` is byte-reproducible for the same input and binaries.
`LC_ALL=C.UTF-8` and `TZ=UTC` are pinned in the sandbox environment.

```
output-dir/
  pcap-flows.v1.json         # canonical evidence (key-sorted JSON)
  engine/
    analysis-manifest.v1.json
    stdout.txt  stderr.txt   # from the primary conv run
  input/capture.pcap         # staged copy (mode 0400)
```

Default caps: 30 s timeout, 1 MiB output per run, 128 stream-follow passes
(`--max-streams`).  If `stream_count_total` exceeds the cap the analysis is
bounded, `streams_truncated: true` is recorded in the evidence, and a
warning is emitted to stderr — no silent truncation occurs.  Publication uses
`renameat2 RENAME_NOREPLACE` (atomic, no-replace).

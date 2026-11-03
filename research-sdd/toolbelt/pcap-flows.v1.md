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

## Intended differences from the Python tool

The tool is now `rsdd corroborate pcap-flows` (Go, kit issue #2485); `pcap-flows.sh` is a compatibility shim. Outputs are
byte-identical to the former `pcap_flows.py` for the evidence, the staged files, the file modes, the exit codes and the
messages, over about a hundred scenarios compared against the frozen legacy script as the oracle
(`internal/corroborate/pcap`, `go test`). The differences:

- The command-line parser reproduces argparse (the program name stays `pcap_flows.py` in usage lines, unambiguous prefixes
  of long options work, `--name=value`, `-h` prints the help on stdout and exits `0`, every error prints the usage
  block and `pcap_flows.py: error: ...` on stderr and exits `2`), so a command line means what it meant.
- The caps are arbitrary-size integers; a value beyond what the OS accepts is clamped, never an error.
- A manifest-tool failure (for example an empty `tshark -v` banner) prints the tool's own line and
  `pcap-flows: manifest-cli 'create' failed (exit 2)` and exits `2`; the Python script died with a traceback and exit `1`
  there, because `ManifestError` subclassed a second copy of `AdapterError` that its handler did not catch.
- A stage directory that already exists (another run in flight, or a leftover) is never deleted by the run that
  failed to create it; the script's cleanup removed it. The run exits `2` with `[Errno 17] File exists: '<stage>'`.
- A FIFO or device as the capture is refused ("not a pcap/pcapng file ...") instead of blocking on open.
- Numbers read from `capinfos` and `tshark` use ASCII digits only; the script also took other Unicode decimal digits
  and crashed on digit-like characters `int()` refuses. A `capinfos` duration of `nan` or `inf` is refused (no JSON
  form) where the script wrote `NaN` / `Infinity`.
- The analyzers' output reaches the runner through pipes, not files: a run stopped at the output cap ends on SIGTERM
  where the script's file-fed run ended on SIGXFSZ, so the manifest's `run.exit_code` / `run.signal` differ in that
  one case. The captured bytes, the truncation and the `output-cap` error are the same.
- Output that is not valid UTF-8 is decoded with one U+FFFD per ill-formed sequence (the `tshark -v` banner included,
  where the script crashed).
- The analysis manifest is created, validated and verified in process by `rsdd` (kit issue #2561): `python3` is no
  longer required, and `--manifest-cli` is accepted and ignored.

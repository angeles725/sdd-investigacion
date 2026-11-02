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

## Intended differences from the Python tool

The tool is now `rsdd corroborate pcap` (Go, kit issue #2485); `corroborate-pcap.sh` is a compatibility shim. Outputs are
byte-identical to the former `corroborate_pcap.py` for the evidence, the staged files, the file modes, the exit codes and the
messages, over about a hundred scenarios compared against the frozen legacy script as the oracle
(`internal/corroborate/pcap`, `go test`). The differences:

- The command-line parser reproduces argparse (the program name stays `corroborate_pcap.py` in usage lines, unambiguous prefixes
  of long options work, `--name=value`, `-h` prints the help on stdout and exits `0`, every error prints the usage
  block and `corroborate_pcap.py: error: ...` on stderr and exits `2`), so a command line means what it meant.
- The caps are arbitrary-size integers; a value beyond what the OS accepts is clamped, never an error.
- A manifest-tool failure (for example an empty `tshark -v` banner) prints the tool's own line and
  `corroborate-pcap: manifest-cli 'create' failed (exit 2)` and exits `2`; the Python script died with a traceback and exit `1`
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
- The analysis manifest is still created, validated and verified by `analysis_manifest.py`, run with `python3` from
  `PATH`; its stdout and stderr are relayed.

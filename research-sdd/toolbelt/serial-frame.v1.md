# `serial-frame.v1`

Shared evidence schema for two complementary serial-protocol wrappers:

- **`serial-frame-analyze.sh`** — FILE-ARTIFACT tool: reads a text log of
  previously captured serial frames and emits statistical analysis.
- **`serial-frame-capture.sh`** — HARDWARE PROBE tool: samples a live serial
  port and emits captured frames (requires `--allow-live-probe` after the
  subcommand; offline plan without it).

Uses only Python stdlib; no external tools required for `serial-frame-analyze`.
`serial-frame-capture` additionally requires `pyserial` for live probing; the
plan-only path works without it.

## Canonical Text Log Format

Frames are exchanged between the two wrappers via a plain-text log.  Each
non-comment line encodes one frame:

```
{t_rel_s:.6f}  len={N}  {HH HH ...}
```

- `t_rel_s` — relative timestamp in seconds from start of capture (6 decimal
  places, e.g. `0.000123`)
- `len={N}` — declared byte count; `N` must equal the number of hex pairs
- `{HH HH ...}` — space-separated lowercase hex pairs, one per byte

Lines starting with `#` and blank lines are ignored by the parser.

`serial-frame-capture` emits this format via `--log <path>`.
`serial-frame-analyze` parses it as its primary input.

## `serial-frame-analyze.sh`

```
serial-frame-analyze.sh stats     --input <frames.log> --output <new.json>
serial-frame-analyze.sh diff      --input-a <a.log> --input-b <b.log> --output <new.json>
serial-frame-analyze.sh checksum  --input <frames.log> --output <new.json>
```

Reads a plain-text frame log, parses lines matching the canonical format above.

Emits a key-sorted JSON evidence envelope.  Read-only: never modifies the input
file.  Output must not already exist (refused via `O_CREAT|O_EXCL|O_NOFOLLOW`).

## `serial-frame-capture.sh`

```
serial-frame-capture.sh sweep   --port <dev> [--seconds N] --output <new.json>
                                 [--allow-live-probe]
serial-frame-capture.sh capture --port <dev> --baud <rate> [--seconds N]
                                 [--gap-ms MS] --output <new.json>
                                 [--log <txt>] [--allow-live-probe]
```

**Flag position:** `--allow-live-probe` is registered on each subcommand, so
it must appear AFTER the subcommand name (e.g. `capture --allow-live-probe`).

**Guard:** without `--allow-live-probe` the wrapper exits 3 and writes an
offline plan only — no serial port is opened and no bytes are read.

**Text log:** `capture --log <txt>` writes the captured frames to a plain-text
file in the canonical format above, **only when at least one frame is captured**.
When `status: no-data` (zero frames), the log file is not created.
The log is suitable as direct input to `serial-frame-analyze`.  This output is
separate from the JSON evidence file.

## Trust Boundary And Accepted Input

### `serial-frame-analyze`

Any regular, non-symlink file containing serial frame captures in the canonical
text-log format.

- **Symlink input**: rejected via `O_NOFOLLOW`; exit 2, no JSON emitted.
- **Absent or unreadable file**: exit 2, no JSON emitted.
- **Empty log (no frame lines)**: `status: complete`; exit 0;
  `frame_count: 0` — proves the tool opened and scanned the file; never
  returned when the open failed.
- **Valid log with frames**: `status: complete`; exit 0; results populated.
- **Malformed input** (all frame-like lines fail len=N validation or hex
  parsing; zero valid frames): `status: failed`; exit 1; JSON emitted with
  `errors` list populated.
- **Output path already exists or is a symlink**: exit 2, no JSON emitted;
  original file not modified.

### `serial-frame-capture`

A live serial port device.

- **Without `--allow-live-probe`**: exit 3; plan-only JSON written;
  no serial port opened; no bytes read.
- **Capture with `--allow-live-probe`, port fails to open**: exit 2; error on
  stderr; no JSON.  (MINOR-4: single-port open failure is capture-only; for
  sweep, per-baud open failures are caught and reported in the JSON → exit 1.)
- **Sweep with `--allow-live-probe`, all baud opens fail or yield zero bytes**:
  exit 1; `status: failed`; JSON emitted with per-baud `error` fields.
- **Capture with `--allow-live-probe`, port opened but no frames received**:
  exit 1; `status: no-data`; JSON emitted.
- **With `--allow-live-probe`, capture or sweep succeeds**: exit 0;
  `status: complete`; frames or baud data populated.

## Exit Codes

### `serial-frame-analyze` subcommands (`stats`, `diff`, `checksum`)

| Code | Meaning |
|---|---|
| 0 | Complete — analysis finished; `status: complete` JSON written |
| 1 | Parse error — malformed input (no valid frames); `status: failed` JSON written |
| 2 | I/O error — absent/symlink input, or output path conflict; no JSON |

### `serial-frame-capture` subcommands (`sweep`, `capture`)

| Code | Meaning |
|---|---|
| 0 | Complete — live probe ran; frames captured or baud data collected; `status: complete` |
| 1 | No data / all failed — sweep: all baud opens failed or returned zero bytes; `status: failed`. Capture: port opened but zero frames received; `status: no-data`. |
| 2 | Operational error — capture port fails to open, import error, or I/O failure; no JSON or error JSON |
| 3 | Plan-only — `--allow-live-probe` not supplied; plan JSON written; `status: plan-only` |

## Evidence Schema (`serial-frame.v1`)

### Common fields (all tools and modes)

| Field | Content |
|---|---|
| `schema` | `"serial-frame.v1"` |
| `tool` | `"serial-frame-analyze"` or `"serial-frame-capture"` |
| `mode` | Subcommand name: `"stats"`, `"diff"`, `"checksum"`, `"sweep"`, `"capture"` |
| `status` | `"complete"`, `"failed"`, `"plan-only"`, or `"no-data"` |
| `errors` | List of parse-error strings; always present when `status: failed`; also present in `status: complete` output when some lines were skipped (mixed input) |

### `serial-frame-analyze` — `stats` mode

| Field | Content |
|---|---|
| `input.path` | Path of the input log file (as provided) |
| `input.sha256` | SHA-256 hex digest of the input file (64 hex chars) |
| `input.frame_count` | Number of frames parsed from the log |
| `summary.frame_count` | Number of frames parsed (same as `input.frame_count`) |
| `summary.distinct_lengths` | Number of distinct frame byte-lengths seen |
| `summary.truncated` | `true` when the 10 000-frame or 10 MB read cap was reached |
| `truncated` | Same as `summary.truncated` (top-level alias) |
| `results.length_histogram` | List of `{length, count}` objects, sorted by count descending |
| `results.most_common_length` | Integer byte-length of the most frequent frame type; `null` if empty |
| `results.variability` | Per-position variability for the most common frame length (see below) |

#### Variability entry fields

| Field | Content |
|---|---|
| `position` | Zero-based byte offset within the frame |
| `is_constant` | `true` when every frame of this length has the same byte value at this position |
| `distinct_count` | Count of distinct byte values seen at this position |
| `sample_hex` | Up to 6 distinct observed values as lowercase 2-char hex strings |

### `serial-frame-analyze` — `diff` mode

| Field | Content |
|---|---|
| `input_a.path` | Path of the first log file |
| `input_a.sha256` | SHA-256 hex digest of input A |
| `input_a.frame_count` | Frame count in log A |
| `input_a.truncated` | `true` if log A was truncated |
| `input_b.path` | Path of the second log file |
| `input_b.sha256` | SHA-256 hex digest of input B |
| `input_b.frame_count` | Frame count in log B |
| `input_b.truncated` | `true` if log B was truncated |
| `summary.frame_count_a` | Frame count in log A |
| `summary.frame_count_b` | Frame count in log B |
| `summary.shared_type_count` | Number of frame types present in both logs |
| `results.shared_types` | List of frame types present in both logs (see below) |

#### Shared-type entry fields

| Field | Content |
|---|---|
| `length` | Frame byte-length |
| `first_byte_hex` | First byte as lowercase 2-char hex (used as secondary key) |
| `changed_positions` | List of zero-based byte offsets that differ between A and B |

### `serial-frame-analyze` — `checksum` mode

| Field | Content |
|---|---|
| `input.path` | Path of the input log file |
| `input.sha256` | SHA-256 hex digest |
| `input.frame_count` | Total frames loaded |
| `input.useful_frame_count` | Frames with length ≥ 3 (tested against 2-byte algorithms) |
| `summary.frame_count` | Total frames loaded |
| `summary.useful_frame_count` | Frames tested |
| `summary.distinct_lengths` | Distinct frame byte-lengths |
| `summary.truncated` | `true` when a read cap was hit |
| `truncated` | Same as `summary.truncated` (top-level alias) |
| `results.algorithms` | List of algorithm result objects (see below) |

#### Algorithm result fields

| Field | Content |
|---|---|
| `name` | Algorithm name: `"sum8"`, `"twos-comp8"`, `"xor8"`, `"crc16-modbus"`, `"crc16-ccitt"` |
| `candidate` | `true` when the algorithm validated across all tested frames of the given length |
| `hit_count` | Number of frames where the algorithm matched |
| `hit_rate` | `hit_count / total_frames` (4 decimal places) |
| `total_frames` | Total frames tested by this algorithm |
| `skip_first` | Number of leading bytes skipped before the checksum body (0 or 1) |
| `little_endian` | `true` for LE two-byte algorithms, `false` for BE; absent for one-byte algorithms |

### `serial-frame-capture` — plan-only output (exit 3)

| Field | Content |
|---|---|
| `status` | `"plan-only"` |
| `mode` | `"sweep"` or `"capture"` |
| `guard` | Human-readable explanation that `--allow-live-probe` is required |
| `plan.port` | Serial port device path as provided |
| `plan.note` | Note describing what the probe would do |

Additional fields for `sweep` plan:

| Field | Content |
|---|---|
| `plan.baud_rates` | List of baud rates that would be attempted |
| `plan.seconds_per_baud` | Listen window per baud rate in seconds |

Additional fields for `capture` plan:

| Field | Content |
|---|---|
| `plan.baud` | Baud rate that would be used |
| `plan.seconds` | Capture duration in seconds |
| `plan.gap_ms` | Idle-gap threshold in ms |

### `serial-frame-capture` — `sweep` live output (exit 0 or 1)

| Field | Content |
|---|---|
| `status` | `"complete"` (any baud yielded data) or `"failed"` (all bauds failed or returned zero bytes) |
| `mode` | `"sweep"` |
| `results.baud_rates` | List of per-baud result objects (see below) |
| `results.best_candidate` | Baud rate of the most likely framed result, or `null` |
| `summary.baud_count` | Number of baud rates attempted |
| `summary.likely_framed_count` | Number of baud rates that produced likely-framed traffic |

#### Per-baud result fields (sweep)

| Field | Content |
|---|---|
| `baud` | Baud rate tested |
| `byte_count` | Bytes received (absent on open failure) |
| `entropy` | Shannon entropy of received bytes (absent on open failure) |
| `likely_framed` | `true` when entropy is low and sufficient bytes were received |
| `sample_hex` | First 24 bytes as hex string (absent on open failure) |
| `unique_byte_values` | Count of distinct byte values (absent on open failure) |
| `error` | Error string from `SerialException` (present only on open failure) |

### `serial-frame-capture` — `capture` live output (exit 0 or 1)

| Field | Content |
|---|---|
| `status` | `"complete"` (frames received) or `"no-data"` (port opened, no frames) |
| `mode` | `"capture"` |
| `input.port` | Serial port device path |
| `input.baud` | Baud rate used |
| `input.seconds` | Capture duration in seconds |
| `input.gap_ms` | Idle-gap threshold in ms |
| `summary.frame_count` | Number of frames captured |
| `summary.distinct_lengths` | Distinct frame byte-lengths |
| `summary.truncated` | `true` when the 1 000-frame cap was reached |
| `truncated` | Same as `summary.truncated` (top-level alias) |
| `frames` | List of frame objects (see below) |

#### Frame object fields (capture)

| Field | Content |
|---|---|
| `hex` | Frame bytes as a lowercase hex string (no spaces) |
| `length` | Frame byte count |
| `t_rel_s` | Relative timestamp in seconds from capture start (6 decimal places) |

## Three-State Honesty (§7 Compliance)

### `serial-frame-analyze`

Three states are always distinguishable:

| State | Indicator |
|---|---|
| absent-input | Exit 2; no JSON written; error on stderr |
| empty-input | `status: complete`; `frame_count: 0`; exit 0 |
| malformed-input | `status: failed`; `errors` list non-empty; exit 1 |

A `frame_count: 0` with `status: complete` proves the tool opened and scanned
the log and found no frame lines.  It is never produced when the open failed.

A `status: failed` with `errors` non-empty proves the tool found frame-like
lines but none passed validation (len=N mismatch or bad hex).

### `serial-frame-capture`

| State | Indicator |
|---|---|
| plan-only (guard not lifted) | Exit 3; `status: plan-only`; no port opened |
| all-fail (sweep) | Exit 1; `status: failed`; all baud opens failed or returned zero bytes |
| no-data (capture) | Exit 1; `status: no-data`; port opened but zero frames received |
| operational error | Exit 2; error on stderr; no JSON |
| complete | Exit 0; `status: complete`; data collected |

## Caps And Truncation

| Cap | Tool | Value |
|---|---|---|
| Maximum read per file | `serial-frame-analyze` | 10 MB |
| Maximum frames parsed | `serial-frame-analyze` | 10 000 |
| Maximum frames captured | `serial-frame-capture` | 1 001 (off-by-one: `_MAX_FRAMES=1000` with post-append `>=` check; `truncated: true` is set) |
| Read buffer per baud sweep | `serial-frame-capture` | 64 KB |
| Read chunk size (capture) | `serial-frame-capture` | 256 bytes |

When the frame cap fires, `truncated: true` is set in the output.  This is
never silently hidden — a capped result is always distinguishable from a
complete one.

## Non-Goals

- `serial-frame-analyze` never writes to the input log file.
- `serial-frame-capture` is read-only: it only reads bytes from the serial
  port; it never writes to it.
- Protocol decoding (application-layer semantics) is out of scope; the tools
  work at the raw-byte/frame level.
- Device-specific knowledge (register maps, protocol state machines) is not
  embedded; findings require human interpretation.

## Output Layout

```
evidence.json      # key-sorted JSON evidence (this schema)
frames.log         # optional text log (capture --log only; canonical format above)
```

Both wrappers write a single JSON file to `--output`.  `serial-frame-capture`
additionally writes an optional text log to `--log` (capture mode only).
Output paths must not already exist (refused via `O_CREAT|O_EXCL|O_NOFOLLOW`).

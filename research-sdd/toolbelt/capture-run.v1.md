# Live capture receipt `capture-run.v1`

`capture_plan.py --allow-live-capture` → `lib/capture_exec.py` (C1).
Spawns dumpcap (Wireshark's privilege-separated capture engine) into a per-run
subdir under `/tmp/rsdd`. Requires `RSDD_CAPTURE_IFACES` (comma-list) to be set;
requires `CAP_NET_RAW` on the dumpcap binary (`setcap cap_net_raw+ep`) or root.

## CLI

```
python3 capture_plan.py plan \
    --interface IFACE           # must be in RSDD_CAPTURE_IFACES allowlist
    --output   DIR
    [--bpf-filter EXPR]
    [--snaplen N]
    [--duration-seconds N]
    [--packet-count N]
    --allow-live-capture        # authorize live capture
```

Env: `RSDD_CAPTURE_IFACES=eth0,lo` — comma-separated allowlist (required).

## `capture-run.v1` schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"capture-run.v1"` | Schema identifier |
| `executed` | `true` | Always true for live receipts |
| `outcome` | `"success"` \| `"timeout-partial"` | `timeout-partial` when client wall deadline fired (SIGTERM); dumpcap flushes a valid partial pcap — this is expected, not an error |
| `exec_argv` | `list[str]` | Actual dumpcap argv executed (with -w rewrite + filesize cap) |
| `argv_deltas` | `list[{transform, …}]` | Two transforms: `output-path` (-w rewrite) and `add-filesize-cap` (-a filesize:N) |
| `pcap_path` | `str` | Absolute path to produced pcap in per-run subdir |
| `exit_code` | `int` | dumpcap exit code (-1 on SIGKILL) |
| `duration_s` | `float` | Elapsed wall seconds |
| `stdout` / `stderr` | `str` | Captured output (capped at ~1 MiB each) |
| `stdout_truncated` / `stderr_truncated` | `bool` | True when output exceeded cap |
| `output_files` | `list[{path, size, sha256}]` | Files in per-run subdir (best-effort); includes analysis JSONs when analyzers succeed |
| `analysis` | `object` | Offline pcap corroboration handoff (C2); always present on live-capture runs |

### `analysis` object

| Field | Type | Description |
|---|---|---|
| `attempted` | `bool` | `false` when pcap is missing or 0 bytes; no child processes spawned |
| `skipped_reason` | `str` \| `null` | `"missing-or-empty-pcap"` when `attempted=false`; `null` otherwise |
| `analyzers` | `list` | Present only when `attempted=true`; one entry per analyzer (see below) |

### `analysis.analyzers[*]` entry

| Field | Type | Description |
|---|---|---|
| `name` | `str` | `"corroborate_pcap"` or `"pcap_flows"` |
| `argv` | `list[str]` | Exact argv of the child process (proves exec-of-file, not in-process import) |
| `exit_code` | `int` | Child exit code; `-1` on spawn failure |
| `timed_out` | `bool` | `true` when outer wall (`RSDD_PCAP_ANALYZER_TIMEOUT_S`, default 300 s) fired; child was SIGTERM→SIGKILL'd |
| `output_json` | `str` \| `null` | Absolute path to the output JSON when it exists; `null` otherwise |
| `output_present` | `bool` | Whether the output JSON file was written |
| `stderr_tail` | `str` | Last 500 bytes of child stderr, UTF-8 decoded |

Both analyzers are always attempted sequentially (`corroborate_pcap` first, `pcap_flows` second) even when the first one fails.  Analyzer failure (any exit code, timeout, or missing output) is DATA in the receipt and never changes the CLI exit code on a successful capture.

## Residual risks

| Risk | Mitigation | Residual |
|---|---|---|
| Root / CAP_NET_RAW required | Operator runs `setcap cap_net_raw+ep /usr/bin/dumpcap`; never sudo | Privilege requirement is operator-owned |
| Shared-host capture observes other tenants' traffic | `RSDD_CAPTURE_IFACES` limits interface; BPF filter narrows packets | Filter over-breadth not semantically enforced |
| BPF filter injection | Passed as discrete `-f` token; dumpcap compiles it and fails closed on bad syntax | Filter semantics (too broad) not policeable |
| Interface-rename TOCTOU | Minor; allowlist check and iface open are not atomic | Documented; no practical mitigation |
| Partial pcap on timeout | SIGTERM before SIGKILL; dumpcap writes valid global header before flushing | `outcome: timeout-partial` is labeled, not treated as error |
| Analysis child inherits root when capture runs as actual root | `analysis` handoff (C2) spawns `corroborate_pcap`/`pcap_flows` as separate processes; their capinfos/tshark sub-invocations stay `bwrap --cap-drop ALL` | Pre-existing: the analyzers lack `corroborate_firmware`'s `euid==0` refusal guard, so their Python parsing runs as root under the (discouraged) root-operator path — follow-up candidate, not introduced by C1/C2 |

Exit codes: 0 success · 2 preflight/capture error · 3 authorization-required (no `--allow-live-capture`).

# Live traffic capture plan `capture-plan.v1`

`capture_plan.py` — offline live-capture planner (U-N8 / item 8).
Produces `capture-plan.v1.json` + `vm-determinism.v1.json`. NEVER captures:
no socket opened, no interface bound, no subprocess spawned.
Live capture gated behind `--allow-live-capture` (U-F1 gate contract).

## CLI

```
python3 capture_plan.py plan \
    --interface  IFACE         # validated: only [A-Za-z0-9._:-] allowed (max 63 chars)
    --output     DIR           # bind-scope guarded output directory
    [--bpf-filter EXPR]        # BPF filter (recorded as data, never compiled/executed here)
    [--snaplen N]              # snapshot length in bytes (default 65535)
    [--duration-seconds N]     # max capture duration (default 60 s)
    [--packet-count N]         # max packets to capture (default 10000)
    [--allow-live-capture]     # authorize live capture (no live executor → exit 2)
```

## Containment policy (future live executor MUST enforce every row)

| Policy | Guarantee | Enforcing mechanism |
|---|---|---|
| **No capture in plan** | No socket opened, no interface bound, no subprocess spawned. | `socket` not imported; `subprocess.Popen/run` never called |
| **Interface name safe charset** | Only `[A-Za-z0-9._:-]` (max 63 chars); injection strings rejected at CLI before argv construction. | `validate_iface()` — clean error, exit 2, no traceback |
| **BPF filter recorded as data** | Validated for length and NUL bytes only; never compiled, never executed here. | `validate_bpf()` — syntactic check, not semantic |
| **Argv as `list[str]`** | Interface and BPF are discrete argv elements; never interpolated into a shell string. | `planned_argv: list[str]`; no `shell=True` anywhere |
| **Duration + packet caps** | Always bounded and present in the emitted plan with sane defaults. | `capture_spec.duration_seconds`, `capture_spec.packet_count_cap` |
| **Output bind-scope** | Output directory rejected if it is a system path or too shallow. | `assert_safe_bind_root` → exit 2 on violation |
| **Required OS capability** | `CAP_NET_RAW` recorded in plan; the future executor must acquire it before opening the interface. | `required_os_capability: "CAP_NET_RAW"` |

## `capture-plan.v1` schema

| Field | Type | Description |
|---|---|---|
| `schema_version` | `"capture-plan.v1"` | Schema identifier |
| `capture_spec` | `{interface, bpf_filter, snaplen, duration_seconds, packet_count_cap}` | Capture specification |
| `output` | `{path, format}` | Intended pcap output path (`/tmp/rsdd/capture.pcap`; never written in dry-run) |
| `required_os_capability` | `"CAP_NET_RAW"` | OS capability the future live executor must hold |
| `planned_argv` | `list[str]` | Full `dumpcap` invocation (NEVER executed in dry-run) |
| `outputs` | `[]` | Empty until live capture |
| `limitations` | `list[str]` | `["outputs-unknown-until-live-capture"]` |

Interface name validated against `[A-Za-z0-9._:-]` (max 63 chars) before argv embedding;
anything outside (semicolons, pipes, `$`) → exit 2, no traceback. Passed as `["-i", iface]`,
never shell-concatenated. `bpf_filter` is `null` when omitted, recorded as data only.
Caps (`duration_seconds`, `packet_count_cap`) are always positive integers with sane defaults.

## Determinism and gate

`vm-determinism.v1.json`: always `declared:false`, `basis:"dry-run-plan"`,
`receipt_identity:null`. Same inputs produce bit-identical plans.

| Condition | Outcome |
|---|---|
| `--allow-live-capture` absent | `authorization-required` / exit 3 |
| `--allow-live-capture` + no executor | `GateError` / exit 2 |

Exit codes: 0 executor ran · 2 hard error · 3 authorization-required.

## Executor contract (future live executor)

Must acquire `CAP_NET_RAW` before opening the interface. MUST NOT use `shell=True`.
On interface-not-found, duration-cap, packet-cap, or general error: return a structured
error with `errors: [...]` and `completeness: "failed"`; never partially capture silently.

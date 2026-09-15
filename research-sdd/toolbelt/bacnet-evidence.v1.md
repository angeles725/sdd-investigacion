# `bacnet-evidence.v1`

`corroborate-bacnet.sh --host <ip> --output <new-out-dir> [--port N] [--src-port N] [--local-bcast <bcast-ip>] [--bbmd <ip>] [--timeout N] [--allow-live-probe] [--json]`
runs a **read-only** BACnet/IP reachability and BBMD probe against a live host,
and emits a deterministic evidence envelope.

Reports reachability verdict, unicast/broadcast Who-Is results, and BBMD BDT/FDT tables —
never writes BACnet objects, never issues Write-BDT, never registers as a Foreign Device.

**Guard:** without `--allow-live-probe` the wrapper exits 3 and writes an offline plan only —
no UDP frames are sent and no network connection is made.

## Trust Boundary And Accepted Input

A live BACnet/IP host reachable over UDP.  Accepted inputs:

- **`--host`** (required): IP address of the target BACnet/IP field device or BBMD.
- **`--output`** (required): directory where `bacnet-evidence.v1.json` is written.
- **`--port`** (default 47808 / 0xBAC0): BACnet/IP UDP port.
- **`--src-port`** (default 0 = ephemeral): local UDP bind port.
- **`--local-bcast`**: broadcast address of the local interface (e.g. `192.168.1.255`);
  required to exercise the broadcast Who-Is path.  Omitting it skips the broadcast probe.
- **`--bbmd`**: optional additional IP probed as a candidate BBMD; `--host` is always probed.
- **`--timeout`** (default 3.0 s): per-probe UDP listen window.
- **`--json`**: also write evidence to stdout as JSON.

Only ANSI/ASHRAE 135 read-only service primitives are sent:
- Unconfirmed-Request Who-Is (unicast, and broadcast when `--local-bcast` is provided)
- Read-BDT (0x02) / Read-FDT (0x06)

State-changing operations (Write-BDT 0x01, Register-Foreign-Device 0x05) are never sent.

## Evidence Schema (`bacnet-evidence.v1.json`)

### Plan-only output (exit 3; `--allow-live-probe` absent)

| Field | Content |
|---|---|
| `schema` | `"bacnet-evidence.v1"` |
| `status` | `"plan-only"` |
| `host` | Target IP string as supplied |
| `port` | UDP port integer |
| `guard` | Human-readable explanation that `--allow-live-probe` is required |
| `plan.protocol` | `"ANSI/ASHRAE 135 BACnet/IP"` |
| `plan.read_only` | `true` |
| `plan.probes` | List of probe names that would run: `["unicast-who-is", "broadcast-who-is", "read-bdt", "read-fdt"]` |
| `plan.note` | Note about `--local-bcast` requirement for broadcast Who-Is |

### Live-probe output (exit 0 or 1; `--allow-live-probe` present)

| Field | Content |
|---|---|
| `schema` | `"bacnet-evidence.v1"` |
| `status` | `"complete"` |
| `host` | Target IP string as supplied |
| `port` | UDP port integer |
| `probes.unicast_who_is.reachable` | `true` when the host replied with I-Am to a directed unicast Who-Is |
| `probes.unicast_who_is.instance` | BACnet device instance number (integer) from I-Am, or `null` |
| `probes.broadcast_who_is.local_bcast` | Broadcast IP used, or `null` when `--local-bcast` not supplied |
| `probes.broadcast_who_is.responders` | Map of `{ip: [instance, …]}` for all I-Am replies |
| `probes.broadcast_who_is.crossed_from_target_subnet` | Subset of `responders` sharing the first three octets with `--host` (hard-coded /24 assumption; if `--host` is on the same /24 as the runner, this set is non-empty by design and the `REBIND OK` verdict is trivial) |
| `probes.broadcast_who_is.same_as_local` | Subset of `responders` on a different /24 than `--host` |
| `probes.broadcast_who_is.note` | Present (with skip explanation) when `--local-bcast` was not supplied |
| `probes.bbmd_probe` | Map of `{host_ip: {is_bbmd, bdt, fdt}}` for each candidate probed |
| `probes.bbmd_probe.<ip>.is_bbmd` | `true` when a Read-BDT-Ack was received within the probe window (any source; not filtered by source IP) |
| `probes.bbmd_probe.<ip>.bdt` | BDT entry list (`{addr, mask}` per entry) or `null` when not a BBMD |
| `probes.bbmd_probe.<ip>.fdt` | FDT entry list (`{addr, ttl_s, remaining_s}` per entry) or `null` |
| `verdict_code` | `"ok"` / `"rebind_fail"` / `"inconclusive"` |
| `verdict` | Human-readable verdict string explaining the rebind conclusion |

BDT address format: `"A.B.C.D:0xPPPP"` (IP + port in hex).  FDT address: same format.

## Three-State Honesty (§7 Compliance)

Three distinguishable states are always produced:

| State | Indicator |
|---|---|
| plan-only (guard not lifted) | Exit 3; `status: "plan-only"`; no UDP frames sent; plan JSON written |
| complete (live probe ran) | Exit 0 (`verdict_code: "ok"`) or 1 (`"rebind_fail"` / `"inconclusive"`); `status: "complete"` |
| operational error | Exit 2; error printed to stderr; no evidence written (e.g. socket bind failure) |

A `status: "complete"` result always proves the probe ran and received (or failed to receive)
BACnet frames — it is never returned when the socket could not be opened.

## Caps and Truncation

| Bound | Value |
|---|---|
| UDP datagram read limit | 1500 bytes (single Ethernet MTU) |
| Per-probe listen window | `--timeout` (default 3.0 s) |
| BDT / FDT entry parsing | Walks the full ACK payload (10 bytes per entry); no server-side cap |

No output truncation or server-side cap is applied; the full BDT/FDT tables are emitted.
Truncation is not applicable for this schema.

## Non-Goals

- No BACnet confirmed services (ReadProperty, WriteProperty) are sent.
- No BACnet object enumeration or property value extraction.
- No Write-BDT or Register-Foreign-Device frames are ever sent.
- The wrapper does not confirm BACnet device identity beyond the I-Am instance number.
- `--allow-live-probe` does not bypass firewall rules or UDP routing; the probe only confirms
  reachability from the host running the wrapper.

## Output Layout

```
output-dir/
  bacnet-evidence.v1.json    # canonical evidence (key-sorted JSON)
```

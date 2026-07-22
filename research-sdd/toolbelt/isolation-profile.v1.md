# isolation-profile.v1 — Sandbox Security Posture Contract

**Status**: active  
**Authority**: `lib/isolation_profile.py` (construction), `analysis_manifest.py:382-385` (validation)

## Purpose

An isolation profile records the sandbox security posture that was in effect
when a Research-SDD corroboration adapter ran.  Every `analysis-manifest.v1`
document carries exactly one profile under the `"isolation_profile"` key.

The profile is an immutable record — it documents what happened, not a policy
input to a running sandbox.  The sandbox's actual security constraints are
configured by `adapter_core.sandbox()` (bubblewrap arguments).  The profile
name must accurately reflect the sandbox posture actually used.

## Schema

```json
{
  "name":             "<string>",
  "static_only":      true | false,
  "network_access":   true | false,
  "target_execution": false
}
```

### Fields

| Field            | Type    | Required | Constraint                    | Meaning |
|------------------|---------|----------|-------------------------------|---------|
| `name`           | string  | yes      | non-empty                     | Human-readable identifier; must accurately describe the sandbox posture |
| `static_only`    | boolean | yes      | —                             | `true` when the adapter never executes target code; `false` for detonation contexts |
| `network_access` | boolean | yes      | —                             | `true` when the sandbox permits outbound/inbound network traffic; `false` when network-denied |
| `target_execution` | boolean | yes   | MUST be `false`               | Always `false` for corroboration adapters; `true` is reserved for detonation adapters and is rejected by the validator |

### Invariant

`target_execution` MUST be `false` for all Research-SDD corroboration
adapters.  The construction authority (`make_profile`) enforces this at build
time.  The `analysis_manifest.py` validator (line 384) enforces it again at
read/validate time.  Any profile with `target_execution: true` MUST NOT
appear in a corroboration manifest.

## Named profiles

These profiles are defined as constants in `lib/isolation_profile.py`.

| Constant | `name` | `static_only` | `network_access` | Used by |
|---|---|---|---|---|
| `PROFILE_BWRAP_STATIC_NETWORK_DENIED` | `bubblewrap-static-network-denied` | `true` | `false` | `corroborate_firmware`, `corroborate_java`, `corroborate_native` |
| `PROFILE_BWRAP_PCAP_OFFLINE` | `bubblewrap-pcap-offline` | `true` | `false` | `corroborate_pcap`, `pcap_flows` |
| `PROFILE_BWRAP_CAPA_OFFLINE` | `bubblewrap-capa-offline` | `true` | `false` | `corroborate_capa` |
| `PROFILE_BWRAP_FLOSS_OFFLINE` | `bubblewrap-floss-offline` | `true` | `false` | `corroborate_floss` |
| `PROFILE_BWRAP_KAITAI_OFFLINE` | `bubblewrap-kaitai-offline` | `true` | `false` | `corroborate_kaitai` |
| `PROFILE_BWRAP_UNBLOB_OFFLINE` | `bubblewrap-unblob-offline` | `true` | `false` | `corroborate_unblob` |
| `PROFILE_BWRAP_UNSQUASHFS` | `bwrap-unsquashfs` | `true` | `false` | `squashfs_extract` |
| `PROFILE_INPROCESS_ZIP_METADATA` | `in-process-metadata-only` | `true` | `false` | `zip_metadata` |
| `PROFILE_INPROCESS_ZIP_STORED` | `in-process-static-stored-copy` | `true` | `false` | `zip_stored` |

## Dynamic profiles

Adapters whose sandbox posture varies at runtime MUST NOT use a named constant.
They MUST call `make_profile()` directly at the call site with the correct
runtime values.

**Ghidra** (`corroborate_ghidra.py`): the `--isolated` flag controls whether
network access is denied.

```python
from lib.isolation_profile import make_profile

"isolation_profile": make_profile(
    "bubblewrap-ghidra-static" if isolated else "test-only-untrusted-bwrap",
    network_access=not isolated,
)
```

## Construction

All isolation-profile dicts MUST be produced by `make_profile()`.  Inline
dict literals are prohibited.

```python
from lib.isolation_profile import make_profile, PROFILE_BWRAP_PCAP_OFFLINE

# Use a named constant when the posture is fixed.
"isolation_profile": PROFILE_BWRAP_PCAP_OFFLINE

# Call make_profile() when the posture varies at runtime.
"isolation_profile": make_profile("my-adapter-profile", network_access=True)
```

## Canonical JSON representation

The manifest is serialized via `canonical_bytes()` (`sort_keys=True`).
Regardless of key insertion order in the source dict, the serialized form
is always alphabetically sorted:

```json
{"name":"bubblewrap-pcap-offline","network_access":false,"static_only":true,"target_execution":false}
```

## Profiles NOT using this schema

Some adapters record an `"isolation"` key (not `"isolation_profile"`) in their
own evidence report using a different schema.  These are NOT managed by
`lib/isolation_profile.py`:

- `squashfs_extract.py` — `"isolation"` key in `squashfs-extract.v1.json`
  uses `{bubblewrap, network_access, payload_execution, static_only}`
- `firmware_carve.py` — `"isolation"` key uses a 5-key schema including
  `vm_boundary`
- `corroborate_ghidra.py` — `"isolation"` key in `report.json` uses a
  6-key schema including `read_only_host_root`, `new_session`,
  `synthetic_user_state`

Only the `"isolation_profile"` key in `analysis-manifest.v1` documents is
governed by this contract.

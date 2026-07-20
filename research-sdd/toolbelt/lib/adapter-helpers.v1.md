# adapter-helpers.v1 — Research-SDD Shared Adapter Helpers

Contract for `lib/adapter_helpers.py`.  Higher-level helpers built on
`adapter_core` primitives.  New adapters (unblob, floss, capa, kaitai) import
from here.  Item-24 migrates existing adapters by replacing inline
duplications with these imports.

**Dependency direction**: `adapter_helpers` → `adapter_core` (never reversed).
This file is a library module, not an artifact adapter; no tool-registry row.

---

## Standard evidence envelope schema

Every adapter produces one JSON file per run.  `emit_evidence` writes it:

```json
{
  "schema":     "<adapter-schema-id>",
  "status":     "complete" | "failed",
  "input":      { "source": {path,size,sha256}, "staged": {path,size,sha256} },
  "isolation":  { "launcher": {path,size,sha256}, "profile": {…} },
  "limitations": [ "…" ],
  "errors":     [ "…" ],
  "<domain-key>": "…"   ← adapter-specific fields merged last
}
```

---

## `emit_evidence(*, stage, schema, domain, input_identity, isolation, limitations, errors, manifest_spec, manifest_cli, destination, timeout=60)`

Assembles the envelope, writes it, runs the manifest-CLI tail, publishes.

| Parameter | Type | Description |
|---|---|---|
| `stage` | `Path` | Staging directory (caller-created; must contain `engine/`) |
| `schema` | `str` | Schema id, e.g. `"pcap-evidence.v1"` |
| `domain` | `dict` | Adapter-specific fields merged into the envelope |
| `input_identity` | `dict` | `{"source": record, "staged": record}` from `stage_file()` |
| `isolation` | `dict` | `{"launcher": record, "profile": dict}` |
| `limitations` | `list[str]` | Human-readable limitation strings |
| `errors` | `list[str]` | Tool error strings from `run_bounded()` |
| `manifest_spec` | `dict` | Full `analysis-manifest.v1` spec (built by adapter) |
| `manifest_cli` | `Path` | Absolute path to `analysis_manifest.py` |
| `destination` | `Path` | Final publish path (must not exist) |
| `timeout` | `int` | Seconds for **every** manifest-CLI `subprocess.run` call.  Mandatory; default 60. |

Raises `ManifestError` (subclass of `AdapterError`) on any failure.
`timeout=` is never optional — omitting it from a direct `subprocess.run`
call was the repeat 4R finding this helper closes.

---

## `pcap_magic_check(path)`

Opens *path* with `O_NOFOLLOW` and validates the first 4 bytes against all
known libpcap (LE/BE × µs/ns) and pcapng magic values.
Raises `PcapMagicError` on bad magic, symlinks, or unreadable files.
Consolidates the duplication in `corroborate_pcap.py` and `pcap_flows.py`.

---

## `squashfs_superblock(data, offset=0) → dict | None`

Parses and validates a SquashFS v4 LE superblock at *offset* in *data*
(`bytes` or `memoryview`).  Returns a field dict on success; `None` on bad
magic or failed validation.  Consolidates `squashfs_extract.py` and
`firmware_carve.py`.  Named constants: `SQFS_SB_FMT`, `SQFS_SB_SIZE`,
`SQFS_FLAG_EXPORTABLE`.

---

## Error classes

| Class | Base | When raised |
|---|---|---|
| `ManifestError` | `AdapterError` | manifest-CLI nonzero/timeout or publish failure |
| `PcapMagicError` | `AdapterError` | bad pcap magic, symlink, or unreadable file |

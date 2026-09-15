# `niagara-hdb.v1`

`niagara-hdb-read.sh --input <file.hdb> --output <evidence.json>`
reads a Niagara N4 binary history file (.hdb), extracts the embedded HistoryConfig
XML schema, and emits a deterministic key-sorted JSON evidence envelope.

Uses only Python stdlib; no external tools or network access required.
Read-only: no writes, no subprocesses, no decoding of binary record data.

## Trust Boundary and Accepted Input

Any regular, non-symlink `.hdb` file containing a Niagara N4 history archive.

- **Symlink input**: rejected via `O_NOFOLLOW`; exit 2, no evidence emitted.
- **Absent or unreadable file**: exit 2, no evidence emitted.
- **Wrong magic bytes** (not `0xA106F11E`): `status: failed`; exit 1; JSON
  emitted with `errors` populated.
- **Truncated file** (declared `config_xml_len` exceeds remaining bytes):
  `status: failed`; exit 1; JSON emitted with `errors` populated.
- **Valid .hdb**: `status: complete`; exit 0; `history_config` and `summary`
  populated from the embedded HistoryConfig XML.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Complete — valid .hdb, schema extracted |
| 1 | Parse error — bad magic, truncated header, or corrupt structure (`status:failed` JSON emitted) |
| 2 | I/O error — absent/unreadable input or symlink input/output (no JSON emitted) |

## Evidence Schema (`niagara-hdb.v1.json`)

| Field | Content |
|-------|---------|
| `schema` | `"niagara-hdb.v1"` |
| `status` | `"complete"` or `"failed"` |
| `input.sha256` | SHA-256 hex digest of the full input file |
| `input.size_bytes` | Total byte size of the input file |
| `history_config.history_id` | History identifier path from the XML (e.g. `/station/Trend`) or `null` if absent |
| `history_config.record_type` | Baja type of the record (e.g. `history:NumericTrendRecord`, `history:AuditRecord`) or `null` |
| `history_config.reversible_encoding` | Value of `reversibleEncodingKeySource` attribute; `"none"` means records are unencrypted |
| `history_config.schema_fields` | Ordered list of `{"name": "...", "type": "..."}` objects parsed from the schema attribute |
| `history_config.source` | Source slot path from the XML, or `null` if absent |
| `history_config.time_zone` | Time zone string from the XML, or `null` if absent |
| `summary.config_xml_bytes` | Byte length of the embedded HistoryConfig XML, or `null` on parse failure |
| `summary.field_count` | Number of schema fields parsed from the XML |
| `summary.record_region_bytes` | Byte count of the unparsed record region (file_size - 12 - config_xml_bytes), or `null` on parse failure |
| `summary.version` | File format version integer from the header, or `null` on parse failure |
| `errors` | Parse-level error strings; non-empty iff `status: failed` |
| `limitations` | Static disclaimer strings |

## Anti-Silent-Zero (S7 Compliance)

Three states are always distinguishable:

| State | Exit | JSON | Indicator |
|-------|------|------|-----------|
| absent-or-unreadable | 2 | none | file missing, unreadable, non-regular, or symlink; error on stderr |
| parse-error | 1 | `status: "failed"`, `errors` non-empty | bad magic, cap exceeded, truncated header, or short XML read |
| valid | 0 | `status: "complete"`, `errors: []` | header and XML extracted successfully |

A `.hdb` file has no meaningful "empty" state (a zero-length file cannot
contain the 12-byte header and is reported as parse-error, not absent-or-unreadable).

## Caps and Truncation

| Cap | Value |
|-----|-------|
| `_MAX_CONFIG_BYTES` | 1 MiB (1,048,576 bytes) |

When the declared `config_xml_len` exceeds `_MAX_CONFIG_BYTES`, the tool raises
a parse error (`status:failed`, exit 1) before any read.  This bounds both memory
use and O(n²) regex CPU cost regardless of file size — a crafted file with
`clen ≈ file_size` is rejected at the cap check, never read.  Fleet files use
approximately 1,600 bytes; 1 MiB is generous.

If the declared length is within the cap but exceeds the bytes remaining in the
file, a short-read error is raised at read time.

The record binary region is never decoded; its byte count is computed
from the file size and reported in `summary.record_region_bytes`.

## Non-Goals

- Binary record data (timestamps, field values, audit entries) is never decoded
  or published.  Only the embedded XML schema is extracted.
- Encrypted record regions (`reversibleEncodingKeySource != "none"`) are not
  decrypted.
- Multi-segment history (`.hdb` files referencing other segments) is not
  followed; each file is read independently.
- No `.hdb` writes are performed.

## Output Layout

```
evidence.json      # key-sorted JSON (this schema)
```

The output path must not already exist (symlinks and pre-existing files are
refused with exit 2 via `O_CREAT|O_EXCL|O_NOFOLLOW`).

## Invocation Example

```bash
niagara-hdb-read.sh --input history.hdb --output hdb-evidence.json
```

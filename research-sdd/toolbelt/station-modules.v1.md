# station-modules.v1 — Niagara N4 Station Module Dependency Schema

## Invocation

```
station-modules.sh --input <config.bog> --install <niagara_root> --output <evidence.json>
```

| Argument | Description |
|---|---|
| `--input BOG` | Niagara N4 config.bog (ZIP-compressed `file.xml`) or bare plaintext XML |
| `--install ROOT` | Niagara N4 install root directory (contains `modules/`) |
| `--output JSON` | Output evidence file (must not already exist; must not be a symlink) |

## One-Line Bounds

Resolves module aliases and type references from a station's config.bog against
installed JARs in `<install_root>/modules/`; reports missing module-parts. Read-only.
JAR scan capped at 2 000 entries; ZIP file.xml inflate capped at 32 MiB.

## Trust Boundary and Accepted Input

- `--input` must be a regular, non-symlink file; FIFOs and device nodes are rejected.
- `--install` must be a non-symlink directory; trailing path separators are stripped
  before the lstat check.
- No subprocess is spawned. No network I/O is performed.
- The tool never writes to the input file or install directory.

## Evidence Schema

| Field | Content |
|---|---|
| `schema` | Always `"station-modules.v1"` |
| `status` | `"complete"` (bog parsed, check ran) or `"failed"` (malformed/capped bog or broken install) |
| `input.format` | `"zip-xml"` (ZIP .bog) or `"plaintext-xml"` (bare XML) or `"unknown"` |
| `input.sha256` | SHA-256 hex of the input file |
| `input.size_bytes` | File size in bytes |
| `install_root` | Path to the Niagara install root used |
| `modules` | Dict: module name → `{installed_parts: [...], types_referenced: [...], types_unresolved: [...]}` |
| `missing_parts` | Dict: part name → reason string — only modules with **no parts installed** appear here |
| `summary.modules_referenced` | Count of distinct modules found in the station bog |
| `summary.missing_parts` | Count of modules entirely absent from the install |
| `summary.types_unresolved` | Count of type references whose type was not found in any installed part (module IS installed; possible version/profile mismatch) |
| `summary.jars_scanned` | Number of JARs actually read from `modules/` |
| `summary.jars_skipped_oversized` | JARs whose `module.xml` exceeded the 64 KiB per-JAR cap |
| `summary.jars_total` | Total `.jar` files in `modules/` |
| `summary.unresolved_aliases` | Count of `t=` type references whose alias was not declared in any `m=` attribute |
| `truncated` | `true` when inflate cap or JAR scan cap fired |
| `errors` | List of error/warning strings (empty on clean runs) |
| `limitations` | Fixed list of documented constraints |

### missing\_parts vs types\_unresolved

These are two distinct findings:

- **`missing_parts`**: module has **no installed parts** at all. The default part name `{mod}-rt` is reported as the expected entry point.
- **`types_unresolved`** (per-module list): module IS installed (parts present) but a referenced type was not found in any part's `module.xml`. This indicates a version or runtime-profile mismatch, not an absent module.

A module that appears in `installed_parts` will **never** appear in `missing_parts`.

## Three-State Honesty (§7)

| State | Exit | Status | jars_scanned |
|---|---|---|---|
| Absent or non-regular input | 2 | (no JSON) | — |
| Malformed bog / inflate cap exceeded | 1 | `failed` | 0 |
| Parsed successfully — no missing parts | 0 | `complete` | N (proves instrument looked) |
| Parsed successfully — missing parts found | 0 | `complete` | N (proves instrument looked) |
| Empty station (no module references) | 0 | `complete` | N (proves instrument looked) |

`modules_referenced=0` with `jars_scanned>0` is a valid and distinguishable state
(empty station bog against a valid install) — not a silent zero.

## Caps and Truncation

| Limit | Default | Field when fired |
|---|---|---|
| ZIP `file.xml` inflate | 32 MiB | `truncated: true`, `status: failed` |
| Plaintext bog read | 32 MiB | `truncated: true`, `status: failed` |
| Install JAR scan | 2 000 entries | `truncated: true`, error note in `errors` |
| Per-JAR `module.xml` inflate | 64 KiB | `summary.jars_skipped_oversized` incremented |

Truncation is always visible; a capped run never silently under-reports (§7).

## Non-Goals

- Does not copy staged JARs into `modules/` (read-only; no `--fix` flag).
- Does not perform transitive dependency closure across installed parts.
- Does not invoke Niagara CLI tools or query a live station.
- Does not validate JAR signatures or module vendor credentials.

## Output Layout

The example below uses the hermetic test fixture: `baja` is installed (`baja-rt`
present), `testmodule` is not installed (its `-rt` part is absent).

```json
{
  "errors": [],
  "input": {
    "format": "zip-xml",
    "sha256": "...",
    "size_bytes": 512
  },
  "install_root": "/path/to/niagara_home",
  "limitations": [
    "Install JAR scan capped at 2000 entries.",
    "ZIP file.xml inflate capped at 32 MiB (zip-bomb protection).",
    "Plaintext bog read capped at 32 MiB (zip-bomb defence).",
    "Slot values are never emitted (secrets discipline).",
    "Fix operations are not performed (read-only tool)."
  ],
  "missing_parts": {
    "testmodule-rt": "module testmodule not installed (type TestService referenced)"
  },
  "modules": {
    "baja": {
      "installed_parts": ["baja-rt"],
      "types_referenced": ["Station"],
      "types_unresolved": []
    },
    "testmodule": {
      "installed_parts": [],
      "types_referenced": ["TestService"],
      "types_unresolved": []
    }
  },
  "schema": "station-modules.v1",
  "status": "complete",
  "summary": {
    "jars_scanned": 2,
    "jars_skipped_oversized": 0,
    "jars_total": 2,
    "missing_parts": 1,
    "modules_referenced": 2,
    "types_unresolved": 0,
    "unresolved_aliases": 0
  },
  "truncated": false
}
```

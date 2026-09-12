# `ifc-evidence.v1`

`corroborate-ifc.sh --input <file.ifc> --output <new-out-dir> [--timeout N] [--max-types N]`
runs [ifcopenshell](https://ifcopenshell.org/) (0.8.5, rsdd-ifc venv) in a network-denied
Bubblewrap sandbox, builds a **bounded entity-type histogram** of an IFC/BIM model
file, and emits a deterministic evidence envelope.

Reports COUNTS + a BOUNDED, sorted entity histogram — never raw geometry, property
sets, or unbounded attribute trees.  Any cap that fires is reported in `limitations` and
`entity_histogram.truncated` is set to `true`; truncation is **never silent**.

## Trust Boundary And Accepted Input

Any regular non-symlink `.ifc` file.  ifcopenshell identifies the schema version
automatically from the file header.

- **IFC2X3, IFC4, IFC4X3**: fully supported schema versions; schema_version is
  extracted from the `FILE_SCHEMA` header declaration.
- **Valid IFC with zero entities**: evidence published with `status: complete` and
  an empty histogram (`total_entities: 0`, `items: []`) — not fail-closed.
  A zero count in `entity_histogram.total_entities` proves the driver actually
  opened and counted the file; it is never returned when the driver failed to run.
- **Non-IFC or corrupt file**: `parse_error` is recorded in the evidence `errors`
  list; `status: failed`; exit code 1.
- **Absent or unreadable input**: `stage_file()` raises `AdapterError` before the
  sandbox launches; exit code 2, no evidence published.
- **Symlink input**: rejected by `stage_file()` via `O_NOFOLLOW`; exit code 2.

## Analysis Sandbox

ifcopenshell runs inside a hardened Bubblewrap sandbox:

| Property | Value |
|---|---|
| Network access | Denied (`--unshare-net`) |
| Capabilities | All dropped (`--cap-drop ALL`) |
| PID namespace | New (`--unshare-pid`) |
| Filesystem | OS runtime dirs (`/usr`, `/bin`, `/lib`, …) + rsdd-ifc venv read-only + brew Cellar Python read-only; no home, /run, /etc credentials, or user data exposed |
| Signal | `--die-with-parent` — sandbox killed on parent exit |

The rsdd-ifc venv (`~/.local/share/rsdd-ifc`) is validated and bound read-only;
no analysis artifact persists in the venv tree.

## Outputs And Determinism

For the same input file, the same installed ifcopenshell, and the same `--max-types`,
`ifc-evidence.v1.json` is byte-reproducible across independent invocations:

- `entity_histogram.items` is sorted by `(-count, type)` before any cap is applied.
- No timestamps, no absolute host paths, and no run-varying fields appear in the JSON
  payload.
- The `driver_argv` field records the canonical inside-sandbox argv (fixed paths
  independent of the host output directory name).

## Evidence Schema (`ifc-evidence.v1.json`)

| Field | Content |
|---|---|
| `schema` | `"ifc-evidence.v1"` |
| `status` | `"complete"` or `"failed"` |
| `input.source` | Source path, byte size, sha256 |
| `input.staged` | Staged logical path, byte size, sha256 |
| `isolation.launcher` | bwrap path, size, sha256 |
| `isolation.profile` | `bubblewrap-ifc-offline` profile with `network_access: false`, `target_execution: false` |
| `ifc.schema_version` | IFC schema from the file header (`IFC4`, `IFC2X3`, `IFC4X3`, …) |
| `ifc.units.length` | Length unit name (`METRE`, `MILLIMETRE`, …) or `null` if absent |
| `ifc.units.area` | Area unit name (`SQUARE_METRE`, …) or `null` if absent |
| `ifc.entity_histogram.total_entities` | Total entity count (sum of all types) |
| `ifc.entity_histogram.total_types` | Total distinct entity type count |
| `ifc.entity_histogram.truncated` | `true` when type-count cap or run-level cap fired |
| `ifc.entity_histogram.items` | Bounded, sorted list of `{type, count}` records |
| `ifc.project.name` | `IfcProject.Name` string (bounded to 256 chars) or `null` |
| `ifc.project.site_count` | Count of `IfcSite` entities |
| `ifc.driver_argv` | Inside-sandbox driver argv (canonical, deterministic) |
| `limitations` | Static disclaimers + any cap-trip strings |
| `errors` | Driver-level errors (parse-error, timeout, output-cap, driver crash) |

### Entity histogram item

| Field | Content |
|---|---|
| `type` | IFC entity type name (e.g. `IfcWall`, `IfcSpace`, `IfcColumn`) |
| `count` | Number of instances of this type in the file |

## Caps and Truncation Contract

All caps are visible when they fire: a limitation string is appended to `limitations`
and `entity_histogram.truncated` is set to `true`.  **Truncation is never silent.**

| Cap | Flag | Default |
|---|---|---|
| Entity type count | `--max-types` | 200 |
| Wall-clock timeout | `--timeout` | 120 s |

- **Type count cap**: when the number of distinct entity types exceeds `--max-types`,
  `items` is bounded to `--max-types` entries (sorted by count DESC then type ASC).
  The limitation string `"histogram truncated: entity-type cap N reached (total_types=M)"`
  is appended.
- **Run-level caps** (timeout, output-cap): when `run_bounded` fires a resource cap,
  `run_truncation` maps it to `entity_histogram.truncated: true` and a limitation string.

## Anti-Silent-Zero (§7 Compliance)

Three states are always distinguishable:

| State | Indicator |
|---|---|
| absent-input | Adapter exits 2; no evidence published; `stage_file()` error on stderr |
| empty-input | `status: complete`; `total_entities: 0`; `items: []` |
| parse-error | `status: failed`; `errors` list contains `"parse-error: …"` |

A `total_entities: 0` result proves the driver opened and counted the file, finding
zero entities — it is never returned when the driver failed to run or did not produce
output.

## Non-Goals

- Raw geometry, B-rep solids, or mesh data are never published.
- Property sets, material assignments, and relationships are not walked.
- No IFC file is ever written or modified; the adapter is strictly read-only.
- The adapter does not validate IFC semantic correctness (e.g. required attributes);
  it only counts entity types as presented in the file.
- `bwrap` on WSL2 is a defense-in-depth measure; it is not a hostile-parser security
  boundary.  Use a disposable QEMU VM for adversarial IFC files.

## Output Layout

```
output-dir/
  ifc-evidence.v1.json       # canonical evidence (key-sorted JSON)
  engine/
    analysis-manifest.v1.json
    stdout.txt               # driver JSON output
    stderr.txt               # driver diagnostics
  input/
    model.ifc                # staged copy of input (mode 0400)
```

## Venv Provisioning

The rsdd-ifc venv is not provided by the kit; provision it once per machine:

```bash
python3 -m venv ~/.local/share/rsdd-ifc
~/.local/share/rsdd-ifc/bin/pip install ifcopenshell
```

Override the venv Python with `RSDD_IFC_PY=<path/to/python>`.
Override the driver script with `RSDD_IFC_DRIVER=<path/to/ifc_driver.py>` (test use only).

# kaitai-evidence.v1 — Kaitai Struct Binary Parsing Evidence Schema

Schema identifier: `kaitai-evidence.v1`
Produced by: `corroborate-kaitai.sh` / `corroborate_kaitai.py`
Pipeline: two-stage (Stage 1: ksc JVM compile; Stage 2: kaitai Python driver parse)

## Envelope (standard fields)

| Key | Type | Description |
|-----|------|-------------|
| `schema` | string | Always `"kaitai-evidence.v1"` |
| `status` | string | `"complete"` when `errors == []`; `"failed"` otherwise |
| `input.source` | object | `{path, size, sha256}` of the binary analysed |
| `input.staged` | object | `{path, size, sha256}` of the binary inside the stage dir |
| `isolation.launcher` | object | `{path, sha256}` of the bwrap launcher |
| `isolation.profile` | object | `{network_access: false, static_only: true, target_execution: false}` |
| `limitations` | string[] | Static limitations + any cap/truncation caveats |
| `errors` | string[] | Run errors (parse-error, timeout, compile failure, etc.) |

## Domain fields

### `structure`

Field-walk output from the Stage 2 driver.

| Key | Type | Description |
|-----|------|-------------|
| `root_type` | string | Name of the ksc-generated root class |
| `module` | string | Python module name (= `meta.id` from the .ksy) |
| `fields` | FieldRecord[] | Ordered list of walked fields (see below) |
| `counts.total_fields` | int | All fields visited during the walk |
| `counts.sampled` | int | Fields actually in `fields` list (≤ total_fields) |
| `truncated` | bool | True when any cap fired: field-count, depth, value-bytes, timeout, or output-cap. A parse error or non-zero tool exit alone does NOT set this field. |
| `parse_error` | string \| null | `"ErrorType: message"` or null on clean parse |

#### FieldRecord

| Key | Type | Description |
|-----|------|-------------|
| `path` | string | Dot-separated field path from root (e.g. `"hdr.origin.x"`) |
| `name` | string | Local field name (e.g. `"x"`) |
| `type` | string | One of `bytes`, `str`, `int`, `float`, `bool`, `struct`, `list`, `null` |
| `start` | int \| null | Byte offset of field start from `_debug` |
| `end` | int \| null | Byte offset of field end from `_debug` |
| `size` | int \| null | `end - start` when both are available |
| `value` | varies | See per-type encoding below |
| `depth_cap` | bool | Present and `true` when this struct was not recursed (depth cap) |
| `count` | int | Present for `list` type: number of elements |

**Per-type `value` encoding:**

- `bytes`: `{hex: str, sha256: "sha256:…", size: int, value_truncated: bool}` — hex is bounded to `--max-value-bytes` bytes; sha256 covers the full raw bytes.
- `str`: `{value: str, sha256: "sha256:…", size: int, value_truncated: bool}` — value is bounded to `--max-value-bytes` chars; sha256 covers the full UTF-8 encoding.
- `int`, `float`, `bool`: scalar value inline.
- `struct`, `list`, `null`: no `value` key (or omitted).

### `ksy_identity`

| Key | Type | Description |
|-----|------|-------------|
| `sha256` | string | SHA-256 of the source .ksy file |
| `size` | int | Size of the .ksy in bytes |
| `path` | string | Absolute host path to the .ksy |

### `compile`

Stage 1 (ksc JVM compile) metadata.

| Key | Type | Description |
|-----|------|-------------|
| `ksc_version` | string | Output of `kaitai-struct-compiler --version` |
| `generated_parser.path` | string | Relative path to generated .py (e.g. `engine/gen/demo.py`) |
| `generated_parser.sha256` | string | SHA-256 of the generated parser |
| `generated_parser.size` | int | Size of the generated parser in bytes |

### `runtime_version`

| Key | Type | Description |
|-----|------|-------------|
| `runtime_version` | string | `kaitaistruct.__version__` from Stage 2 driver |

## Analysis manifest

The analysis manifest at `engine/analysis-manifest.v1.json` records the Stage 2
(kaitai Python driver) run.  The `outputs` list covers:

- `kaitai-evidence.v1.json` — this evidence document
- `input/struct.ksy` — staged Kaitai Struct definition
- `engine/driver.py` — staged parse driver
- `engine/gen/<meta_id>.py` — ksc-generated Python parser
- `engine/compile-stdout.txt` — Stage 1 (ksc) standard output
- `engine/compile-stderr.txt` — Stage 1 (ksc) standard error

## Cap parameters

| Flag | Default | Effect |
|------|---------|--------|
| `--max-fields` | 2000 | Maximum SEQ_FIELDS yielded (`sampled`); walk continues for count |
| `--max-depth` | 32 | Maximum recursion depth for nested struct types |
| `--max-value-bytes` | 64 | Maximum bytes/chars shown per leaf value |
| `--max-memory-mb` | 256 | `RLIMIT_AS` for the Stage 2 driver process |
| `--timeout` | 300 | Wall-clock limit for Stage 2 (seconds) |
| `--compile-timeout` | 60 | Wall-clock limit for Stage 1 ksc (seconds) |

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Complete analysis — no errors |
| 1 | Analysis failed — parse error or timeout — evidence published |
| 2 | Fatal error — compile failure, bad inputs, or internal error — no evidence |

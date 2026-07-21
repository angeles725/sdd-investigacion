# In-VM execution receipt `vm-run-receipt.v1`

`vm_receipt.py` records the complete, content-addressed evidence of one run inside
a disposable VM or sandbox. It never launches a VM or the recorded tool.

## Quick path

1. After the VM exits, collect all artifact digests (sha256 + size) and metadata.
2. Write a spec JSON with pre-computed values (see field table below).
3. Run `python3 vm_receipt.py build --spec spec.json --output receipt.json`.
   Add `--overwrite` only when replacing an existing receipt is intentional.
4. Check structure: `python3 vm_receipt.py validate receipt.json`.
5. Rehash artifacts: `python3 vm_receipt.py verify --artifacts-dir <root> receipt.json`.

## Field table

| Field | Content-addressed | Required | Description |
|---|---|---|---|
| `schema_version` | yes | yes | Exactly `"vm-run-receipt.v1"` |
| `identity` | — (is the hash) | yes | SHA-256 of canonical content-addressed fields |
| `tool.name` | yes | yes | Human-readable tool name |
| `tool.version` | yes | yes | Tool version string |
| `tool.argv` | yes | yes | Full argv array (secret-free) |
| `tool.sha256` | yes | yes | SHA-256 of the tool binary |
| `limits.cpu_seconds` | yes | yes | CPU-time cap (positive integer, seconds) |
| `limits.mem_bytes` | yes | yes | Memory cap (positive integer, bytes) |
| `limits.wall_seconds` | yes | yes | Wall-clock cap (positive integer, seconds) |
| `limits.output_bytes` | yes | yes | Output-size cap (positive integer, bytes) |
| `vm_pre_snapshot` | yes | yes | `{"sha256": "sha256:…"}` or `null` |
| `vm_post_snapshot` | yes | yes | `{"sha256": "sha256:…"}` or `null` |
| `inputs` | yes | yes | Array of `{path, sha256, size}` input artifacts |
| `outputs` | yes | yes | Array of `{path, sha256, size}` output artifacts |
| `exit_status` | yes | yes | `{exit_code: N, signal: null}` or `{exit_code: null, signal: N}` |
| `environment` | yes | yes | Allowlisted env vars (see `ENV_ALLOWLIST`) |
| `observed` | **no** | yes | Non-deterministic measurements (see below) |

### Observed sub-object (excluded from identity)

| Field | Description |
|---|---|
| `wall_started_at` | UTC ISO-8601 timestamp when the VM run began |
| `wall_ended_at` | UTC ISO-8601 timestamp when the VM run ended |
| `wall_seconds_measured` | Actual elapsed wall-clock seconds |
| `cpu_seconds_measured` | Actual CPU-seconds consumed |
| `mem_bytes_peak` | Peak resident memory in bytes |

## Determinism guarantee

`identity` is the SHA-256 of the canonical JSON (sorted keys, compact separators,
UTF-8, one trailing newline) of the receipt with `identity` and `observed` removed.

Two receipts with identical inputs, tool, limits, snapshots, artifacts, exit status,
and environment have the same `identity` regardless of when they ran or how long
they took. This makes the receipt reproducible across timing-only reruns.

**Array canonicalisation**: `inputs` and `outputs` arrays are sorted by `path`
(ascending, lexicographic) before the identity hash is computed. A manual
re-derivation of the identity must path-sort each array; array insertion order
alone is not canonical and will produce a different hash.

## Secret-rejection policy

`argv` items and environment values are checked against regex patterns that cover
bearer tokens, GitHub PATs, Slack tokens, JWT prefixes, AWS keys, and PEM private-key
headers, plus compound option names such as `--token`, `--password`, `--client-secret`.
A matching value is **rejected** (raises `VmReceiptError`) — never stored, redacted,
or logged. The caller must redact secrets before capture and record that loss in a
`limitations` field of the enclosing analysis manifest.
Environment keys must appear in `ENV_ALLOWLIST`; any other key is rejected.

## How items 3/9/10/11/12 emit this receipt

Each tool that runs inside a disposable VM (gzip-xz-in-VM, trace capture, QEMU
detonation, generic deterministic-exec) should, after the run completes:

1. Compute sha256 + size for every input artifact, output artifact, and VM snapshots.
2. Populate a spec dict with all content-addressed fields plus the `observed` block.
3. Call `build_receipt(spec)` (Python) or `vm_receipt.py build --spec` (shell) to
   produce the canonical receipt.
4. Embed or reference the receipt path in the enclosing analysis manifest's `outputs`.

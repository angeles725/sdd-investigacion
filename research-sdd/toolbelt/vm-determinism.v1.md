# Determinism evidence `vm-determinism.v1`

`lib/vm_plan.py` produces a content-addressed record asserting a
reproducibility verdict for one in-VM run. It **wraps** `vm-run-receipt.v1`
by referencing its frozen `identity` hash — never duplicates receipt contents,
never extends or re-hashes the receipt schema.

## Field table (spec input — `declared` and `identity` are computed, not supplied)

| Field | Type | Required | Description |
|---|---|---|---|
| `schema_version` | str | yes | Exactly `"vm-determinism.v1"` |
| `receipt_identity` | sha256\|null | yes | Identity of the wrapped receipt, or `null` for dry-run |
| `seed` | int≥0\|null | yes | Pinned RNG seed or `null` |
| `clock.mode` | `"pinned"\|"host"` | yes | Clock source |
| `clock.epoch` | ISO-8601\|null | yes | Non-empty when mode=`"pinned"`, else `null` |
| `limits_conformance.cpu_within` | bool | yes | `observed.cpu_seconds_measured <= limits.cpu_seconds` |
| `limits_conformance.mem_within` | bool | yes | `observed.mem_bytes_peak <= limits.mem_bytes` |
| `limits_conformance.wall_within` | bool | yes | `observed.wall_seconds_measured <= limits.wall_seconds` |
| `limits_conformance.output_within` | bool | yes | `sum(output sizes) <= limits.output_bytes` |
| `reproducible.basis` | str | yes | `"identity-match"`, `"dry-run-plan"`, or `"unverified"` |
| `reproducible.replicate_identity` | sha256\|null | yes | Replicate run's receipt identity or `null` |

## Record output (adds `declared` and `identity`)

| Field | Content-addressed | Notes |
|---|---|---|
| All spec fields | yes | Preserved in canonical form (limits_conformance keys sorted) |
| `reproducible.declared` | yes | Computed from predicate below |
| `identity` | — | SHA-256 of canonical record minus `identity` |

## Declared-true predicate (enforced offline, fail-closed)

`reproducible.declared = True` if and only if **all** hold:

1. All four `limits_conformance` booleans are `True`.
2. `clock.mode == "pinned"`.
3. `seed` is not `null`.
4. `reproducible.replicate_identity == receipt_identity` (both non-null).

Otherwise `declared = False` and `basis` must be `"unverified"` or
`"dry-run-plan"`. Supplying `basis="identity-match"` when the predicate fails
is a hard error. `validate_determinism` independently re-checks via rebuild.

## Wrap-not-extend relationship to `vm-run-receipt.v1`

`vm-determinism.v1` is a sibling schema. The receipt schema is frozen; its
`identity` is a stable content address. This record references that identity
and adds only the reproducibility verdict. `verify_determinism` calls
`vm_receipt.validate_receipt` to validate the referenced receipt and
re-derives `limits_conformance` from `observed` — single source of truth.

## U-V3 dry-run state

`corroborate_compress.py` (U-V3) emits this record with `receipt_identity: null`,
`declared: false`, `basis: "dry-run-plan"`, `replicate_identity: null`.
No `vm-run-receipt.v1` is fabricated for a dry-run.

## API (`lib/vm_plan.py`)

```
class VmDeterminismError(AdapterError)
build_determinism(spec: dict) -> dict          # computes declared + identity
validate_determinism(record: dict) -> None     # no file access
verify_determinism(record: dict, receipt_path: Path) -> None  # reads receipt
# CLI: build --spec S --output O [--overwrite] | validate R | verify --receipt R R
```

# Design: VM spine — determinism-spec (U12) + vm_run dry-run (U3)

Scopes the backlog "VM spine" into two reviewable units, each ≤400 authored
physical touched lines. Both are **offline, no-live-boot, no-payload-exec**.
Grounded in the shipped `vm_receipt.py` (`vm-run-receipt.v1`) and the existing
adapter conventions (`emit_evidence`, `sandbox`, `run_bounded`,
`assert_safe_bind_root`, `_parser()/main(argv)`, fail-closed `AdapterError`).

## Technical Approach

`vm_receipt.py` is DONE and content-addressed: it already pins `limits`
(cpu/mem/wall/output), `vm_pre_snapshot`/`vm_post_snapshot`, input/output
digests, `exit_status`, an allowlisted `environment`, and an `identity` =
SHA-256 of the canonical record minus `identity`+`observed`. U12 adds the
*determinism claim* on top; U3 adds a *dry-run planner* that emits both.

    archive ──► U3 vm_run.plan ──► vm-run-plan.v1.json
                     │  (PlanOnlyExecutor — never boots, never decompresses)
                     ▼
              U12 vm_determinism.build ──► vm-determinism.v1.json
                     │  references ──► vm-run-receipt.v1 (by identity)
                     ▼
              vm_receipt.validate_receipt (imported, not duplicated)

## Architecture Decisions

### Decision: U12 WRAPS vm_receipt, does not extend it
**Choice**: New sibling module `vm_determinism.py` + schema `vm-determinism.v1`
that **references a `vm-run-receipt.v1` by its `identity` hash** and adds only
the determinism-specific fields. It `import`s `vm_receipt` and calls
`validate_receipt` for the referenced receipt.
**Alternatives considered**: (a) add `seed`/`clock`/`reproducible` fields into
`vm-run-receipt.v1`; (b) fork a superset schema.
**Rationale**: `vm-run-receipt.v1` is shipped and its `identity` is a frozen
content-address; adding fields silently changes every existing receipt hash and
breaks `vm-receipt.test.sh`. Wrapping keeps ONE source of truth for run
evidence (inputs/outputs/limits/snapshots live only in the receipt) and lets
the determinism verdict evolve independently.

### Decision: U3 does not fabricate a receipt in dry-run
**Choice**: Dry-run emits `vm-run-plan.v1` (intended argv, caps, mount plan,
real input identity, expected-receipt skeleton) + a `vm-determinism.v1` in the
`declared:false / basis:"dry-run-plan"` state. It does NOT build a
`vm-run-receipt.v1` (that needs a real run's `observed` block and real output
digests).
**Alternatives considered**: emit a placeholder receipt with zeroed observed.
**Rationale**: A receipt asserts a run happened; forging one with fake `observed`
values would be a false evidence record. The plan explicitly records
`outputs: []` + limitation `outputs-unknown-until-live-run`.

### Decision: the live-VM seam is a one-function executor selector
**Choice**: `select_executor(allow_live: bool) -> Executor`. Dry-run returns
`PlanOnlyExecutor` (pure planning, zero subprocess). `--allow-live-boot` is
parsed but, with no `DisposableVmExecutor` present in this unit, hard-refuses
(exit 2, `live boot not implemented in this unit`). The future gated executor
drops in behind exactly this call.
**Rationale**: Makes the seam explicit and testable now; proves the default
path can never execute.

## File Changes

| File | Action | ~Lines | Description |
|------|--------|-------:|-------------|
| `vm_determinism.py` | Create | 180 | U12 producer + validators + CLI |
| `vm-determinism.v1.md` | Create | 70 | U12 spec (house `.v1.md` format) |
| `tests/vm-determinism.test.sh` | Create | 140 | U12 RED-first contract tests |
| **U12 total** | | **390** | ≤400 ✅ |
| `vm_run.py` | Create | 205 | U3 planner, executor seam, CLI |
| `vm-run-plan.v1.md` | Create | 55 | U3 plan spec |
| `tests/vm-run.test.sh` | Create | 135 | U3 RED-first contract tests |
| **U3 total** | | **395** | ≤400 ✅ |

## Interfaces / Contracts

**U12 `vm-determinism.v1`** (all fields deterministic; `identity` over all):
- `schema_version` = `"vm-determinism.v1"`
- `receipt_identity` — `sha256:<64>` of the referenced `vm-run-receipt.v1`
- `seed` — non-negative int (pinned RNG seed) or `null`
- `clock` — `{mode: "pinned"|"host", epoch: <ISO-8601>|null}`
- `limits_conformance` — `{cpu_within, mem_within, wall_within, output_within}`
  booleans (derived: `observed.* <= limits.*` from the referenced receipt)
- `reproducible` — `{declared: bool, basis: "identity-match"|"dry-run-plan"|"unverified", replicate_identity: sha256|null}`
- `identity` — `sha256:` of canonical record minus `identity`

```python
# vm_determinism.py — mirrors vm_receipt's API + CLI shape
def build_determinism(spec: dict) -> dict
def validate_determinism(record: dict) -> None          # no file access
def verify_determinism(record: dict, receipt_path: Path) -> None  # cross-check
# CLI: build --spec --output [--overwrite] | validate REC | verify --receipt R REC
```

**U3 `vm_run.py`**:
```python
class Executor(Protocol):
    def evaluate(self, plan: dict) -> dict: ...          # returns result skeleton
class PlanOnlyExecutor:  # executed=False, outputs=[], no subprocess
def select_executor(allow_live: bool) -> Executor        # THE SEAM
def read_declared_size(archive: Path, codec: str) -> int # gzip ISIZE / xz index — metadata only
def build_plan(archive: Path, caps: dict, codec: str) -> dict   # vm-run-plan.v1
def plan_run(args) -> tuple[dict, dict]                  # (plan, determinism)
# CLI: plan --input ARCHIVE --output DIR --codec {gzip,xz,auto}
#      --cpu-seconds --max-mem-bytes --max-output-bytes --wall-seconds [--allow-live-boot]
```

## U12 Offline Validation Rules

1. `schema_version` exact; `receipt_identity` matches `HASH_RE`.
2. `seed` is int≥0 or `null`; `null` REQUIRES clock/verdict to forbid
   `reproducible.declared:true`.
3. `clock.mode` ∈ {pinned,host}; `pinned` REQUIRES non-empty ISO `epoch`;
   `host` disqualifies reproducibility.
4. `limits_conformance` has exactly the 4 booleans.
5. `reproducible.declared:true` iff **all 4 conformance booleans true AND clock
   pinned AND seed pinned AND `replicate_identity == receipt_identity`**;
   otherwise fail closed.
6. `verify_determinism` reads the receipt file, runs
   `vm_receipt.validate_receipt`, recomputes its identity, asserts it equals
   `receipt_identity`, and re-derives `limits_conformance` from the receipt's
   `observed`/`limits` — mismatch fails closed.

## Security Invariants (enforced offline)

| Invariant | Enforcement |
|---|---|
| No live exec | `PlanOnlyExecutor.evaluate` calls no subprocess; `run_bounded`/`Popen` are never imported into the dry-run path |
| No payload decompression | `read_declared_size` reads only the gzip ISIZE trailer / xz stream footer (metadata), never inflates |
| Disposable-by-construction | plan records tmpfs `/tmp/rsdd/work`, pinned pre-snapshot digest, `--unshare-net`, `--cap-drop ALL`; nothing is booted |
| Bind-safety | mount-plan host paths validated via `assert_safe_bind_root` and the `sandbox()` ro-input rules while BUILDING argv; argv is recorded, never exec'd |
| Bounded resources | caps reuse `vm_receipt._limits` shape (positive ints); plan refused if any cap ≤0 |
| Decompression-bomb bound | mandatory `max_output_bytes` cap; plan REFUSED (exit 2) when `read_declared_size > max_output_bytes` |
| Live seam refusal | `select_executor(True)` raises → CLI exit 2 |

## Testing Strategy (RED first)

**U12** (`vm-determinism.test.sh`, importlib-load pattern like `vm-receipt.test.sh`):
- RED: `build_determinism` byte-identical for identical spec (determinism).
- RED: `declared:true` rejected when any conformance false / clock host / seed
  null / `replicate_identity != receipt_identity`.
- RED: `verify_determinism` fails closed when receipt file identity ≠
  `receipt_identity`, and when `observed.cpu > limits.cpu` but `cpu_within:true`.
- RED: bad digest shape, missing field, unknown `clock.mode`.
- CLI build/validate/verify round-trip + overwrite guard.

**U3** (`vm-run.test.sh`):
- RED: dry-run never executes — monkeypatch `subprocess.Popen` to raise; `plan`
  still exits 0 and writes both JSONs.
- RED: decompression-bomb — gzip whose ISIZE claims > `max_output_bytes` ⇒
  exit 2, no output dir published.
- RED: path/bind safety — `--output` under `/home`/`/etc`/nonexistent parent or
  a colliding dest ⇒ fail closed (reuse adapter output-path guards).
- RED: limit enforcement — any cap ≤0 ⇒ exit 2.
- RED: emitted `vm-determinism.v1.json` has `reproducible.declared:false`,
  `basis:"dry-run-plan"`, `outputs:[]`, limitation `outputs-unknown-until-live-run`.
- RED: `--allow-live-boot` ⇒ exit 2 `live boot not implemented in this unit`.
- GREEN: plan argv contains `--unshare-net`, `--cap-drop ALL`, tmpfs work, and
  the codec decompressor (`gzip -dc` / `xz -dc`) with the output cap.

## Threat Matrix

Applicable — U3 designs a subprocess/mount plan and executable-classification
seam (even though it never executes it).

| Row | Status | Safe/Failure behavior | RED test |
|---|---|---|---|
| Command injection via argv | Applicable | argv is data-only, recorded not exec'd; paths after validation | plan-never-executes |
| Path traversal on `--output` | Applicable | `assert_safe_bind_root` + `require_private` + no-collision | bind-safety |
| Symlinked input / TOCTOU | Applicable | input hashed by fd (`stage_file`/`identity`), O_NOFOLLOW | input-identity |
| Resource exhaustion (bomb) | Applicable | declared-size vs `max_output_bytes`; refuse to plan | bomb-bound |
| Live-boot authorization bypass | Applicable | `select_executor` hard-refuses live | live-refusal |
| Secret leakage in argv/env | Applicable | reuse `vm_receipt._safe_argv/_safe_env` allowlist on recorded argv | secret-argv |

## Migration / Rollout

No migration. Both units are additive files; `vm-run-receipt.v1` is untouched.
Register `vm_determinism.py`/`vm_run.py` in `tool-registry.md` and add both
`.test.sh` to `tests/run-all.sh` in the same slice.

## Build Order & Dependency

**U12 before U3.** U3 imports `vm_determinism` (U12) and `vm_receipt`. Ship U12
(schema + producer + tests) first; U3 consumes its `build_determinism` to emit
the dry-run determinism record.

## Open Questions

- [ ] Confirm gzip ISIZE (mod 2^32, untrusted) is acceptable as a plan-time
  bomb heuristic, or require the xz `--robot --list` index path for xz inputs.
- [ ] `vm-run-plan.v1` — standalone schema (chosen) vs. folding the plan into
  the analysis-manifest `outputs`. Chosen standalone for a clean live-run seam.

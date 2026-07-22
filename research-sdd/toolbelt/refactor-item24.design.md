# Design: Item 24 — Compact/Refactor Adapter Duplication (behavior-preserving)

Scoping design only. No code in this artifact. Baseline: batch1 merged code + U-C1/U-C2/U-C3 dedup already done (`emit_evidence`, venv-bind + run-cap, shared `assert_safe_bind_root`). This plan identifies only what REMAINS.

## 1. Remaining-Duplication Inventory (ranked: value ÷ regression risk)

| # | Duplication | Where (file:symbol) | Copies | Value | Risk |
|---|---|---|---|---|---|
| D1 | `identity()` OSError escape + unbounded hostile-input hashing | `lib/adapter_core.py:identity` (+ same pattern in `stage_file`) | 1 (spine — 20+ callers) | High | Low |
| D2 | Plan-adapter template boilerplate: `PlanOnlyExecutor` + `select_executor`; dry-run `det_spec` dict + `build_determinism` call; gate epilogue (`execute_or_plan` → auth-required → JSON print); `assert_safe_bind_root(realpath(output_dir))` preflight | `vm_run.py`, `trace_plan.py`, `qemu_plan.py`, `detonate_plan.py`, `capture_plan.py`, `emba_plan.py`, `fact_plan.py` — each `select_executor`, `plan_*` epilogue | 7 near-identical (~40–55 lines/file) | High | Low (plan-only code, no subprocess) |
| D3 | `':'/','` Docker-mount delimiter guard | `emba_plan.py:build_plan` (×1), `fact_plan.py` (×2) | 3 | Med-High (security guard — single source of truth) | Low |
| D4 | Charset/leading-dash validators | `emba_plan.py:_validate_tag/_validate_profile`, `fact_plan.py:_validate_tag/_validate_name`, `capture_plan.py:validate_iface` | 5 (same shape, different regex) | Med | Low |
| D5 | pcap magic check + magic constants | `corroborate_pcap.py:_check_magic` + `pcap_flows.py:_check_magic` (byte-identical incl. `_PCAP_MAGIC`/`_PCAPNG_MAGIC`); same fd-magic-read shape in `vm_run.py:_detect_codec` | 2 identical + 1 variant | Med | Low-Med |
| D6 | Manual manifest CLI dance (spec write → create/validate/verify → publish) instead of `emit_evidence` | `corroborate_pcap.py:main`, `pcap_flows.py:main` (~35 lines each) | 2 | Med | **Med** (evidence-schema surface) |
| D7 | SquashFS v4 LE superblock validation | `firmware_carve.py:candidates` (squashfs branch) vs `squashfs_extract.py:find_squashfs_offset` (comment says "mirrors") | 2 | Med | **High** (firmware_carve is deliberately self-contained) |
| D8 | firmware_carve private clones of the spine (`canonical`, `copy_input`≈`stage_file`, `private_fs`≈`require_private`, own `publish`, own bounded runner) | `firmware_carve.py:*` | 1 file | Low | **High** |
| D9 | Output-path pre-flight (`..` check, symlink probe loop, parent perms) | `firmware_carve.py:main`, `squashfs_extract.py:main` | 2 | Low | High |

## 2. The two `identity()` follow-ups — verdicts

**F1 — OSError escape (INCLUDE).** Confirmed at `lib/adapter_core.py:83-108`: only the initial `os.open` is wrapped. `os.fstat(fd)` (lines 88, 102), `os.read` (line 97), and `Path("/proc/self/fd/...").resolve()` (line 93) sit inside the try block unwrapped — an OSError (EIO, proc quirk) escapes past callers' `except AdapterError`. Impact is worst in the 6 plan adapters that wrap ONLY `_file_identity` in `except AdapterError` (`vm_run.py:152`, `trace_plan.py:92`, `qemu_plan.py:108`, `detonate_plan.py:107`, `emba_plan.py:121`, `fact_plan.py:120`) → uncaught traceback, wrong exit code. Batch1 mains catch OSError too, so they mask it. Minimal fix: catch `OSError` inside the block and re-raise as `AdapterError(...) from exc` (never re-wrap AdapterError). Extend the same wrap to `stage_file` for consistency (same pattern, lines 143-166).

**F2 — max_bytes bound (INCLUDE as caller-side threading; core is already done).** The U-V11 note is stale w.r.t. current code: `identity()` ALREADY accepts `max_bytes` with pre-size check + bounded read loop + overflow re-check. The REMAINING gap is that no hostile-input caller passes it: 6 plan adapters call `_file_identity(sample)` unbounded (detonate/qemu/emba/fact/vm_run/trace hash attacker-controlled files), and `corroborate_pcap.py:121` / `pcap_flows.py:156` call `identity(args.input)` unbounded. Fix: per-adapter documented cap constant (suggest 2 GiB for firmware/sample paths) threaded into `_file_identity`. This is a **deliberate, documented fail-closed behavior change** (oversized inputs now exit 2 instead of hanging on a multi-TB sparse file) — flag it in the unit PR body, not silent.

## 3. Recommended Unit Breakdown (supersedes U-C24a/b/c)

The original firmware/pcap/squashfs migration split is the WRONG cut: D7/D8/D9 are high-risk/low-value (see §5). The real dedup value is the identity hardening + plan-adapter template. Recommended units, in order:

| Unit | Scope | Touches | Est. diff | Depends on |
|---|---|---|---|---|
| **U-24.1** | F1 OSError wrap in `identity` (+`stage_file`); RED tests (monkeypatched `os.read`/`os.fstat` raising OSError → AdapterError) | `lib/adapter_core.py`, `tests/adapter-core.test.sh` | ~60–90 lines | — |
| **U-24.2a** | New shared plan helpers in `lib/` (extend `adapter_helpers.py` or new `lib/plan_common.py`): schema-parameterized plan-only executor + `select_executor`, `dry_run_determinism_spec()`, gate-epilogue helper, `reject_mount_delimiters()`, generic `validate_token(value, regex, what)`; migrate 3 adapters (`emba_plan.py`, `fact_plan.py`, `vm_run.py`) + F2 cap threading in those | lib + 3 adapters + their tests | ~250–350 lines | U-24.1 |
| **U-24.2b** | Migrate remaining 4 (`trace_plan.py`, `qemu_plan.py`, `detonate_plan.py`, `capture_plan.py`) to the same helpers + F2 cap threading | 4 adapters + tests | ~200–300 lines | U-24.2a |
| **U-24.3** | pcap pair: shared `check_magic(path, magics, context)` + shared magic constants in lib; F2 cap on `identity(args.input)`; `emit_evidence` migration ONLY IF golden manifest/evidence output proven byte-identical — otherwise keep the manual dance and record why | `corroborate_pcap.py`, `pcap_flows.py`, lib, 2 test suites | ~120–200 lines | U-24.1 |

All units ≤400 changed lines. `Decision needed before apply: Yes` (chained PRs). `Chained PRs recommended: Yes`. `400-line budget risk: Medium` (U-24.2a is the one to watch — drop `vm_run.py` to 2b if it overruns).

## 4. Security invariants + verification per unit

| Unit | Invariants that must hold | Verification |
|---|---|---|
| U-24.1 | O_NOFOLLOW open; regular-file check; TOCTOU pre/post fstat compare; bounded-read overflow check; error TYPE only widens callers' catch (OSError→AdapterError), never narrows | `tests/adapter-core.test.sh` green unchanged; new RED tests for injected OSError; grep-proof no error-string change for existing paths |
| U-24.2a/b | Gate seam semantics identical (`select_executor` returns None on live; exit 3 on authorization-required; exit 2 on all errors); delimiter guard rejects same inputs with same exit; charset regexes byte-identical per adapter (tag vs profile vs iface); `assert_safe_bind_root` still called on realpath(output) BEFORE any write; plans still written before gate routing; per-adapter stderr prefixes preserved | All 7 `tests/*-plan.test.sh` + `vm-run.test.sh` green with zero test edits (tests pin the CLI behavior); side-by-side diff proving moved guard bodies identical; F2 cap change called out as the ONLY behavioral delta |
| U-24.3 | Magic sets byte-identical; O_NOFOLLOW fd read preserved; per-adapter error class (`PcapError`/`PcapFlowsError`) and message shape preserved; evidence/manifest JSON byte-identical (golden compare) or migration aborted | `tests/corroborate-pcap.test.sh` + `tests/pcap-flows.test.sh` green unchanged; golden-output diff for D6 before accepting the emit_evidence swap |

Global rule: NO existing test file is modified in the same commit that moves a guard (except adding new cases). A moved guard is proven identical by unchanged tests + textual diff of the extracted body.

## 5. Explicitly NOT worth refactoring (leave merged code alone)

- **D8 — firmware_carve → adapter_core migration** (was U-C24a): deliberately self-contained worker-re-exec architecture; its local variants differ on purpose in both directions (`trusted_bwrap` root-owned check is STRICTER than `executable`; `private_fs` is weaker than `require_private`; `publish` has distinct `PublishedUnsynced`/exit-3 durability semantics). Migration would change error strings, exit semantics, and guard strength on the highest-risk merged adapter. Churn > benefit.
- **D7 — shared SquashFS superblock validator**: extracting it forces firmware_carve to import `lib/` (breaks self-containment) or leaves an asymmetric half-share. Cross-reference comments already exist. Keep both copies; revisit only if a third consumer appears.
- **D9 — output pre-flight dance** (firmware_carve/squashfs): subtle, tested, tied to each adapter's publish model. Leave.
- **sys.path bootstrap block** (7 copies): must execute before `lib` imports — structurally unsharable. Leave.
- **squashfs_extract further migration** (was U-C24c): it already uses `adapter_core` for everything sensible; what remains is D7/D9. No unit.
- **D6 emit_evidence migration**: conditional inside U-24.3, not a standalone unit — abort on any golden-output mismatch.

## Threat Matrix (applicability)

Per `references/threat-matrix.md`: Documentation-like paths — N/A (no executable-file classification changed). Git repository selection / Commit state / Push state / PR commands — N/A (no VCS/PR automation touched). The refactor moves subprocess-ADJACENT guard code without changing any spawned command; the real boundaries are the per-unit invariants in §4, which propagate unchanged to tasks and RED tests.

## Open Questions

- [ ] F2 cap default (2 GiB proposed) — confirm against largest legitimate firmware corpus sample before U-24.2a.
- [ ] `lib/plan_common.py` vs growing `adapter_helpers.py` — decide at tasks time; helpers file is already large (~650+ lines), a new module keeps review diffs clean (leaning `plan_common.py`).

## Migration / Rollout

Chained PRs in unit order (24.1 → 24.2a → 24.2b → 24.3), each independently revertable; no data migration.

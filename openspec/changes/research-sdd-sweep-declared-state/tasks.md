# Tasks: Declared-State Sentinel for SessionStart Sweep/Verify Instruments

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~120–135 |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | Single PR |
| Delivery strategy | auto-chain |
| Chain strategy | stacked-to-main |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: stacked-to-main
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | Sentinel emit + hook silence (all 8 files) | PR 1 | `bash research-sdd/toolbelt/tests/run-all.sh` | All 8 test files via run-all.sh | Revert sentinel echo + hook state block; 25+ RC=0 assertions unaffected |

## Phase 0: Preflight — Dependency Gating

- [ ] 0.1 Create branch from post-#376 main. Run `grep 'Ledger consistent' research-sdd/toolbelt/sweep-breakthroughs.sh`; confirm match before any edits. Block if absent.

## Phase 1: sweep-retros.sh Sentinel (Strict TDD)

- [ ] 1.1 [RED] `sweep-retros.test.sh`: add 3 stubs — (a) clean fixture → last stdout line = `RSDD-STATE: clean`; (b) missing_retro=1 fixture → `RSDD-STATE: attention`; (c) skipped>0, findings=0 → `RSDD-STATE: partial`. Run suite; confirm RED (sentinel absent).
- [ ] 1.2 [GREEN] `sweep-retros.sh`: add `missing_retro=0` before retro loop; increment `missing_retro` at ~line 237 (MISSING-RETRO print); set `FINDINGS=$((pending + missing_retro))`; append sentinel block (if/elif/else + bare echo) after ~line 243. Confirm 3 stubs GREEN.
- [ ] 1.3 [TEETH] Add tooth in `sweep-retros.test.sh`: sed drops `missing_retro` term from FINDINGS expression → attention fixture → assert sentinel = `RSDD-STATE: clean` → RED. Verify sed pattern literally matches written source (no silent no-op).

## Phase 2: sweep-audits.sh Sentinel (Strict TDD)

- [ ] 2.1 [RED] `sweep-audits.test.sh`: stubs for clean / attention (pending>0) / partial (skipped>0, findings=0). Confirm RED.
- [ ] 2.2 [GREEN] `sweep-audits.sh`: set `FINDINGS=$((pending))`; append sentinel block after ~line 130. Confirm GREEN.
- [ ] 2.3 [TEETH] Tooth: sed zeroes `pending` before FINDINGS assignment → attention fixture flips to clean → RED. Verify sed matches source.

## Phase 3: sweep-breakthroughs.sh Sentinel (Strict TDD)

- [ ] 3.1 [RED] `sweep-breakthroughs.test.sh`: stubs for clean / attention (warn_unindexed>0) / partial (skipped>0, findings=0). Confirm RED.
- [ ] 3.2 [GREEN] `sweep-breakthroughs.sh`: set `FINDINGS=$((warn_unindexed + warn_drift))`; append sentinel block AFTER the post-#376 "Ledger consistent" line (~line 180). Confirm GREEN.
- [ ] 3.3 [TEETH] Tooth: sed drops `warn_drift` from FINDINGS → drift-only attention fixture → RED. Verify sed matches source.

## Phase 4: verify-registry.sh Sentinel (Strict TDD)

- [ ] 4.1 [RED] `verify-registry.test.sh`: stubs for clean / attention (rowlint>0) / partial (skipped>0, findings=0). Assert sentinel is unconditionally LAST stdout line. Confirm RED.
- [ ] 4.2 [GREEN] `verify-registry.sh`: set `FINDINGS=$((drift + retro_drift + unresolved + rowlint))`; append sentinel block after summary (~line 448), BEFORE `exit 0` (~line 451). Use bare echo (pipefail-safe); all vars pre-assigned on all reaching paths (set -u safe). WARN-only early exit at ~line 73 emits NO sentinel — do not add one (missing → hook loud = §7-correct). Confirm GREEN.
- [ ] 4.3 [TEETH] Tooth: sed drops `rowlint` from FINDINGS → rowlint-only attention fixture → RED. Verify sed matches source.

## Phase 5: Hooks — All 4 (Strict TDD)

- [ ] 5.1 [RED] In each hook test file (`sweep-retros-hook.test.sh`, `sweep-audits-hook.test.sh`, `sweep-breakthroughs-hook.test.sh`, `verify-registry-hook.test.sh`): add 3 cases each — (a) clean sentinel in output → assert NO output to session; (b) attention sentinel → assert output emitted; (c) output contains no `RSDD-STATE:` line → assert output emitted (§7 anti-silent-zero). Confirm all 12 new stubs RED.
- [ ] 5.2 [GREEN] In each hook script (`sweep-retros-hook.sh`, `sweep-audits-hook.sh`, `sweep-breakthroughs-hook.sh`, `verify-registry-hook.sh`): insert AFTER rc≠0 block (~line 18), BEFORE existing emit (~line 20): `state="$(printf '%s\n' "$out" | grep '^RSDD-STATE:' | tail -1 | cut -d' ' -f2)"` then `if [ "${state:-}" = "clean" ]; then exit 0; fi`. Hook exits 0 on every path. Confirm all 12 stubs GREEN.
- [ ] 5.3 [TEETH] Add 3 mutation teeth per hook (12 teeth total): (a) mutate `= "clean"` → `= "NEVER"` in guard → clean case not silent → RED; (b) mutate `${state:-}` → `${state:-clean}` → missing-sentinel silenced → RED; (c) comment out the script's sentinel echo → hook must go loud → RED. Verify each sed pattern literally matches written source before asserting bite.

## Phase 6: Quality Gates

- [ ] 6.1 Run `shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh`; assert zero warnings across all files.
- [ ] 6.2 Run `bash research-sdd/toolbelt/tests/run-all.sh` on a quiet tree; assert zero failures. Then run `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth`; assert all mutation controls go RED.

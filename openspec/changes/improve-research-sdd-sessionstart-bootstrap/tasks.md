# Tasks: Improve Research-SDD SessionStart Bootstrap

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | PR #1 ~167 lines; PR #2 ~120 lines |
| 400-line budget risk | Low |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 (silence guards + wording + ledger sentence + tests) → PR 2 (absent/empty exit-code contract) |
| Delivery strategy | auto-chain |
| Chain strategy | stacked-to-main |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | D1 silence guards + D2 ledger sentence + D3 wording fixes + test updates | PR 1 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | N/A — kit-internal shell only, no live target | Revert 10 files; no state change |
| 2 | D4 absent/empty/no-match exit-code contract (§7) across 4 scripts + hook mapping | PR 2 | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | N/A — fixture TARGETS.md sufficient | Revert 8 files; no state change |

---

## PR #1 — Silence Guards, Wording, Ledger Sentence (~167 lines)

### Phase 1: Tests — RED First (§4 TDD)

- [ ] 1.1 `research-sdd/toolbelt/tests/sweep-retros-hook.test.sh`: flip test 4 (rc=0, 0-pending Summary → output EMPTY); add test 5 (rc=0, nonzero-pending Summary → header present); add tooth B (mutate `&& exit 0` → `&& true` → test 4 must go RED). Spec: silence-on-clean + emit-on-findings.
- [ ] 1.2 `research-sdd/toolbelt/tests/sweep-audits-hook.test.sh`: same pattern as 1.1 for `pending` count.
- [ ] 1.3 `research-sdd/toolbelt/tests/sweep-breakthroughs-hook.test.sh`: same pattern; clean signal = `unindexed=0, drifted=0`.
- [ ] 1.4 `research-sdd/toolbelt/tests/verify-registry-hook.test.sh`: same pattern; clean signal = all 4 Summary counts = 0 (drift, retro_drift, unresolvable, oversized).
- [ ] 1.5 Create `research-sdd/toolbelt/tests/verify-kit-clean-hook.test.sh`: case 3 (rc=0 → silent), case 4 (rc=1 → "KIT is NOT clean"), case 5 (rc=2 → "could not run", distinct from case 4); tooth A (`[ "$rc" = 0 ] && exit 0` → `&& true` → case 3 RED); tooth B (`if [ "$rc" = 1 ]` → `if true` → case 5 emits dirty banner → RED).
- [ ] 1.6 Run each updated/new test file → confirm each fails for the correct reason (hook still always-emits, or new file not found); not a crash or missing-SUT failure.

### Phase 2: D3 Wording Fixes

- [ ] 2.1 `research-sdd/toolbelt/sweep-retros-hook.sh:10`: change "retros sweep" → "retro sweep" (matches success path header `:22`). Spec: neutral-header singular.
- [ ] 2.2 `research-sdd/toolbelt/verify-registry-hook.sh`: change "registry drift" → "registry check" at jq path `:21` and printf fallback `:25` (matches failure header `:10`; "drift" wrongly implies findings on clean). Spec: neutral-header registry.

### Phase 3: D2 Ledger Consistent Sentence

- [ ] 3.1 `research-sdd/toolbelt/sweep-breakthroughs.sh`: insert clean sentence after Summary echo (`:171`), before `warn_unindexed>0` block (`:175`): `if [ "$warn_unindexed" -eq 0 ] && [ "$warn_drift" -eq 0 ]; then echo "Ledger consistent — all tagged breakthroughs indexed, no drift."; fi`. Parallel to `sweep-retros.sh:176` / `verify-registry.sh:444`. Spec: ledger-consistent positive sentence.

### Phase 4: D1 Silence Guards

Guards go AFTER `if [ "$rc" -ne 0 ]` block (ends `:18`), BEFORE success emit (`:20`). Pattern mirrors `sweep-tools-hook.sh:22-42`. Missing Summary → LOUD banner (anti-silent-zero); counts-all-zero → `exit 0` silent.

- [ ] 4.1 `research-sdd/toolbelt/sweep-retros-hook.sh`: extract `Summary:` line; empty → LOUD missing-Summary banner + `exit 0`; parse `pending` count via `grep -oE`; `[ "${pending:-0}" = "0" ] && exit 0`. Spec: silence-on-clean + operational-failure stays loud.
- [ ] 4.2 `research-sdd/toolbelt/sweep-audits-hook.sh`: same for `pending` count.
- [ ] 4.3 `research-sdd/toolbelt/sweep-breakthroughs-hook.sh`: parse `unindexed` + `drifted` counts; both 0 → `exit 0`. Guard decoupled from D2 sentence (counts not sentence).
- [ ] 4.4 `research-sdd/toolbelt/verify-registry-hook.sh`: parse ALL FOUR counts from Summary line `verify-registry.sh:439` (drift, retro_drift, unresolvable, oversized/rowlint); all 0 → `exit 0`. MUST NOT use `grep 'Registry consistent'` — that sentence omits rowlint (`:443-444` gates on drift/retro_drift/unresolved only), so a rowlint>0 run would be silenced — §7 false-negative hole. Count-parse is the mandatory design choice.
- [ ] 4.5 Run all 4 hook tests: test 4 GREEN (clean → silent), test 5 GREEN (findings → header). Confirm tooth B → RED (silence guard mutated → test 4 fails). Confirm test 3 (operational banner) UNCHANGED.

### Phase 5: PR #1 Gates (quiet tree — wait for all writes to finish)

- [ ] 5.1 `shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh` → zero warnings on all touched scripts.
- [ ] 5.2 `bash research-sdd/toolbelt/tests/run-all.sh` full suite on a quiet tree → all suites pass; no zero-coverage run.
- [ ] 5.3 `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` → all mutation controls RED (tooth A kept + tooth B new for each of the 4 hook tests; both teeth for `verify-kit-clean-hook.test.sh`).

---

## PR #2 — Absent/Empty Exit-Code Contract (§7, ~120 lines) [chained on PR #1 branch]

### Phase 6: Tests — RED First

- [ ] 6.1 Update each of 4 hook test files: add 3 input-state assertions per hook — (a) absent-TARGETS → exit 3 + banner "TARGETS.md not found"; (b) broken-helper → exit 4 + banner; (c) empty-rows → "no targets registered yet" distinct from absent; assert all 3 states distinguishable. Spec: absent-input vs empty-input distinction.
- [ ] 6.2 Run all new tests → confirm they fail (underlying scripts still conflate exit 1 for absent vs empty paths).

### Phase 7: Underlying Script Exit-Code Contract

- [ ] 7.1 `research-sdd/toolbelt/sweep-retros.sh`: absent/unreadable TARGETS.md → `exit 3` + explicit banner; broken lib helper → `exit 4` + banner; 0 rows present → "no targets registered yet" + distinct exit (0 or 2). Disambiguates `:42-45` (absent) vs `:54-58` (empty).
- [ ] 7.2 `research-sdd/toolbelt/sweep-audits.sh`: same 3-state contract; same exit code map.
- [ ] 7.3 `research-sdd/toolbelt/sweep-breakthroughs.sh`: same 3-state contract; additive to D2 (D2 ledger sentence from PR #1 unchanged).
- [ ] 7.4 `research-sdd/toolbelt/verify-registry.sh`: same; preserve existing WARN-only finding behavior (operational-failure is exit≠0, findings are WARN-only per §8).

### Phase 8: Hook Exit-Code Mapping

- [ ] 8.1 `research-sdd/toolbelt/sweep-retros-hook.sh`: map exit 3 → "could not run — TARGETS.md not found"; exit 4 → "could not run — TARGETS.md/helper broken"; distinct from existing rc≠0 path.
- [ ] 8.2 `research-sdd/toolbelt/sweep-audits-hook.sh`: same mapping.
- [ ] 8.3 `research-sdd/toolbelt/sweep-breakthroughs-hook.sh`: same mapping.
- [ ] 8.4 `research-sdd/toolbelt/verify-registry-hook.sh`: same mapping; confirm silence guard (PR #1) unaffected.

### Phase 9: PR #2 Gates (quiet tree)

- [ ] 9.1 Run all updated hook test files → all 3 input-state cases GREEN per hook.
- [ ] 9.2 `shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh` → zero warnings on all PR #2 touched scripts.
- [ ] 9.3 `bash research-sdd/toolbelt/tests/run-all.sh` quiet tree → all suites pass.
- [ ] 9.4 `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` → all mutation controls RED.

---

## Boundary Constraints

- Do NOT touch: `research-sdd/toolbelt/research-sdd-init.sh`, `research-sdd/PROMPT-LOOP.md`, `research-sdd/toolbelt/templates/*`, `research-sdd/toolbelt/research-sdd-status.sh` (disjoint from peer lane `improve-research-sdd-target-onboarding`).
- Do NOT touch: `research-sdd/toolbelt/sweep-tools-hook.sh` (reference idiom only; already correct).
- Doctrine inviolable: §7 absent/empty/no-match distinguishable; silence only on genuine-clean; operational failure loud + exit≠0; propose-never-apply.

## Parallel / Sequential Analysis

- Tasks 1.1–1.5 (test writes) are **parallel** — each touches a disjoint test file.
- Tasks 2.1, 2.2, 3.1 are **parallel** — disjoint source files.
- Tasks 4.1–4.4 are **parallel** — disjoint hook files.
- Task 4.5 (run tests) is **sequential** after 4.1–4.4 and 2.1–2.2.
- Phase 5 gates are **sequential** after all Phase 1–4 writes finish (quiet tree required).
- PR #2 phases 6–9 are **sequential** after PR #1 is merged (stacked-to-main).

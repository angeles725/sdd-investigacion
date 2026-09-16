# Tasks: Improve Research-SDD Target Onboarding

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~40 (≤15 init.sh + ≤25 test.sh) |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | Single PR |
| Delivery strategy | auto-chain |
| Chain strategy | N/A — single PR |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: size-exception
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | All 3 items in 2 frozen files | PR 1 | `bash research-sdd/toolbelt/tests/research-sdd-init.test.sh` | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` | `git revert` restores prior wording + suite |

---

## Phase 1: Test Infrastructure

- [ ] 1.1 In `research-sdd/toolbelt/tests/research-sdd-init.test.sh`: add a stdout-capture pattern — for each new assertion group, run SUT with stdout redirected to `"$TMP/<label>.out"` so `assert_grep` can assert against the file (current helper already takes a file path; no new helper needed, only a new invocation pattern).
- [ ] 1.2 In `research-sdd/toolbelt/tests/research-sdd-init.test.sh`: add a dynamic already-git fixture block — `d="$TMP/already-git"; mkdir -p "$d"; git -C "$d" init -q` — placed under `$TMP` only, never under `tests/fixtures/` or a live target directory.

> Tasks 1.1 and 1.2 are independent and may be written together.

---

## Phase 2: RED — Failing Assertions (all items)

- [ ] 2.1 RED (Item 1 — cross-refs): In `research-sdd-init.test.sh`, capture a no-prefix SUT run to `"$TMP/xref.out"` and add three `assert_grep` calls using the CLOSED-PAREN form so they do not false-match step 2's existing text: assert `"PROMPT-LOOP §b)"` present; assert `"§e)"` present; assert `"§c follow-up)"` present. Run `bash research-sdd/toolbelt/tests/research-sdd-init.test.sh` and confirm these three assertions FAIL.
- [ ] 2.2 RED (Item 1 — step-5 else-branch): Capture a no-prefix run to `"$TMP/nopfx.out"` and a `--prefix foo` run to `"$TMP/pfx.out"`. Assert: `"no --prefix given"` present in no-prefix out; `"5. Block files use the prefix:"` absent in no-prefix out; `"5. Block files use the prefix: foo-blockN.md"` present in prefix out; `"no --prefix given"` absent in prefix out. Run and confirm all four FAIL.
- [ ] 2.3 RED (Item 2 — already-git message): Using the already-git fixture from 1.2, run SUT to `"$TMP/agit.out"`. Assert: `"corpus files land untracked"` present; `".claude/ hook is gitignored"` present; `"git add --force"` present. Run and confirm all three FAIL.
- [ ] 2.4 RED (Item 3 — next-step): Capture any valid run to `"$TMP/nextstep.out"`. Assert: `"research-sdd-status.sh"` present; `"BOOTSTRAP"` present. Run and confirm both FAIL.

> Tasks 2.1–2.4 are independent and may be written together. All four must fail before proceeding.

---

## Phase 3: GREEN — Implement `research-sdd-init.sh` Changes

- [ ] 3.1 GREEN (Item 1a — cross-refs): In `research-sdd/toolbelt/research-sdd-init.sh`, append `(PROMPT-LOOP §b)` to the step-1 echo (line ~151); append `(§e)` before the period on the step-3 echo (line ~154); change the step-4 label to include `(§c follow-up):` (line ~155). Step 2's existing `(PROMPT-LOOP §b/§b2)` must NOT be touched.
- [ ] 3.2 GREEN (Item 1b — step-5 else-branch): Convert line ~158 `[ -n "$prefix" ] && echo ...` to `if [ -n "$prefix" ]; then echo "  5. Block files use the prefix: ${prefix}-blockN.md"; else echo "  (no --prefix given — step 5, block-file prefix, is skipped; pass --prefix to enable it)"; fi`.
- [ ] 3.3 GREEN (Item 2 — already-git message): Convert lines ~146-147 `[ "$git_did_init" = 1 ] && echo … || echo …` to `if [ "$git_did_init" = 1 ]; then echo "  git    : initialized a new repo in the target"; else echo "  git    : target is ALREADY under git — corpus files land untracked (git add as needed)"; echo "           the .claude/ hook is gitignored (init appended .claude/ to .gitignore) — git add --force to track it, or leave it ignored"; fi`. The `git_did_init=1` message is preserved verbatim.
- [ ] 3.4 GREEN (Item 3 — next-step): Immediately before the terminal `echo "== done =="` (line ~159), insert: `echo; echo "NEXT: run $KIT/toolbelt/research-sdd-status.sh $target — it reports BOOTSTRAP until the follow-ups above are done."; echo "  mental model: you now have a VALID-but-EMPTY corpus; the JUDGMENT follow-ups turn it into a real research target."`. The terminal `echo "== done =="` remains unchanged.
- [ ] 3.5 VERIFY GREEN: Run `bash research-sdd/toolbelt/tests/research-sdd-init.test.sh` (without `--prove-teeth`). All previously failing assertions from Phase 2 must now PASS; no existing tests may regress.

> Tasks 3.1–3.4 modify distinct echo lines and may be written together. Task 3.5 requires 3.1–3.4 complete.

---

## Phase 4: TEETH — Mutation Controls (`--prove-teeth`)

- [ ] 4.1 TEETH (M1 — cross-ref): In the `--prove-teeth` block of `research-sdd-init.test.sh`, add a mutant that uses `awk` to strip `(PROMPT-LOOP §b)` from the step-1 echo; run the mutant and assert that `"PROMPT-LOOP §b)"` is absent from stdout. Confirm the control goes red.
- [ ] 4.2 TEETH (M2 — step-5): Add a mutant that uses `awk` to unconditionally print step 5 (removes the prefix `if` condition); run no-prefix against the mutant and assert that `"5. Block files use the prefix:"` IS present — i.e., the no-prefix ABSENT assertion from 2.2 flips red. Confirm the control goes red.
- [ ] 4.3 TEETH (M3 — already-git): Add a mutant that uses `awk` to revert the else-branch to the original single-line message (removing the untracked/gitignored split); run the already-git fixture against the mutant and assert that `"gitignored"` or `"--force"` is absent. Confirm the control goes red.
- [ ] 4.4 TEETH (M4 — next-step): Add a mutant that uses `awk` to delete the NEXT echo line; assert that `"research-sdd-status.sh"` is absent from stdout. Confirm the control goes red.
- [ ] 4.5 VERIFY TEETH: Run `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth`. All four new mutation controls must go red; no existing teeth must regress.

> Tasks 4.1–4.4 each produce independent `--prove-teeth` blocks and may be written together. Task 4.5 requires 4.1–4.4 complete.

---

## Spec Traceability

| Requirement | Tasks |
|-------------|-------|
| PROMPT-LOOP cross-refs on steps 1, 3, 4 | 2.1, 3.1, 4.1 |
| Conditional step-5 transparency (else-branch) | 2.2, 3.2, 4.2 |
| Accurate already-git message (untracked vs gitignored) | 1.2, 2.3, 3.3, 4.3 |
| End-of-report next-step + mental model | 2.4, 3.4, 4.4 |
| Stdout assertions use file capture (not file contents) | 1.1 |
| Already-git fixture in $TMP (not tests/fixtures/) | 1.2 |
| One `--prove-teeth` mutant per new assertion group | 4.1–4.4 |
| No changes to PROMPT-LOOP.md, sweep-*.sh, verify-*.sh, *-hook.sh, status.sh, templates/ | all tasks (frozen scope) |

---

## Review Workload Forecast

Estimated authored changed lines: ~40 (≤15 in `research-sdd-init.sh`, ≤25 in `research-sdd-init.test.sh`). Well within the 400-line budget. No chaining required.

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: size-exception
400-line budget risk: Low

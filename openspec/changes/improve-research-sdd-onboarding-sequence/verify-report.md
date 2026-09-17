# Verify Report: improve-research-sdd-onboarding-sequence

**Change**: improve-research-sdd-onboarding-sequence
**Worktree branch**: worktree-onboarding-seq (HEAD ff00de2, rebased onto main 26332ba)
**Verification date**: 2026-08-26
**Mode**: Static contract validation + focused test run

---

## Completeness Table

| Artifact | Status |
|---|---|
| Spec (obs 7564) | Retrieved |
| Design (obs 7563) | Retrieved |
| Tasks (obs 7569) | Retrieved |
| Apply-progress (obs 7581) | Retrieved |
| Tasks complete | 13/13 [x] |

---

## Scope Check

`git diff origin/main --name-only` returns exactly 2 files:

- `research-sdd/toolbelt/research-sdd-init.sh`
- `research-sdd/toolbelt/tests/research-sdd-init.test.sh`

No PROMPT-LOOP.md, no sweep/verify/hook/status/templates file. **PASS**

---

## Spec Compliance Matrix

### Requirement 1: CONFIRM/THEN Split in JUDGMENT Follow-up Block

| Scenario | Evidence | Status |
|---|---|---|
| CONFIRM header present before items 1-2 | `research-sdd-init.sh:155` — `-- CONFIRM these are done — they belong at PROMPT-LOOP §b/§b2, BEFORE this scaffold (do them NOW if skipped) --` | PASS |
| THEN header present before items 3-5 | `research-sdd-init.sh:159` — `-- THEN do next (post-scaffold) --` | PASS |
| JUDGMENT/NOT mechanizable framing preserved | `research-sdd-init.sh:154` — `-- JUDGMENT follow-ups (NOT mechanizable) --` still present | PASS |
| Item order 1→2→3 preserved under split | Static read: REGISTER (156) → CLASSIFY (158) → SEED (160) in order | PASS |

### Requirement 2: §18 Sweep Consequence on Item 1

| Scenario | Evidence | Status |
|---|---|---|
| Consequence clause present (§18 signal) | `research-sdd-init.sh:157` — `     — else sweep-retros.sh cannot see its retros/ (§18).` VERBATIM | PASS |
| Spec scenario: contains "§18" OR ("invisible"+"sweep") | Line 157 contains `(§18)` — satisfies OR-condition | PASS |
| Mutation control M7 (prove-teeth for consequence) | **NOT IMPLEMENTED** — dropped per orchestrator scope-trim | WARNING |

### Requirement 3: Unit-1 Signals Non-Regression

| Token | File:Line | Status |
|---|---|---|
| `(PROMPT-LOOP §b)` on item 1 | `research-sdd-init.sh:156` | PASS |
| `(PROMPT-LOOP §b/§b2)` on item 2 | `research-sdd-init.sh:158` | PASS |
| `(§e)` on item 3 | `research-sdd-init.sh:160` | PASS |
| `(§c follow-up)` on item 4 | `research-sdd-init.sh:161` | PASS |
| no-prefix step-5 if/else | `research-sdd-init.sh:164-168` | PASS |
| NEXT + mental-model lines | `research-sdd-init.sh:170-171` | PASS |

### Requirement 4: PROMPT-LOOP.md Untouched

| Scenario | Evidence | Status |
|---|---|---|
| `git diff origin/main -- research-sdd/PROMPT-LOOP.md` empty | Output: 0 bytes | PASS |

---

## Test Evidence

**Command**: `bash research-sdd/toolbelt/tests/research-sdd-init.test.sh`
**Exit code**: 0
**Result**: 64 passed · 0 failed

### Assertion Coverage

| Assertion | Test line | Result |
|---|---|---|
| `reframe: CONFIRM group header present` | test:185 | PASS |
| `reframe: THEN group header present` | test:186 | PASS |
| `reframe: item-1 consequence unchanged` (`cannot see its retros/`) | test:187 | PASS |
| `reframe: item-2 cross-ref unchanged` (`PROMPT-LOOP §b/§b2`) | test:188 | PASS (extra guard not in tasks spec — bonus coverage) |

### Mutation Teeth (--prove-teeth block)

| Mutant | Build-check | Target | Status |
|---|---|---|---|
| M5: strip CONFIRM header | `grep -qF 'CONFIRM these are done' "$m5_mutant"` guards against silent no-op | `CONFIRM these are done` absent from mutant stdout | IMPLEMENTED (test:297-310) |
| M6: strip THEN header | `grep -qF 'THEN do next (post-scaffold)' "$m6_mutant"` | `THEN do next (post-scaffold)` absent from mutant stdout | IMPLEMENTED (test:314-327) |
| M7: strip consequence clause | — | `§18`/`invisible`/`sweep` absent from stdout | NOT IMPLEMENTED — orchestrator-authorized scope trim |

---

## Design Coherence

| Decision | Design says | Implementation | Status |
|---|---|---|---|
| Replace line 154 with CONFIRM header | Replace single flat header | Old header kept at line 154 AND new CONFIRM header added at line 155 | COMPLIANT — verify spec explicitly requires JUDGMENT framing preserved |
| Reword line 156 consequence | `— else its retros/ is invisible to the §18 sweep.` | Preserved VERBATIM as `— else sweep-retros.sh cannot see its retros/ (§18).` | AUTHORIZED DEVIATION — orchestrator scope-trim; verify spec requires verbatim preservation |
| M7 consequence mutant | Implement M7 alongside M5 and M6 | M7 not implemented | AUTHORIZED DEVIATION |

---

## Issues

### WARNINGS (1)

**W1 — Spec mutation control M7 not implemented**
- Spec requires: "Each new assertion MUST fail when its corresponding mutant runs" (mutation controls table, row 3: Item-1 consequence present)
- Implementation: Assertion `reframe: item-1 consequence unchanged` exists at `test:187` but has no `--prove-teeth` mutant
- Authorization: Orchestrator explicitly authorized dropping M7 with the line-156 reword; recorded in apply-progress
- Risk: The consequence assertion (`cannot see its retros/`) has no teeth proof. If line 157 were inadvertently stripped, the assertion would go red — but the absence of a mutant means the prove-teeth suite never exercises that failure path
- Remediation: Add M7 in a follow-up: `awk '/cannot see its retros\// { next } { print }' "$SUT" > "$m7_mutant"` + build-check + assert `§18` absent from stdout

### SUGGESTIONS (1)

**S1 — Item-2 cross-ref guard is undocumented bonus coverage**
- Test line 188 `reframe: item-2 cross-ref unchanged` is not listed in tasks spec but is present and correct
- No action required; document it in a future tasks update if desired

---

## Final Verdict

**PASS WITH WARNINGS**

- CRITICAL: 0
- WARNING: 1 (M7 mutation control absent; orchestrator-authorized; consequence assertion exists but untested for teeth)
- SUGGESTION: 1 (document bonus item-2 cross-ref guard in tasks)

All 13 tasks complete. Scope frozen to 2 files. Test suite: 64 passed, 0 failed. PROMPT-LOOP.md untouched. All spec requirements satisfied. Single authorized deviation: M7 mutant dropped with consequence-reword scope trim.

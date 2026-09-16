# Tasks: Research-SDD Journal Mode (instant capture → §18 consolidate)

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~60–90 (prose only) |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | Single PR |
| Delivery strategy | ask-on-risk |
| Chain strategy | N/A |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: stacked-to-main
400-line budget risk: Low

**No runtime gate** — zero tooling; verification is doc↔spec readback only. No `*.test.sh` required.

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | All three doc edits + readback | PR 1 | Doc↔spec readback (manual cross-read) | N/A — doctrine prose, no executable | Revert merge commit; §18 returns to blind-recall wording independently |

---

## Phase 1: METHODOLOGY.md §18 — Journal Format + Consolidation Doctrine

Target file: `research-sdd/METHODOLOGY.md`
Spec refs: journal-capture §Entry Format, §Instant Capture Discipline, §Substrate Justification, §Category Taxonomy; retro-flow §Consolidate-Curate Mode, §Deduplication, §Promotion Gate, §Terminal Retro Retained.

- [x] 1.1 In `research-sdd/METHODOLOGY.md` §18, prescribe the journal entry format: one line per entry, ISO 8601 date prefix, one category tag from `{improvement, defect, tool-idea, algorithm-idea, formula-idea}`, English description; multi-line prose is non-conforming.
- [x] 1.2 In `research-sdd/METHODOLOGY.md` §18, prescribe the capture substrate: use `mem_save` with `topic_key: research/<target>/journal`, `session_id: <loop>`, `type` one of `bugfix|discovery|decision|pattern`, `title: <class>: <insight>`; build a dedicated command ONLY after a run measures a concrete gap the convention cannot cover (§6/§7 measure-before-build; record the measurement in that run's retro).
- [x] 1.3 In `research-sdd/METHODOLOGY.md` §18, redefine the terminal retro from blind end-of-loop recall to: `mem_search` this session's journal entries → dedup/collapse near-duplicates → curate → promote worthwhile entries to `## Proposed kit deltas`; retain §18 as the mandatory promotion gate.
- [x] 1.4 In `research-sdd/METHODOLOGY.md` §18, add explicit handling for absent-journal runs: §18 fires and explicitly notes "no journal entries" — it does not silently pass or skip. Retain the §18 honesty clause verbatim.
- [x] 1.5 In `research-sdd/METHODOLOGY.md` §18, add cross-reference note on open questions: (a) Engram `session_id` reliability when a target spans multiple sessions; (b) retro agent `mem_search` scope (session journal only, not whole-project memory). Record these as the measured criteria before any tooling is built.

---

## Phase 2: PROMPT-LOOP.md — Instant Capture Step + Terminal Consolidation

Target file: `research-sdd/PROMPT-LOOP.md`
Spec refs: journal-capture §Instant Capture Discipline; retro-flow §Consolidate-Curate Mode, §Terminal Retro Retained.

- [x] 2.1 In `research-sdd/PROMPT-LOOP.md`, add a mid-loop instant-capture step: when a defect, capability idea, algorithm, formula, or process insight surfaces, append a conforming journal entry via `mem_save` before the loop continues; deferred capture is out of spec.
- [x] 2.2 In `research-sdd/PROMPT-LOOP.md`, update the TERMINAL TRIGGER / SELF-RETROSPECTIVE section: §18 consolidates the session journal (read → dedup → curate) instead of blind recall; the `## Proposed kit deltas` output shape and `review-status` marker consumed by `sweep-retros.sh` are UNCHANGED.

---

## Phase 3: retro.template.md — Cross-Reference Note

Target file: `research-sdd/templates/retro.template.md`
Spec refs: retro-flow §Promotion Gate; design out-of-scope cross-reference.

- [x] 3.1 In `research-sdd/templates/retro.template.md`, add a brief cross-reference note: deltas in `## Proposed kit deltas` may be sourced from the session journal (consolidated at §18); no auto-promotion — the template's `review-status: pending` gate is unchanged. Cross-reference the capability-proposal slot as out of scope for this change; do NOT implement it.

---

## Phase 4: Verification (doc↔spec readback)

No runtime gate. Verification is a manual cross-read ensuring the written doctrine matches spec requirements.

- [x] 4.1 Cross-read `research-sdd/METHODOLOGY.md` §18 against `specs/journal-capture/spec.md`: confirm Entry Format, Instant Capture Discipline, Substrate Justification, Category Taxonomy, and English Artifacts requirements are all satisfied; no present-tense claim about tooling that does not exist (§12-1).
- [x] 4.2 Cross-read `research-sdd/METHODOLOGY.md` §18 and `research-sdd/PROMPT-LOOP.md` against `specs/retro-flow/spec.md`: confirm Consolidate-Curate Mode, Deduplication, Promotion Gate, and Terminal Retro Retained requirements are satisfied; confirm `sweep-retros.sh` countability contract (output shape) is untouched.
- [x] 4.3 Cross-read `research-sdd/METHODOLOGY.md`, `research-sdd/PROMPT-LOOP.md`, and `research-sdd/templates/retro.template.md` (read-only) against `design.md` §File Changes: confirm all three described modifications are present and no tooling was built.

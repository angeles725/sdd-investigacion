# Proposal: Reframe research-sdd-init.sh JUDGMENT follow-ups by ordering

## Intent

`research-sdd-init.sh` prints a JUDGMENT follow-up block headed `-- ... do these next --`,
framing all five items as post-scaffold chores. But items 1 (REGISTER TARGETS.md, cites §b)
and 2 (CLASSIFY + ANGLE, §b/§b2) are doctrinally PRE-scaffold. §b is emphatic ("right here,
NOT later") with a documented failure: three.js ran unregistered, so its `retros/` was invisible
to the §18 supervision sweep (sweep-retros.sh derives its whole scan list from TARGETS.md).
Framing register/angle as "next" de-emphasizes that anti-forgetting signal and a careful operator
hits a literal contradiction (item 1 cites §b — "do it before this script" — while the header says
"next"). This is doctrine-PRESERVING: strengthen an existing signal at the point of use.

## Scope

### In Scope
- Reframe the follow-up block into two groups: CONFIRM (items 1-2, belong at §b/§b2 BEFORE this
  scaffold) and THEN do next (items 3-5, genuine post-scaffold).
- Add §b's consequence to item 1 concisely (unregistered → `retros/` invisible to the §18 sweep);
  mirror §b, do NOT duplicate the three.js lesson.
- New test assertions for the CONFIRM/next split and the consequence clause, each with a
  `--prove-teeth` mutant.

### Out of Scope
- `PROMPT-LOOP.md` stays FROZEN (already clear at §c line 147-148). No corpus change, no exit-contract
  change, no `verify-doc-consistency` surface. propose-never-apply preserved.

## Concrete reframe (before → after)

Before (single header, all five as "do next"):
`-- JUDGMENT follow-ups (NOT mechanizable — do these next) --` then items 1-5 flat.

After (two ordered groups):
- `-- CONFIRM these are done — they belong at PROMPT-LOOP §b/§b2, BEFORE this scaffold --`
  - 1. REGISTER target row in TARGETS.md (§b) — else its `retros/` is invisible to the §18 sweep.
  - 2. CLASSIFY artifact + declare ANGLE (§b/§b2); run profile-target.sh + detect-tools.sh.
- `-- THEN do next (post-scaffold) --`
  - 3. SEED gaps (§e). 4. REGISTER + ADAPT hook (§c follow-up). 5. Block-file prefix (conditional).

## Capabilities

### New Capabilities
- None

### Modified Capabilities
- None (report-wording only; no spec-level behavior change)

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `research-sdd/toolbelt/research-sdd-init.sh` | Modified | Reframe follow-up block (Option A) |
| `research-sdd/toolbelt/tests/research-sdd-init.test.sh` | Modified | Split + consequence assertions + teeth |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| §6 yield is only MODEST | — | Stated honestly: anti-silent-failure ergonomics (§7 family), not a correctness bug; registration works whenever done |
| Over-wording the report | Low | Mirror §b concisely; keep scannable |

## Rollback Plan

Single-file text revert of the two frozen files; no state, corpus, or contract to unwind.

## Dependencies

- Builds on merged `improve-research-sdd-target-onboarding` (main 0d54949).

## Success Criteria

- [ ] Items 1-2 read as pre-scaffold CONFIRM; items 3-5 as post-scaffold; no "do next" over §b.
- [ ] Item 1 carries the §18-sweep consequence.
- [ ] New assertions pass RED→GREEN and go red under `--prove-teeth`.
- [ ] PROMPT-LOOP.md untouched; one PR within 400-line budget.

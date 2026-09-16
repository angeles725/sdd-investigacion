# Proposal: Improve Research-SDD Target Onboarding

## Intent

A fresh operator bootstrapping a new corpus with `research-sdd-init.sh` gets a scaffold
report and a JUDGMENT follow-up block that under-communicates in three ways: (1) most
follow-up steps carry no PROMPT-LOOP cross-reference and a no-prefix run ends at
`== done ==` with no sign that step 5 is conditional, so "complete" is indistinguishable
from "step silently skipped"; (2) the already-git message says files "land as untracked",
which is inaccurate — the `.claude/` hook is **gitignored** (init appends `.claude/` to
`.gitignore`), so `git add` on it is a silent no-op; (3) the report ends flatly with no
next-step pointer or mental model. This is a §7 anti-silent-zero surface: a real state
(ignored) currently reads as a different one (untracked).

## Scope

### In Scope
- **Item 1**: add one-directional PROMPT-LOOP cross-refs to follow-up steps 1 (`§b`), 3
  (`§e`), 4 (`§c follow-up`), matching step 2's existing `(PROMPT-LOOP §b/§b2)` style; add a
  one-line note on no-prefix runs so the missing conditional step 5 is transparent.
- **Item 2**: amend the already-git message to distinguish untracked corpus files (plain
  `git add`) from the gitignored `.claude/` hook (`git add --force`, or leave ignored).
- **Item 3**: add one explicit next-step line + a one-line mental model, borrowing the
  SDD-bootstrap report shape; forward pointer to `research-sdd-status.sh <target>` (shows
  BOOTSTRAP until follow-ups are done).
- New test assertions for all three items, incl. a new already-git-target fixture (item 2).

### Out of Scope
- **No edit to `PROMPT-LOOP.md`** — cross-refs are one-directional (init.sh cites letters);
  avoids overlap with a parallel session.
- **No corpus modification** — propose-never-apply preserved (§8); read-only-corpora intact.
- No runtime git introspection — item 2 is text-only wording, no `git check-ignore` added.
- No renumbering — there is no numbering gap in init.sh; "no step d" is a PROMPT-LOOP
  letter-scheme note only.
- No touch to `sweep-*.sh`, `verify-registry.sh`, `verify-kit-clean.sh`, any `*-hook.sh`,
  `research-sdd-status.sh`, or `templates/`.

## Capabilities

### New Capabilities
- `init-onboarding-report`: the observable wording contract of `research-sdd-init.sh`'s
  scaffold report, JUDGMENT follow-up block (cross-refs, conditional step-5 transparency),
  already-git message taxonomy, and end-of-report next-step guidance.

### Modified Capabilities
None.

## Approach

Behavior deltas (all in the `# --- report ---` block, init.sh ~146-159):

| Item | Before | After |
|------|--------|-------|
| 1 | `1. REGISTER … TARGETS.md` (no ref); `3. SEED …`; `4. REGISTER + ADAPT the hook …`; `== done ==` after step 4 on no-prefix | steps 1/3/4 gain `(PROMPT-LOOP §b)`/`(§e)`/`(§c follow-up)`; a one-line note states step 5 appears only with `--prefix` |
| 2 | `git … ALREADY under git — files land as untracked (git add as needed)` | message splits: corpus files are untracked (`git add`); the `.claude/` hook is **gitignored** (`git add --force`, or leave ignored) |
| 3 | ends at `== done ==` | one next-step line (`research-sdd-status.sh <target>` → BOOTSTRAP until follow-ups done) + one-line mental model |

Test strategy (strict TDD, runner `bash research-sdd/toolbelt/tests/run-all.sh`):
- **RED→GREEN**: item 1 — assert step-5 text absent on no-prefix run, present on `--prefix`
  run, and `(PROMPT-LOOP §b)` present in step-1 output. Item 2 — new already-git-target
  fixture; assert the message names `.claude/` as gitignored / `--force`. Item 3 — assert a
  next-step marker (e.g. `research-sdd-status.sh`) present in output.
- **Teeth**: mutate each new echo (drop the cross-ref / revert the git wording / remove the
  next-step line) and confirm the assertion goes red via `--prove-teeth`.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `research-sdd/toolbelt/research-sdd-init.sh` | Modified | Report block, all 3 items (~≤15 lines) |
| `research-sdd/toolbelt/tests/research-sdd-init.test.sh` | Modified | New assertions + already-git fixture (~≤20 lines) |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Existing tests assert exact follow-up text and break | Low | Current suite asserts NO follow-up text; probe confirmed no breakage risk |
| Wording overlaps PROMPT-LOOP parallel session | Low | One-directional refs only; PROMPT-LOOP.md frozen out of scope |
| Item 2 wording implies runtime detection it doesn't do | Low | Text-only; message states the gitignore fact, adds no `git check-ignore` |

## Rollback Plan

Single-PR, two-file change. `git revert` the PR (or discard the branch) fully restores the
prior report wording and test suite. No corpus, no registry, no template touched.

## Dependencies

None. `research-sdd-status.sh` referenced in item 3 output already exists and needs no change.

## Success Criteria

- [ ] Follow-up steps 1/3/4 carry PROMPT-LOOP cross-refs matching step 2's style.
- [ ] A no-prefix run makes clear step 5 is conditional (no silent-skip ambiguity).
- [ ] The already-git message distinguishes untracked corpus files from the gitignored hook.
- [ ] The report ends with an actionable next-step + mental-model line.
- [ ] New assertions pass and go red under `--prove-teeth`; full suite green.
- [ ] Delta ≤ ~35 authored lines — one PR within the 400-line budget; PROMPT-LOOP untouched.

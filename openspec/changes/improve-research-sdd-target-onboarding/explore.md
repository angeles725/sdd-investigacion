# Exploration — improve-research-sdd-target-onboarding

Change scope: improve the NEW-TARGET onboarding surface a fresh operator sees when running
`research-sdd-init.sh`, and its alignment with `PROMPT-LOOP.md §BOOTSTRAP`.

Artifact store: hybrid. Engram topic `sdd/improve-research-sdd-target-onboarding/explore` (id 7536).

## Scope — three concrete items

Agreed with the parallel session (`improve-research-sdd-sessionstart-bootstrap`). Do not expand
beyond these without flagging at freeze.

### ITEM 1 — Cross-reference gaps + conditional-step opacity in the JUDGMENT follow-up block

`research-sdd/toolbelt/research-sdd-init.sh`, JUDGMENT follow-up block (lines 150-159):

- Line 151 `1. REGISTER the target row in $KIT/TARGETS.md` — no PROMPT-LOOP cross-ref (should be §b)
- Line 152 `2. CLASSIFY the artifact + declare the ANGLE (PROMPT-LOOP §b/§b2)` — has cross-ref (existing style)
- Line 153 `3. SEED 5-15 real gaps into $corpus/RESEARCH-STATE.md` — no cross-ref (should be §e)
- Lines 154-157 `4. REGISTER + ADAPT the hook` — no cross-ref (should be §c follow-up)
- Line 158 (conditional `[ -n "$prefix" ]`) `5. Block files use the prefix: ${prefix}-blockN.md`
- Line 159 `== done ==` — on a no-prefix run appears right after step 4; nothing signals step 5 exists conditionally

`research-sdd/PROMPT-LOOP.md §BOOTSTRAP` (lines 139-151): lettered steps a / a2 / b / b2 / c / e / e2 / e3 / e4 / f.
Line 147-148 states "there is no step d" — this refers ONLY to the PROMPT-LOOP letter scheme, NOT to init.sh's
numbered output. So there is no numbering GAP in init.sh; the real defects are (a) missing cross-references on
steps 1/3/4 and (b) no-prefix opacity where the operator cannot tell "complete" from "step silently skipped".

Order note: PROMPT-LOOP declares b/b2 (register + classify) BEFORE step c (scaffold). init.sh re-lists them as
post-scaffold follow-ups 1 and 2. Pre-existing design tension — propose should resolve, not paper over.

### ITEM 2 — git messaging misleads on an already-git target

- Git message (lines 146-147): already-git branch prints "files land as untracked (git add as needed)".
- gitignore append (lines 113-116): appends `.atl/` and `.claude/` to target `.gitignore`.
- Hook placement (lines 104, 108): SessionStart hook copied to `$target/.claude/hooks/research-protocol.sh`.

Confirmed: the hook lands under `.claude/`, which init itself appends to `.gitignore`. The hook is therefore
GITIGNORED, not merely untracked. "git add as needed" is inaccurate for it — a plain `git add` is a silent
no-op; it requires `git add --force`. Ties to §7 (a real state currently reading as absent/untracked).

### ITEM 3 — end-of-scaffold-report ergonomics

Report ends at `== done ==` (line 159) after a flat numbered list. Missing: a prioritization/next-step line and
a one-line mental model (what the operator now has, what the follow-ups unlock). Borrow the shape from the SDD
bootstrap report. A forward pointer to `research-sdd-status.sh $TARGET` (shows BOOTSTRAP until follow-ups done)
is a candidate.

## Existing test coverage (research-sdd/toolbelt/tests/research-sdd-init.test.sh, 178 lines)

- Asserts hook file exists (line 32) and `.gitignore` contains `.atl/` + `.claude/` (lines 39-40).
- Does NOT assert JUDGMENT follow-up text, git message text, conditional step-5 presence, or ignored-vs-untracked.
- TDD anchors: step-5 absent on no-prefix / present on `--prefix`; step-1 cross-ref present; git message names
  `.claude/` as ignored; a `NEXT:` next-step pointer present. Item 2 needs a new already-git-target fixture.

Strict TDD is ACTIVE. Test runner: `bash research-sdd/toolbelt/tests/run-all.sh`.

## Out of scope (evidence)

- `research-sdd/toolbelt/research-sdd-status.sh` — its `--sync-state` path (called best-effort at init.sh:136)
  prints none of the follow-ups/git/report text. NO change required.
- `research-sdd/templates/hook-sessionstart.sh` — items 1-3 do not modify template content (init copies it
  unchanged). Stays neutral; owned by the parallel (hooks) session by subject if it ever needs a change.
- MUST NOT touch: `sweep-*.sh`, `verify-registry.sh`, `verify-kit-clean.sh`, any `*-hook.sh`, `status.sh`, `templates/`.

## Approaches — ITEM 1 (only real fork)

| Approach | Pros | Cons | Effort |
|---|---|---|---|
| A. Add cross-refs to steps 1/3/4 + conditional step-5 note | Minimal delta; extends step 2's existing pattern; keeps numbered scheme | Doesn't address b/b2 order ambiguity | Low |
| B. Switch to PROMPT-LOOP letter labels | 1:1 letter match | Out-of-order labels; "c" collides with scaffold step; brittle | Medium |
| C. Mapping note in PROMPT-LOOP §c only | Helps the reader from PROMPT-LOOP; init unchanged | Note lives in doc, not at operator's terminal | Low-Med |
| D. A + explicit conditional note on no-prefix runs | Fixes both cross-refs and opacity; low delta | Slightly more no-prefix output | Low |

Recommendation to carry into propose: **A + D** (items 2 and 3 have no fork).

## §6 viability probe

- Item 1: no existing test asserts follow-up text → zero breakage risk. Yield: less first-bootstrap friction, no "is step 5 missing?" ambiguity.
- Item 2: fix is text-only (split the message) → no runtime introspection added. Yield: stops misleading the operator on the hook file.
- Item 3: one added echo line. Yield: one clear next-action signal.

All three buildable, non-zero yield.

## Frozen candidate file list

| File | Role | Status |
|---|---|---|
| `research-sdd/toolbelt/research-sdd-init.sh` | Implementation — all 3 items | Mandatory |
| `research-sdd/toolbelt/tests/research-sdd-init.test.sh` | Tests — new assertions items 1/2/3 | Mandatory |
| `research-sdd/PROMPT-LOOP.md` | Optional — §c cross-ref note for item 1 | Propose decides |

Budget estimate: ≤15 lines in init.sh + ≤20 new assertion lines — within the ~400-line PR budget.

## Open questions for propose

1. Should init step 1 note that PROMPT-LOOP expects TARGETS.md registration BEFORE scaffolding?
2. Is `PROMPT-LOOP.md` in scope for edits, or is cross-referencing one-directional (init → doc)?
3. Item 2: two lines (ignored `.claude/` vs untracked corpus) or one amended line with the `.claude/` exception?
4. Item 3: one-liner before `== done ==` or a small separate section? Confirm the SDD-bootstrap shape to borrow.

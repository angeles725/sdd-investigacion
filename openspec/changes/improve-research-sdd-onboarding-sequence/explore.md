# Exploration — improve-research-sdd-onboarding-sequence

Builds on the merged change `improve-research-sdd-target-onboarding` (main 0d54949). Investigates the
"b/b2-before-c ordering tension" that change's explore deferred (its Open Question #1).

Artifact store: hybrid. Engram topic `sdd/improve-research-sdd-onboarding-sequence/explore`.

## The tension (current state, file:line evidence)

`research-sdd/PROMPT-LOOP.md` §BOOTSTRAP declares the canonical order `a · a2 · b · b2 · c · e · e2 · e3 · e4 · f`
(line 148). Crucially:

- **§b (lines 118-130):** "REGISTER the target in $KIT/TARGETS.md's master table **right here** ... as part of
  bootstrap, **NOT later**." The stated reason is a real, documented failure: the retro sweeper derives its ENTIRE
  scan list from TARGETS.md, so "an unregistered target's `retros/` dir is invisible to the §18 supervision sweep
  (lesson: three.js ran its first focus — 12 blocks — unregistered, so its retro was invisible to the sweeper
  until registered by hand)."
- **§b2 (lines 131-138):** DECLARE the investigation ANGLE, "CONFIRM it BEFORE closing the first gap."
- **§c (lines 139-151):** run `research-sdd-init.sh` (the scaffold), then do the JUDGMENT follow-ups it prints.
  Line 147-148 already clarifies: "TARGETS.md registration is step b; gap-seeding is step e. There is no step d."

`research-sdd/toolbelt/research-sdd-init.sh` JUDGMENT follow-up block (post the merged unit-1 change, ~lines 154-166):
- header: `-- JUDGMENT follow-ups (NOT mechanizable — do these next) --`
- `1. REGISTER the target row in $KIT/TARGETS.md ... (PROMPT-LOOP §b)`
- `2. CLASSIFY the artifact + declare the ANGLE (PROMPT-LOOP §b/§b2) ...`
- `3. SEED 5-15 real gaps ... (§e).`
- `4. REGISTER + ADAPT the hook (§c follow-up): ...`
- `5. Block files use the prefix ...` (prefix-conditional)

**The inconsistency:** init.sh's header frames ALL five as things to "do these next" (i.e. AFTER the scaffold at
step c). But items 1 and 2 ARE §b and §b2 — which doctrine places BEFORE step c, with §b emphatic ("right here,
NOT later") and backed by a documented failure. So init.sh de-emphasizes register/angle to a flat post-scaffold
chore list, weakening the anti-forgetting signal §b deliberately carries. A careful operator also hits a literal
contradiction: init step 1 cites `(PROMPT-LOOP §b)`, and §b says do it before the very script that is now telling
them to do it "next".

## Is registration actually a hard pre-scaffold requirement?

No — functionally, a TARGETS.md row can be added at any time; the sweeper only needs it to EVENTUALLY exist. So
this is not a correctness bug. It is an **anti-silent-failure ergonomics** gap (§7 family, UX layer): the current
framing makes it easy to defer/forget registration, which reproduces the exact three.js failure (retros invisible
to the §18 sweep). The value is in surfacing the consequence at the point of use (the terminal report), not only
in PROMPT-LOOP §b prose an operator may not re-read.

## Fix options (tradeoffs)

| Option | What | Pros | Cons |
|---|---|---|---|
| A | Reframe init's follow-up block: split it into "CONFIRM these are done (they belong at §b/§b2, BEFORE this scaffold)" for items 1-2, and "then do next" for items 3-5. Add §b's consequence to item 1 (unregistered target → its retros/ is invisible to the §18 sweep). | Honest about ordering; ties the documented failure to the action at the point of use; init-only, low risk | Slightly more report text |
| B | Only add the consequence clause to item 1, keep the flat header | Minimal delta | Doesn't resolve the "do next" vs "before" contradiction for the reader |
| C | Also edit PROMPT-LOOP §c to note init's item-1 is a §b catch-up | Symmetric for a PROMPT-LOOP reader | PROMPT-LOOP §c line 147-148 ALREADY clarifies registration is step b — largely redundant; adds doc-consistency-test surface for little gain |
| D | Leave as-is | — | Leaves a real, documented failure under-signalled |

**Recommendation for propose: Option A** (init.sh only). PROMPT-LOOP.md is already internally clear (line 147-148),
so it stays FROZEN — the fix belongs on init.sh's side, where the misframing actually is. This also keeps the change
disjoint and avoids `verify-doc-consistency` risk.

## §6 viability probe (honest)

- Unbuildable if: init's follow-up text were machine-parsed downstream (it is not — verified in unit-1: nothing
  parses init.sh stdout). No blocker.
- Yield: MODEST but REAL. It does not fix a correctness bug (registration works whenever done); it strengthens an
  anti-forgetting signal tied to a documented failure (three.js: unregistered → invisible retros). Comparable in
  kind and value to the unit-1 report-wording items already shipped. Not zero-yield; not high-yield. Honest call:
  worth building as a small polish, NOT worth expanding scope for.

## Test coverage

`research-sdd/toolbelt/tests/research-sdd-init.test.sh` already asserts the step-1 cross-ref `(PROMPT-LOOP §b)` and
the follow-up block presence (unit-1). New assertions would check the reframed CONFIRM/next split and the
consequence clause on item 1, each with a `--prove-teeth` mutant. `verify-doc-consistency` need not change because
PROMPT-LOOP.md is untouched.

## Frozen candidate file list

| File | Role | Status |
|---|---|---|
| `research-sdd/toolbelt/research-sdd-init.sh` | Reframe JUDGMENT follow-up block (Option A) | Mandatory |
| `research-sdd/toolbelt/tests/research-sdd-init.test.sh` | New assertions + teeth | Mandatory |
| `research-sdd/PROMPT-LOOP.md` | NOT edited — already clear at line 147-148 | Out of scope |

Est. ~20-30 authored lines. Single PR, well within 400 budget.

## Open questions for propose

1. Exact split wording: two sub-headers ("CONFIRM (belong at §b/§b2, before scaffold)" vs "THEN") or an inline
   annotation per item? Keep it scannable.
2. Consequence clause phrasing for item 1 — mirror §b's "retros/ invisible to the §18 sweep" without duplicating
   the whole three.js lesson.
3. Confirm PROMPT-LOOP.md stays frozen (recommended) vs a one-line §c cross-note (Option C, likely redundant).

# SHELVED — do not build

**Status:** SHELVED (do not implement). This change is a re-implementation of an
already-closed feature. Read this before touching any file in this directory.

**Verdict date:** 2026-08-31 · recorded by `investigador2`, independently endorsed by
`investigador1` and `QA` (autonomous kit-maintenance team session).

## Why shelved

This is a re-litigation of **PR #383** (`feat/sweep-declared-state`, commit `5c1ff9c`),
which was **CLOSED unmerged on 2026-08-27** by a deliberate §6/§7 decision — not a scope
problem. That decision still holds:

1. **§6 zero current yield.** On the real fleet no SessionStart hook is ever genuinely
   `clean` — there is always a WARN / pending / MISSING-RETRO / absent corpus. A
   silence-on-clean feature therefore silences *nothing* today; its value is
   future-conditional (only a pristine fleet benefits). This is the `verify-block.sh`
   measure-before-build trap §6 exists to prevent. (Confirmed live: the session that wrote
   this had a non-clean SessionStart — registry drift on 2 targets, an unindexed
   breakthrough, 248 unrecorded tools.)
2. **§7 false-clean treadmill.** The sentinel derives `clean` from a hand-summed
   `FINDINGS` counter. That is exactly the mechanism #383's close comment named as the
   recurring hazard FABLE blocked across three rounds: a newly-added WARN is born
   *uncounted*, so the counter reads 0 and the sentinel emits `clean` while a real
   attention line prints. The planned teeth only test *dropping an existing* term; they
   cannot catch a *future uncounted* WARN — that mutant is never written.

The later OpenSpec refinement in this directory only made the file set disjoint from peer
lanes. **Disjointness was never the reason #383 was closed**, so the refinement does not
revive the change.

## Already delivered (the real, unconditional wins)

- **D2** (breakthroughs "Ledger consistent" clean sentence) and **D3** (neutral header
  wording) shipped via **PR #376** — MERGED 2026-08-27, merge commit `26332ba`
  (squash `5185632`). See `sweep-breakthroughs.sh:176`.

## If ever revisited

Only when a fleet actually runs clean, AND using the structure FABLE prescribed: route
every WARN/attention line through **one emit helper that flips an "attention" flag**, so an
attention line can never be emitted uncounted (`clean` == "the helper was never called"),
plus a fixture per real emitter. A hand-summed counter is not acceptable. Not scheduled.

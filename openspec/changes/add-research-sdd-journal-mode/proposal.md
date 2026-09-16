# Proposal: Research-SDD Journal Mode (instant capture → §18 consolidate)

## Intent

The §18 self-retrospective fires only at the TERMINAL TRIGGER (end of loop / at
archive) — a batch recall "just before stopping." A read-only survey of 146 retro
files fleet-wide found the output is ~57% doctrine/process, ~22% instrument tweaks,
~12% new tools, ~6% algorithms/heuristics, <1% mathematical/statistical models (only
ONE statistical model surfaced fleet-wide, and it was correctly measured and
rejected). Mid-session insights — especially small capability-additive ones (tool
ideas, algorithms, formulas) — are forgotten by the terminal, and end-of-loop recall
structurally biases toward doctrine prose. Insight: the instant-capture SUBSTRATE
already exists (Engram `mem_save`, called proactively at the moment of a decision /
bugfix / discovery); the gap is that §18 does NOT consume those in-the-moment
captures — it is re-authored blind at the end instead of consolidating what was
already recorded.

## Scope

### In Scope
- **Journal doctrine**: prescribe a per-entry instant-capture convention for
  mid-loop insights (improvement / defect / tool-idea / algorithm-idea / formula-idea) captured
  the instant they surface, not deferred to the terminal. Each insight is one independent
  Engram observation.
- **§18 transform**: redefine the terminal retro from "recall everything from memory"
  to CONSOLIDATE / CURATE — dedup the session's journal entries and promote worthwhile
  ones to deltas. §18 is RETAINED as the gate that filters the journal (keeps it from
  becoming noise).
- **Substrate decision, measured first**: prefer reusing Engram capture over a parallel
  store; measure whether a dedicated lightweight capture command/convention is needed
  BEFORE building one (§6 doctrine-first — a zero-tooling convention may suffice).
- Cross-reference the complementary retro-template "capability proposal" slot.

### Out of Scope
- Implementing the retro-template "capability proposal" slot (new tool-idea / algorithm-idea /
  formula-idea + measurement criterion) — out of scope for this change; a future change may add
  this slot.
- Retro-flow redesign (markers → GitHub issues) — separate future change.
- `apply-research-sdd-retro-backlog` (applying existing open deltas) — distinct change.

## Capabilities

### New Capabilities
- `journal-capture`: governs the per-entry instant-capture convention — its format, its
  per-entry discipline (one insight = one Engram observation), and the reuse-Engram-vs-dedicated-store
  decision (built only if measurement shows tooling buys something).

### Modified Capabilities
- `retro-flow` (§18 terminal retro): requirement changes from blind end-of-loop recall
  to consolidate/curate/dedup over the session journal, with §18 retained as the
  promotion gate.

## Approach

- **Doctrine-first (§6)**: prescribe the journal entry format and the consolidation
  discipline in METHODOLOGY.md §18 + PROMPT-LOOP.md BEFORE any tooling.
- **Measure-before-build (§6/§7)**: measure whether instant capture needs a dedicated
  command or whether the existing Engram `mem_save` convention suffices; a valid rule
  with a zero-tooling convention beats a script that buys nothing.
- **Retain §18 as the filter**: the terminal dedup/consolidation step is exactly the
  guard that stops the journal degrading into noise.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `research-sdd/METHODOLOGY.md` (§18) | Modified | Terminal retro → consolidate/curate over journal; journal format doctrine |
| `research-sdd/PROMPT-LOOP.md` | Modified | Instant-capture step mid-loop; TERMINAL TRIGGER consolidates the journal |
| retro template | Modified | Cross-reference the capability-proposal slot (out of scope here; a future change may add it) |
| lightweight capture convention/command | New (conditional) | Only if measurement shows Engram reuse is insufficient |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Same insight double-counted (journal + terminal) | Med | §18 dedup/consolidation step is retained precisely for this |
| Instant capture degrades into noise | Med | §18 promotion gate filters; append-only one-line discipline |
| Building a parallel store that buys nothing | Med | Measure-before-build (§6/§7); prefer reusing Engram substrate |
| Overlap/confusion with retro-flow redesign | Low | Explicitly cross-referenced, kept distinct; template slot is out of scope |

## Rollback Plan

Doctrine edits are text-only — revert the offending PR's merge commit. If a capture
convention/command is built, it is additive and reverts independently; §18 reverts to
its prior blind-recall wording. No target corpus data is mutated (METHODOLOGY
§13/§18 propose-never-apply).

## Dependencies

- Engram `mem_save` as the candidate instant-capture substrate.
- Coordinate wording with any future change that adds the capability-proposal template slot;
  no hard ordering dependency for this change's doctrine.

## Success Criteria

- [ ] METHODOLOGY.md §18 redefined as consolidate/curate over the session journal, with §18 retained as the promotion gate.
- [ ] PROMPT-LOOP.md prescribes mid-loop instant capture and terminal consolidation.
- [ ] Journal entry format (append-only, one line) prescribed doctrine-first.
- [ ] Measurement recorded on whether a dedicated capture command/convention is needed before any tooling is built.
- [ ] Complementary capability-proposal template slot cross-referenced, not implemented here.

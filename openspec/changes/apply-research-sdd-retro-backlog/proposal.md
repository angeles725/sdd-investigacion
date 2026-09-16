# Proposal: Apply Research-SDD Retro Backlog (kit deltas)

## Intent

Pending §18 retros across the fleet proposed doctrine/instrument improvements that are still open. A read-only triage of 104 pending retros found ~9 kit-delta-bearing retros / ~26 open kit deltas (rest are target-corpus findings or already-applied; no clean already-applied marker-flips — 3 partial applies). Apply the genuinely-open HIGH/MED deltas, grouped by DESTINATION FILE (CLAUDE.md §3), and flip each source retro marker to `applied <date> · kit <merge-sha>` or `dismissed` as it lands.

## Scope

### In Scope (apply, grouped by destination file — parallelizable per §3)
- **CLAUDE.md §3**: design agents emit artifact-only; `isolation:worktree` + read-back path per writer; worktree base explicitly on `origin/main`; ordering messages name FILE SETS.
- **CLAUDE.md §4/§5**: executed RED-before-fix (swap SUT bytes, not a comment); spec pins a DATED measurement not a bare number; budget is a FLEET property.
- **CLAUDE.md §6**: sampling-rule change is its own work unit.
- **CLAUDE.md §7**: DEGRADED-env 4th axis (typed `degraded`, never silent pass); re-run enumerator at every new instrument's gate; distinct labels for distinct populations.
- **METHODOLOGY.md §11b**: gate calibration corpus must be a FROZEN fixture.
- **METHODOLOGY.md §12**: point-set + link snapshot before growing-write-set load test; `GATED-BY-DEPLOYMENT` verb; self-built scaffold validates CODE not DEPLOYMENT; min-priv principal is a capability; cross-source calibration.
- **METHODOLOGY.md §18 + sweep-retros.sh**: WARN column for unwired §18 Stop hooks (measure wired/unwired first).
- **research-sdd-archive.sh + PROMPT-LOOP.md**: gate archive on §18 conformance (exit-3), restate §18 in TERMINAL TRIGGER.
- **PROMPT-LOOP.md RETURN CONTRACT**: surface proven BREAKTHROUGH recipe; forward-resolution back-pointer; ScheduleWakeup self-paced note.
- **NEW templates/workflows/deep-research-tiered.js + doctrine**: promote from ephemeral dir; per-effort model-assignment line; "Verify stays on sonnet" caveat.

### Out of Scope
- journal-mode (J1/J2) → change `add-research-sdd-journal-mode`.
- retro-flow redesign (markers → GitHub issues) → its own change.
- The 3 LOW §5/RETURN-CONTRACT items: OPTIONAL, defer if over budget.

## Capabilities

### New Capabilities
None (doctrine + instrument-behavior deltas; spec phase captures instrument-behavior requirements).

### Modified Capabilities
- `retro-sweep`: sweep-retros.sh gains unwired-§18 WARN column.
- `archive-gate`: research-sdd-archive.sh gains §18 conformance exit-3 gate.

## Approach

- **Doctrine-first (§6)**: for every delta adding instrument behavior (sweep WARN column, archive gate, degraded axis), prescribe the declaration, THEN build the checker.
- **Measure incidence first**: count unwired §18 hooks before scheduling — a zero-occurrence rule is verifier discipline, not a work unit.
- Group work units BY DESTINATION FILE (disjoint sets, parallelize); each doctrine PR ~400 lines (§6), auto-chain.
- Marker flips in TARGET corpora: `git add <file>` only, MERGE sha, never checkout/reset in a peer tree (§8 propose-never-apply).

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `CLAUDE.md` | Modified | §3/§4/§5/§6/§7 doctrine deltas |
| `research-sdd/METHODOLOGY.md` | Modified | §5/§11b/§12/§18 deltas |
| `research-sdd/PROMPT-LOOP.md` | Modified | RETURN CONTRACT + TERMINAL TRIGGER |
| `research-sdd/toolbelt/sweep-retros.sh` | Modified | unwired-§18 WARN column |
| `research-sdd/toolbelt/research-sdd-archive.sh` | Modified | §18 exit-3 gate |
| `research-sdd/templates/workflows/deep-research-tiered.js` | New | promoted from ephemeral dir |
| pending §18 retro markers | Modified | flip to applied/dismissed |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Concurrent doctrine churn with in-flight promotion campaign | High | SEQUENCE: apply AFTER promotion frees shared files (it touches tool-registry.md; these touch CLAUDE.md/METHODOLOGY.md) |
| Instrument delta with zero real incidence | Med | Measure incidence before scheduling; drop to verifier-discipline if zero |
| Over-budget doctrine PR | Med | Split by destination file; ~400 lines/PR; defer 3 LOW items |
| New checker false-positives on real corpus | Med | Doctrine-first; accept via fleet sweep vs `main`, not fixtures |

## Rollback Plan

Each work unit is an independent PR. Revert the offending PR's merge commit; doctrine edits are text-only, instrument changes are WARN/exit-code additive. Marker flips revert with `git revert`. No target-corpus data is mutated beyond marker lines.

## Dependencies

- In-flight promotion campaign must free shared kit files before APPLY.

## Success Criteria

- [ ] All HIGH + MED open deltas applied, grouped by destination file.
- [ ] Each source retro marker flipped to `applied <date> · kit <merge-sha>` or `dismissed`.
- [ ] New instrument behaviors: doctrine landed before checker; incidence measured.
- [ ] Gates green on quiet tree (shellcheck, run-all, --prove-teeth); accepted via fleet sweep.
- [ ] 3 LOW items either applied or explicitly deferred with reason.

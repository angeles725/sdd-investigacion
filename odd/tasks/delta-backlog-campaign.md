# ODD Feature: delta-backlog-campaign

**Created:** 2026-09-20 · **Branch base:** origin/main @ `ad87c33` · **Owner session:** sdd-investigacion

## Objective

Resolve the un-applied delta backlog: 246 OPEN deltas across 68 retros in 7 target
corpora currently have **zero** GitHub issues. The backlog-first rule (METHODOLOGY §18 /
PROMPT-LOOP) and its tools (`stage-retro-issues.sh`, `reconcile-issues.sh`) landed on
origin/main ~2026-09-19 but were never run (manual loop step + local checkout was 49
commits behind). Bring the backlog into the tracked, backlog-first state and apply the
deltas that are genuinely still open.

## Problem / why

- `reconcile-issues.sh --all` → `tracked=0 untracked=246 orphaned=0 degraded=1 retros=102`.
- CRITICAL: `untracked` (no issue) ≠ `unapplied` (kit unchanged). Reconcile measures
  marker↔issue coverage only. Many Aug/early-Sep deltas were likely applied during the
  14-PR campaigns without flipping the retro marker. Seeding 246 issues blindly = false
  backlog (violates report-only-what-you-measured / anti-silent-zero doctrine).

## Constraints

- propose-never-apply: kit surfaces findings; never auto-edits target corpora.
- All deltas here propose KIT changes (METHODOLOGY / PROMPT-LOOP / toolbelt). Target
  corpora are NOT edited by this campaign.
- Group apply work by DESTINATION FILE, not source retro (CLAUDE.md §3).
- Work-unit budget ~400 authored lines/PR; chain PRs when exceeded.
- English artifacts. Conventional commits, no AI attribution. Commit/push/PR/merge
  authorized by user this session.

## Backlog by target (open deltas / retros)

| Target | Deltas | Retros | Triage slice |
|---|---|---|---|
| niagara-research | 120 | 38 | niagara-A (74/19) + niagara-B (46/19) |
| blender-llm | 77 | 16 | blender |
| fluke-177x-datos | 29 | 7 | fluke |
| api-paneles + panccadia-3d + COB-IM2 + hisense | 20 | 7 | small |

## Phase 1 — Triage (read-only, IN PROGRESS)

Delegated 5 parallel mappers (disjoint retro sets) to classify each delta:
APPLIED (already in kit) / OPEN (kit unchanged) / AMBIGUOUS. Output feeds Phase 2/3.

- [x] T1 niagara-A triage → APPLIED=56 OPEN=6 AMBIGUOUS=12 (of 74)
- [x] T2 niagara-B triage → APPLIED=35 OPEN=8 AMBIGUOUS=4 (of 47)
- [x] T3 blender triage → APPLIED=72 OPEN=4 AMBIGUOUS=1 (of 77)
- [x] T4 fluke triage → APPLIED=25 OPEN=3 AMBIGUOUS=1 (of 29)
- [x] T5 small-targets triage → APPLIED=13 OPEN=8 AMBIGUOUS=1 (of 22)

Running tally (4/5): APPLIED=129 OPEN=25 AMBIGUOUS=18 (of 172). Confirms ~75%
already-applied — the "246 open deltas" was almost entirely applied-but-marker-not-flipped.
OPEN so far concentrate in METHODOLOGY.md and PROMPT-LOOP.md. Some AMBIGUOUS deltas target
the `build-n4-module` skill, not research-sdd (separate scope).

## Phase 2 — Seed issues (backlog-first backfill) — PENDING triage

KEY FINDING (dry-run 2026-09-20): `stage-retro-issues.sh` seeds ALL rows of a `pending`
retro — it does NOT know which are already applied. Naive `--apply` recreates the false
backlog. Correct sequence (uses the tool's existing PARTIAL-marker support + `is_shipped`):

- [ ] P2a Per retro, rewrite the review-status marker to reflect triage: mark APPLIED rows
      as `shipped` in a PARTIAL marker (or fully `applied`/`dismissed` when no row is OPEN),
      leaving ONLY the triaged-OPEN rows open. This DOUBLES as Phase 4 E2 marker hygiene.
- [ ] P2b Then `stage-retro-issues.sh <retro> --apply` seeds issues ONLY for still-open
      (unshipped) rows.
- SCOPE NOTE: marker edits land in retros inside PEER target repos (panccadia-3d-viewer,
  COB-IM2, api-paneles, blender-llm, niagara-research, fluke, hisense) — commits in those
  repos, not just the kit. Confirm peer-repo commit scope with user before P2a.

## Phase 2 RESULT (2026-09-20)

Marker hygiene done in 4 clean repos (panccadia 523cf03, fluke 070169c+946ae23, blender
f6b4176, niagara-research 4c179f7b2+80bcafe4c). reconcile untracked 246→106. Caught + fixed
a marker-id bug: fluke PARTIAL markers used triage labels `R1-R6` but the delta tables use
bare `1-6`; stage-retro-issues/reconcile match on table ids, so the mismatch made every row
read open (over-seed 13 vs 4). Fixed in 946ae23. Only fluke had it (blender/panccadia/niagara
matched). Lesson: PARTIAL shipped/deferred ids MUST match the retro's actual delta-row ids,
not the triage's labels.

Issue seeding DONE: **28 backlog-first issues created #828–#855** in the kit repo (0 dup, 1
transient network fail on b38-b52 retried→#855). Friction repos (api-paneles/hisense ~7 open)
deferred — their markers not yet reconciled.

## Phase 3 — Apply open deltas with ODD — PENDING triage

- [ ] Regroup OPEN deltas by destination kit file (disjoint writer sets).
- [ ] Implement in chained PRs within budget; TDD per kit §4/§5; native checks.

## Phase 4 — Make backlog-first ENFORCED in /research-sdd (user hard requirement)

User requirement: "next time `/research-sdd` MUST generate retros/deltas as backlog-first
issues, sí o sí" — reliably, not as prose an agent can skip.

Findings so far:
- The §18 rule + `stage-retro-issues.sh` DID land on origin/main (#796/#797) and the
  09-19 campaign resolved 233 deltas via tracker #557. But the steady-state rule is a
  MANUAL loop step; a session on a stale checkout or an agent that skips it creates no issue.
- `reconcile-issues.sh` keys "open delta" off the retro review-status MARKER (`pending`),
  not off whether the kit changed. Applied-but-not-flipped markers make it report
  false `untracked` — a related reliability gap.

- [ ] E1 Decide enforcement mechanism (fork — propose with tradeoffs):
      (a) fold issue-seeding into the retro-staging flow (`stage-retro.sh`) so writing a
          retro auto-seeds its issues; (b) a post-retro hook running reconcile that WARNs/
          blocks on untracked; (c) a loop "done gate" refusing terminal until seeded.
- [ ] E2 Close the marker-hygiene gap so applied deltas flip their markers (stop the
      false-untracked signal).
- [ ] E3 Wire it so it fires without a human remembering (hook / loop gate), with §7
      degraded when `gh` is absent. Ship with TDD teeth (§4/§5). propose-never-apply intact.

## Scope handoff — build-n4-module deltas → @Niagara (2026-09-20)

11 AMBIGUOUS deltas target niagara-tools/build-n4-module, NOT research-sdd. Handed to the
Niagara peer session to own; to be marked out-of-scope for research-sdd on their confirm.
- retro 2026-09-01-build-n4-module-kit-v0.2-retro.md: P1–P6 (P7 SHARED — coordinate)
- retro 2026-09-11-module-worktree-location-retro.md: D1–D5
Effect: research-sdd ambiguous count 19 → ~7 after handoff confirmed.
CONFIRMED 2026-09-20: Niagara accepted P1–P6 + D1–D5 (scoped OUT of research-sdd). Their
heads-up: most already implemented in build-n4-module (D1–D5 done, P3/P4/P5 exist, P1
partial, P2/P6 to reconcile). P7 SHARED — split agreed: I own the research-sdd
METHODOLOGY.md half (coordinator/researcher/QA three-session template), Niagara owns the
BUILD-LOOP/ORCHESTRATION half; cross-link. TODO: open research-sdd issue for METHODOLOGY half.
Niagara owns the marker flip on the 2 build-n4-module retros in niagara-research. My
niagara-research marker hygiene stays deferred until Niagara confirms it's done writing there.

## Sequence decision (user): ENFORCEMENT FIRST

Make /research-sdd auto-fire before cleaning the old backlog. Enforcement work units:
- [x] EN1 #627 — VERIFIED closed + working (research-sdd-status.sh:759 emits RETRO-DUE).
      Fix was doc-sync only: PROMPT-LOOP.md:98-99 stale "until #627 lands, check manually"
      note removed. Commit 596b21f on branch fix/enforce-en1-retro-due-doc-sync.
- [ ] EN2 `research-sdd-init.sh` wires `retro-gate.sh` (Stop hook) by DEFAULT + wire the
      currently unwired targets (SessionStart: 2 wired / 4 unwired / 11 absent-settings).
- [ ] EN3 Fold issue-seeding into the retro/Stop flow so `stage-retro-issues` runs
      automatically (or Stop gate refuses to close until deltas have issues).
- [ ] EN4 External driven verification session: fresh session runs /research-sdd on a
      sacrificial target, asserts each requirement auto-fired with no human command.

## Progress log

- 2026-09-20: checkout updated (49 behind → ad87c33); reconcile run; 193→24 local
  branches cleaned (169 merged deleted, 23 unmatched retained, 189 remote pending);
  triage slices built; 5 mappers launched.

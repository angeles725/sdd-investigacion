# Agenda 2026-09-22 follow-ups (#901, #902, #904, G54, #903)

## Objective
Close the four items deferred at the end of the kit-consistency-cleanup session, and audit
that the research-sdd instruments report what they actually measured.

## Authorized scope
ODD + RDD (candidate consent pre-granted by the maintainer for every candidate); commit, push,
PR, PR view, issues and merge authorized on 2026-09-22. TARGETS.md stays hand-edited only (§8).

## TDD
Mode: on · source: repo CLAUDE.md §4 (strict TDD + mutation check) · runner:
`bash research-sdd/toolbelt/tests/run-all.sh [--prove-teeth]`.

## Decisions
- #901 semantics (maintainer, 2026-09-22): every entry under `## Blocked / non-read-only gaps`
  counts toward `blocked_open` → niagara root focus `blocked_open=2` (G5b + G8). Heading unchanged.

## Tasks
- [x] T1 — #904: strip stray `**` from nine issue titles. Route: inline (gh). Evidence: titles
  edited, #904 closed.
- [x] T2 — #901a: re-seed niagara root `RESEARCH-STATE.md` envelope for blocked_open=2 with the
  counter identity kept consistent. Route: delegated (peer repo). Evidence: niagara `0a6eb1e1f`
  pushed; blocked_open 0→2, requires_execution_open 1→0, known_gaps 8→9 (identity 7+0+2+0+0=9);
  verify-state root envelope `blocked_open=2/2`, only the T3 covered_blocks FAIL remains.
- [x] T3 — #901b + audit: `covered_blocks` FAILs across ~50 niagara focuses (many carry the
  identical value 266). Map first: corpus drift or instrument defect? Route: delegated mapper. Finding (verified at `research-sdd-status.sh` SG-ATTR-SYNC): the
  seeder falls back to the corpus-wide count under shared-global, contradicting §16; cases 52/53
  certify the defect. 266 itself came from hand re-seeds (niagara `fa3582fef`, `28500260a`).
  Filed #905 (seeder defect) and #906 (root RESEARCH-STATE.md not targetable by --sync-state).
- [x] T3b — #905 kit fix. Route: delegated writer, worktree, strict TDD (files disjoint from T4).
  Commit `50fccdf`, PR #907. RDD: high → granted → 4 lenses approved → acknowledged (burned).
  Advisory follow-ups: T53 INFO grep unscoped, T-905 verify-state check negative-only. Merged `47c1750` (#907) on green CI.
- [x] T3c — niagara corpus re-seed of shared-global focuses, only after #905 merges. Route:
  delegated. niagara `a636d22f9` re-seeded 41 files but also rewrote other counters; spot
  checks proved two wrong (database blocked_open, platform-native known_gaps). Corrected in
  `fbd5df3b4`: only covered_blocks/block_scope kept. verify-state FAIL lines 75 → 34. Root
  RESEARCH-STATE.md and optimizer-4.13 left for judgement. Filed #911.
- [x] T4 — #902: test stubs of `target_paths_all` diverge from the #887 library contract.
  Route: delegated writer, worktree, strict TDD. First attempt rejected (parity tested a copy of
  the stub). Rework: commit `5e7f43c`, PR #909. RDD: high → granted → approved → acknowledged.
  Advisory: parity does not assert lib rc. Merged `3feea95` (#909) on green CI.
- [x] T7 — #908 (audit finding): CI `toolbelt tests` red on main for every one of the last 60
  runs; retro-gate jq-absent simulation not hermetic on ubuntu (/bin → /usr/bin). Route:
  delegated writer, worktree. Must merge first so #907/#909 merge on green CI. Merged `0ff0eac` (#910);
  first green `toolbelt-tests` run on CI in 60+ runs.
- [x] T5 — blender-llm G54 `needs:` without `tried:`: research work, not a number to adjust. No
  edit; WARN stays standing.
- [x] T6 — #903 fleet hygiene: not worked this session; TARGETS.md rows are human-only (§8).

## Progress / evidence
- T1 done 2026-09-22.
- Merged-main gate (worktree on `3feea95`, quiet tree): shellcheck clean; `run-all.sh
  --prove-teeth` 123/123 suites, 3204 passed, 0 failed, 8 skipped; 21 suites without teeth (pre-existing).

## Next step
#911 derivation misses (derive_blocked form, multi-table backlog, --sync-state writing
unseen counters); #906 root state targeting; advisory review follow-ups from #907/#909/#910;
#903 hygiene; niagara root covered_blocks (attributed derivation gives 11) awaits #906.

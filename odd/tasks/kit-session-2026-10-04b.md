# Kit session 2026-10-04b

**Objective:** execute the 2026-10-04 "Next session — agenda" in chain, automatically, plus every buildable
improvement found on the way.

**Authorization:** ODD + RDD (consent granted for every candidate), commit, push, PR, PR view, issues, merge.
Gentle AI review prompts: grant and run the review without asking.
**Delivery:** one PR per work unit, `auto-chain`; each PR `Closes #N` of a `status:approved` issue.
Merge via `research-sdd/toolbelt/merge-gate.sh --merge` (scratchpad `ship.sh`).

**Per-PR pipeline:** harness-worktree sonnet writer (based on `origin/main`, brief = scratchpad
`writer-common.md`) → parent spot check (`review.sh`: teeth + repo-wide lints) → RDD (`rdd-drive.py`,
merge-base range, committed-only) → fix real WARNs; after ~3 rounds file the remainder as a follow-up → PR → CI →
merge-gate.

**Start:** origin/main = 19223b9. Shared checkout main = e9c9b4b (pinned: live niagara5 session; human edit in
research-sdd/TARGETS.md — never touched). RDD mode: on (global).

## Tasks
Wave 1 (concurrent, disjoint file sets; route: delegated, writer trigger):
- [ ] T1 #1661 docs unit — clean-check.v1.md, tool-registry.md, METHODOLOGY.md, PROMPT-LOOP.md.
- [ ] T2 #1576 shared helpers in tests/lib/mutant.sh + adopting suites (slice if > ~400 lines; deferred part filed).
- [ ] T3 #1647 run-all teeth-helper lint false negatives → delete the 2 waivers; then #1645 (same file, serial).
- [ ] T4 #1657 migrate-backlogs advisories.
- [ ] T5 #1637 `--sync-state` declared counters (research-sdd-status.sh).
Wave 2 (after T1 merges):
- [ ] T6 Release v1.2.0 — CHANGELOG.md PR (regenerated), tag v1.2.0, GitHub release. Shared checkout NOT updated.
- [ ] T7 #1659 verify-block / clean-check advisories (touches clean-check.v1.md → after T1).
- [ ] T8 #1663 java class-file facts advisories.
- [ ] T9 #1626 detect-tools dotnet leak; #1641 binwalk path.
Wave 3:
- [ ] T10 Triage priority:medium needs-review with the maintainer (explain each with an example; maintainer decides).
- [ ] T11 #1660 only after progress on #1650–#1656.

## Excluded
Blocked/user decisions unchanged from 2026-10-03c (#1255 #1256 data; #1259 #1442 #1369 #1358 #1361 #1328 #1295
#1246 #1262).

## Progress log
- Session start: ODD doc created; helpers recovered from the previous scratchpad.

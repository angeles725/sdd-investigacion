# Kit backlog — session 2026-09-23d

## Objective
Continue the kit backlog from the 2026-09-23c agenda (`odd/tasks/kit-audit-2026-09-23.md`, "Next session"),
autonomously and chained: ODD + native RDD (consent granted by the maintainer), commit, push, PR, issues, merge
authorized.

## Constraints
- Base every work branch on `origin/main` (currently `356fa15`); harness worktree isolation for writers.
- Per PR gate: rebase on origin/main → native RDD (consent granted) → Opus adversarial review → parent re-runs
  claims → quiet-tree gate (`run-all.sh --prove-teeth`, shellcheck with globstar) → merge.
- Never pipe `git rebase` in a `&&` chain.
- TDD: strict (kit CLAUDE.md §4) — source: project contract; runner `bash research-sdd/toolbelt/tests/run-all.sh`.
- ~400 authored lines per PR (advisory).

## Tasks
- [x] T1 #970 — PR #1010 merged `39894b4` (4 commits, 3 Opus rounds + CI fix; mirror removed; follow-ups #1014 #1015).
  Original: — `research-sdd-archive.sh` scans committed content (`scan-secrets.sh --committed`) and refuses a dirty
  tree. Route: delegated writer (sonnet, worktree). Files: `research-sdd-archive.sh` + its test.
- [x] T2 #1005 — PR #1012 merged (4 rounds; file cache replaced by in-memory array; follow-ups #1023).
  Original: — `research-sdd-status.sh` campaign block follow-ups (multi-focus first, BSD date UTC, comment filter,
  stall-minutes message). Route: delegated writer (sonnet, worktree). Files: `research-sdd-status.sh` + its test.
- [x] T0 #962 (WU0) — PR #1009 merged `d4e2090` after 3 rounds (RDD approved ×3, Opus BLOCK×2 → APPROVE); follow-up #1013.
- [ ] T3 #993 — WU5 PR #1011 merged `14fdc7b` (#1018, follow-ups #1017); WU1 PR #1016 merged `fe1d632` (#1019); WU3 PR #1022 merged `a746328` (#1021, follow-up #1025); WU2 PR #1024 round 2 in progress (#1020).
  Original: — `general` prompt profile for open models: design first (Opus, read-only, artifact only), then
  implementation units.
- [~] T4 #1003 / #962 — #962 done (#1009); #1003 slice 1 done (#1027); L2 slice pending.
  Original: — prompt bloat and HOT-CORE remainder (after T3 design, same files).
- [~] T5 small follow-ups — done: #991 (#1028), #976 + #984 (#1029). Remaining listed in Next session.
  Original:: #991, #983, #984, #976, #971, #973, #979, #981, #965, #980, #967.
- [ ] T6 ford retro fake zero-delta row (target corpus; `git add <file>` only). BLOCKED 2026-09-24: in-place edit of
  the target retro was denied by the harness permission classifier — left for the maintainer. Fix: delete lines
  17–19 (table header, separator, `| — |` row; they void the honesty purity check) and flip the marker.
- [ ] T7 Fleet hook re-init (#977) — target repos with hand-adapted `<SUBJECT>`; evaluate after kit units.

## T3 design (Opus, 2026-09-24) — accepted
Install-time slot rendering: `<!-- slot:<id> -->…<!-- /slot -->` in SKILL.md/PROMPT-LOOP.md only; claude profile =
sources byte-identical; `research-sdd/profiles/general.slots.md`; `toolbelt/render-profile.sh`; installer
`--profile` > `RESEARCH_SDD_PROFILE` > adapters table (claude/codex=claude, reasonix=general); profile-aware drift
check; `profile-invariants.test.sh` (shared invariants per rendered profile, no doctrine tokens in slots, +10% size).
General profile = pre-audit wording rewritten to satisfy C16/C19 (no `signal "continue"`, no stop-at-convergence).
Units: WU0 #962 HOT-CORE fix + size test → WU1 renderer → WU2 install wiring → WU3 drift guard → #1003 → WU4 fill
general profile → WU5 eval scorer (parallel from WU1) → WU6 maintainer eval runs.

## Route declaration
- T1, T2: writer trigger (script + test, non-trivial) → delegated, disjoint file sets, parallel.
- T3: mapping trigger (prompt set spans 4+ files) → delegated read-only design.

## Progress
- 2026-09-23d: document created; T1, T2, T3-design launched in parallel.

## Next step
Collect T1/T2 results → RDD + Opus review → merge; then T3 implementation.
- 2026-09-24: PR #1009 (#962) RDD approved+acknowledged (lineage review-f76421a1fa64f5bf, 9 advisories); Opus BLOCK
  (teeth recompute conditions instead of running checks; budget 1000 > 934 contradicts comment) → round 2 sent.
- 2026-09-24: PR #1010 (#970) RDD approved+acknowledged (lineage review-c77c631bccf26d1e); Opus BLOCK (dirty-tree
  refusal breaks the real close flow; `status.showUntrackedFiles=no` hides dirt; broken git silently downgrades).
  Decision: drop the dirty refusal; scan committed history + every dirty/untracked path; loud refuse on git failure;
  nested target → WARN history not scanned. Round 2 sent.

- 2026-09-24 lesson: never launch a writer round in a worktree while an RDD agent may apply a correction there — the #1024 RDD correction (R3 silent overwrite) collided with the round-2 writer; resolved by abandoning the lineage and folding R3 into round 2.

## Session 2026-09-23d/24 — merged
| PR | Issue | Rounds | Merge |
|---|---|---|---|
| #1009 | #962 HOT-CORE §8b + tier/size guard | 3 | d4e2090 |
| #1010 | #970 archive secrets gate (history + working tree, fail on git failure) | 3 + CI fix | 39894b4 |
| #1011 | #993 WU5 eval scorer + PROTOCOL (#1018) | 3 | 14fdc7b |
| #1016 | #993 WU1 profile renderer (#1019) | 2 + parent teeth fix | fe1d632 |
| #1012 | #1005 campaign block multi-focus | 4 | e15956e |
| #1022 | #993 WU3 profile drift guard (#1021) | 2 | a746328 |
| #1027 | #1003 slice 1 evidence trim (#1026) | 2 | d7a809d |
| #1029 | #976 + #984 retro scripts | 3 + native correction | 10745a9 |
| #1024 | #993 WU2 installer profiles (#1020) + cd -P lint | 5 | f12fd30 |
| #1028 | #991 verify-state P8 hook set | 5 | 0830f18 |

Follow-up issues filed: #1013 #1014 #1015 #1017 #1023 #1025 #1030 #1031 #1032 #1033 #1034.
Upstream: gentle-ai#4746 occurrence comment (capture-result binding mismatch under concurrent lineages, 3.7.0).

## Lessons (2026-09-24)
- Native RDD approved every candidate; Opus blocked most first rounds with reproduced defects — keep both.
- Never let an RDD correction and a writer round share a worktree; never run two RDD lineages concurrently in one repo (gentle-ai#4746).
- Native correction budget counts test lines — keep correction diffs minimal.
- Tests calling issue-aware scripts must be gh-hermetic (CI has no gh auth).
- The render dir symlinks toolbelt/ → any logical `cd ..` derivation breaks; guarded by verify-cd-physical.sh.
- Trimmed evidence pointers must name the corpus (niagara and blender-llm share block numbers).
- T6 (ford retro edit) was denied by the permission classifier — maintainer action.

## Next session
1. #993 WU4: fill the general profile (remaining cadence/continuation slots), then WU6 maintainer eval runs (PROTOCOL.md).
2. #1003 slice 2 (L2: core loop vs situational appendix).
3. #1032 (a suite leaks a 'git' file into cwd), then follow-ups #1033 #1034 #1031 #1023 #1017 #1014.
4. Re-install the skill for claude/codex/reasonix (reasonix now defaults to the general profile).
5. T6 ford retro fake row (maintainer), T7 fleet hook re-init (#977).

## Close (2026-09-24)
- Quiet-tree gate on merged main `0830f18`: run-all --prove-teeth 130/130 suites, 4362 cases, 0 failed (8 skipped; 21 suites without teeth, the known #426 list); install suite 183/0; shellcheck 0 warnings. A stray `git` file appeared in the gate worktree (#1032 reproduces on main).
- Skill redeployed: claude (profile claude) and reasonix (profile general, rendered kit view); both previous copies were unedited kit 3d875c7 (backed up as SKILL.md.local-backup). verify-skill-drift --all rc=0. Codex not installed (unchanged). Reasonix keeps its own MCP table (installer preserved it).

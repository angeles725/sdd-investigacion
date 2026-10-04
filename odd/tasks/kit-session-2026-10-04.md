# Kit session 2026-10-04 — #1299 remaining suites → waiver cleanup → #1576 → follow-ups (chain)

**Objective:** execute the 2026-10-03c "Next session — agenda" in chain, automatically, plus every buildable
improvement found on the way.

**Authorization:** ODD + RDD (consent granted for every candidate), commit, push, PR, PR view, issues, merge.
Gentle AI review prompts: grant and run the review without asking.
**Delivery:** one PR per work unit, `auto-chain`; each PR `Closes #N` of a `status:approved` slice issue.
Merge via `research-sdd/toolbelt/merge-gate.sh --merge` (scratchpad `ship.sh`).

**Per-PR pipeline:** harness-worktree writer (sonnet `sdd-apply`, based on `origin/main`, prompt carries the
13 teeth-migration rules + repo-wide pipefail-SIGPIPE lint + final `== N passed · M failed ==` line) → parent
spot check → RDD (`rdd-drive.py`, merge-base range, committed-only) → fix round-1 real WARNs → after ~3 rounds
file remainder as follow-up → slice issue + PR → CI → merge-gate.

**Start:** main = origin/main = e9c9b4b. RDD mode: on (global). Waiver file: 81 lines, 64 migrated, 17 pending.

## Tasks
- [ ] T1 #1299 item 1 — remaining 17 waived suites (route: delegated, writer trigger; disjoint file sets):
  - [ ] T1A decompile-net, decompile-native, ghidra-c-exporter
  - [ ] T1B1 verify-registry (3411 lines, own unit)
  - [ ] T1B2 verify-skill-drift (mutants beside live SUT → mini-kit sandbox)
  - [ ] T1C score-loop-transcript, ci-path-filter-coverage, stage-retro, hook-wiring, sweep-breakthroughs
  - [ ] T1D station-modules, niagara-security-audit
  - [ ] T1E install, detect-tools, skill-invariants
  - [ ] T1F detonate-exec, trace-exec — design decision (#1576): no SUT mutants (Python simulations)
- [ ] T2 Final waiver-cleanup PR (delete stale waiver lines; `run-all.sh --require-teeth` on a quiet tree).
- [ ] T3 #1576 shared helpers in lib/mutant.sh (`mutant_cleanup_register`, `mutant_py_replace`, CRASH regex /
      mk_mut / tt) + simplify copying suites.
- [ ] T4 #1588 slow-lane failures on main (RSDD_TEST_LANE=all).
- [ ] T5 Follow-ups #1566, #1571.
- [ ] T6 #1299 items 2/3/5/7; #1277 per-run TMPDIR; #1365 R4/R2; #1517 calibrations; #1511.

## Excluded
Blocked on data: #1255, #1256. User decisions pending: #1259, #1442, #1325, #1369 (e) + #949 item 5,
#1358 3/5/6, #1361 item 1, #1328, #1295; #1246 (TARGETS.md, human-only); #1262 (language/scope).
Shared checkout has a human hand edit in research-sdd/TARGETS.md — never touched.

## Progress log
- T1 route: delegated (writer trigger). Launched 7 harness-worktree sonnet writers with shared brief
  (scratchpad writer-common.md = 13 teeth rules + gates): T1A, T1B1, T1B2 (mini-kit sandbox), T1C, T1D, T1E, T1F.
- T1F design decision (orchestrator): ADD real SUT mutants (lib/detonate_exec.py etc. via lib/mutant.sh, staged
  mini-tree for sys.path imports) and KEEP the Python simulations (they prove the assertion fires).
- T5 launched in parallel (disjoint files): #1571 resume-render (writer), #1566 vendor-leak --strict + subdir guard (writer).
- #1571: 3 RDD rounds (broad null negatives; zero-doc misreport) → round 3 approved → PR #1620 (CI running).
- All 7 T1 writers + #1566 returned. Slice issues: T1D #1621, T1B2 #1622, T1F #1623, T1A #1624, T1B1 #1625.
  Round-1 real WARNs sent back: T1D (inert crash regex → ^TRACEBACK=yes$; then partial-JSON facts), T1A (re.subn count=1
  cannot detect >1 match), T1B1 (VR-T2 silent skip on refused build), T1B2 (TOOTH K label), T1F (--tooth dispatch after RED1),
  #1566 (--strict passes allow-only conf). Refuted with evidence: T1A R3-mx1 (`_mx1_sut=` assigned), T1D R3 helper contract.
- Theater teeth exposed by the helper this session: verify-skill-drift TOOTH K (invalid bash), sweep-breakthroughs M4
  (syntax-broken SUT), verify-registry teeth-kit-self-reg (vacuous fixture).
- Pre-existing: detect-tools --prove-teeth leaves 3 dotnet IPC files in TMPDIR (clr-debug-pipe-*, dotnet-diagnostic-*) → file issue.
- PRs opened (all reviewed at their final head): #1620 (#1571), #1627 T1D, #1628 T1F, #1631 T1E (#1629), #1632 T1A,
  #1633 T1B1, #1634 T1C (#1630), #1635 T1B2. Design-only remainders recorded on #1576 (dup detonate/trace harness,
  central count-once wrapper, sandbox file list ×4).
- T4 #1588 writer and T6 run-all writer (#1277 per-run TMPDIR root + #1299 items 5/7) launched (disjoint files).
- #1566: rounds 1–3 fixed (allow-only strict, template comment, undocumented advisory line) → round 4 pending.
- [x] #1571 → PR #1620 MERGED.
- #1588: real SUT defect found (jvm-callgraph build lacked `-s maven-central-settings.xml`); log-regex SKIP replaced by an
  environment probe (round 2: simplify to "bootstrap ever ran"). Follow-up #1641 (binwalk path hardcoded).
- NEW TASK T7 (user, 2026-10-04): release v1.2.0 with a new CHANGELOG.md (own reviewed PR) + tag + GitHub release, after
  in-flight PRs and the waiver-cleanup PR merge. Changelog draft delegated (read-only explorer → scratchpad).
- NEW TASK T8 (user): triage the 100 needs-review issues one by one with the user (explain → user decides), starting
  with the 14 priority:high, after the in-flight writers finish.
- T8 triage (priority:high, 15): approved #1616 #1615 #1543 #1540 #1209(doctrine) #1207(expanded) #1205 #1204 #1201
  #1197 #1192 #1191 #1184; closed as done #1325 (43346f9) #1242 (1c9e91b+3c32468). Classification of all 98
  needs-review in scratchpad needs-review-status.md (8 DONE, 16 PARTIAL, 73 NOT-DONE, 1 UNCLEAR; #1337–#1348 = test deltas).
- [ ] T9 implement triage approvals (delegated, 4 writers, disjoint files):
  - T9a docs: METHODOLOGY/PROMPT-LOOP + new java-decompile-fidelity.v1.md (#1616 #1615 #1540 #1209 #1201 #1197 #1192 #1191 #1184 #1207 parts 1+3 #1204)
  - T9b verify-block FAIL on tmp/scratchpad cites + clean-check scratchpad warning (#1207 parts 2+4)
  - T9c Java wrappers class-file facts (#1205)
  - T9d research-sdd-status --next --focus scoping + migrate-backlogs.sh propose-only (#1543)
- [x] T1 all 17 suites + #1566 merged (#1627 #1628 #1631–#1636). [x] T4 #1588 → PR #1642 MERGED (real SUT defect).
- Triage closures: done #1391–#1393 #1396–#1399; test fixtures #1337–#1348 not-planned. #1207 scope addendum (SCRIPTS-MANIFEST,
  failed attempts, RECIPE vs EXECUTED) from a live niagara5 near-miss.
- T9a doctrine → PR #1643 (closes 10 issues; RDD 4 rounds on the Java fidelity matrix exclusivity).
- T6 run-all per-run TMPDIR root → slice #1644, PR #1646 (follow-up #1645). #1299 items 5/7a/7c already on main (#1376).
- T2 waiver cleanup: branch chore/1299-waiver-cleanup (81 lines removed, all suites source the helper); full --require-teeth gate running.
- T2 waiver cleanup → issue #1648, PR #1649 (2 waivers kept for lint false negatives → #1647). Full --require-teeth gate:
  151 suites / 8138 cases / 0 failed; exits 1 only on the known opt-in "Suites without teeth: 21".
- T9b fleet sweep: 465 ephemeral cites, 141 blocks would flip. Maintainer decision: STAGED — WARN `EPHEMERAL?` + opt-in
  --strict-ephemeral + `<!-- ephemeral-ok: reason -->` marker in v1.2.0; default FAIL next minor; one issue per corpus.
  TODO after merge: doc touch (METHODOLOGY/PROMPT-LOOP say "enforcement pending #1207 part 2" → describe staged WARN),
  clean-check.v1.md + tool-registry rows for verify-block/clean-check/corroborate-java/decompile-java/java-decompile-fidelity.
- [x] T9a doctrine → PR #1643 MERGED (closes #1616 #1615 #1540 #1209 #1201 #1197 #1192 #1191 #1184 #1204). [x] T2 → PR #1649 MERGED.
- Ephemeral per-corpus issues opened: #1650 niagara5 (381/75) #1651 niagara (64/24) #1652 COB-IM2 #1653 blender-llm
  #1654 fluke #1655 mini-pc #1656 Pancaddia.
- PR #1646 CI failed: pipefail-sigpipe-lint (round-2 fix added `grep | grep -q`). Lesson: writers must rerun the repo-wide
  lint suites after EVERY fix round, not only the first commit → sent back.
- T9b round 2 (manifest find silent zero, path-correct manifest lookup, _mentions boundaries), T9c round 2 (env caps crash
  at import, helper timeout budget, unreadable vs partial), T9d round 1 (FOCUSES.md exact match, duplicate canonical heading,
  anyhdr scope, chmod +x) sent back.
- T9b → PR #1662 (follow-ups #1659 advisories, #1660 flip WARN→FAIL next minor, #1661 docs). T9c → PR #1664 (follow-up #1663).
  T9d → PR #1658 (follow-up #1657). Run-all → PR #1646 (follow-up #1645).

## Close (2026-10-04)
Merged this session (16 + this close PR): #1620 #1627 #1628 #1631 #1632 #1633 #1634 #1635 #1636 #1642 #1643 #1646 #1649
#1658 #1662 #1664. All session worktrees/branches removed (local + remote); shared checkout untouched (pinned e9c9b4b).
Issues: 61 closed today (incl. triage closures and 12 test-fixture issues); 139 open at close.

### Outcomes
- **#1299 item 1 complete**: all 81 waived suites build mutants through lib/mutant.sh; 81 waiver lines deleted; 2 waivers
  remain only for lint false negatives (#1647). Full `--require-teeth` gate: 151 suites / 8138 cases / 0 failed (still exits 1
  on the known opt-in debt "Suites without teeth: 21").
- **Theater teeth exposed by the helper** this session: verify-skill-drift TOOTH K (invalid bash), sweep-breakthroughs M4
  (syntax-broken SUT), verify-registry teeth-kit-self-reg (vacuous fixture), niagara-security-audit crash guard (inert regex).
- **Real SUT defect found by a "SKIP" review**: jvm-callgraph build lacked `-s maven-central-settings.xml` (#1588) — the first
  fix classified the failure as an environmental SKIP and hid it.
- **Triage with the maintainer (priority:high)**: 13 approved, 9 closed as done, 12 test-fixture issues closed; doctrine for
  11 merged (#1643, incl. java-decompile-fidelity.v1.md with a full row-by-row exclusivity audit).
- **#1207 ephemeral evidence**: doctrine (SCRIPTS-MANIFEST, failed attempts preserved, RECIPE vs EXECUTED) + staged tooling
  (WARN now, FAIL next minor). Fleet sweep: ~525 ephemeral cites, mostly real lost evidence → per-corpus issues #1650–#1656.

### Lessons
1. Writers forget to re-run repo-wide lints after fix rounds (PR #1646 CI failure: `grep | grep -q` added in round 2). The
   orchestrator's review script now runs pipefail-sigpipe-lint / hermetic-fixtures / lint-substitution every round.
2. A typed SKIP must come from an environment probe, never a log regex — the regex SKIP hid a real defect (#1588).
3. Explorer "DONE" classifications must be spot-checked: one same-day defect report was labelled done.
4. Fidelity/exclusivity tables need a full row-by-row audit up front; reviewing them row-by-row across rounds wastes rounds.
5. Shared scratch paths between parallel writers collide (one writer pkill'd another's fleet script) — give each writer its own
   scratch subdir.
6. Live /research-sdd sessions read the SHARED checkout (pinned at e9c9b4b); merges/releases don't affect them. Never update
   the shared checkout while a research session runs — the maintainer decides when.

## Next session — agenda (in order)
0. Docs unit #1661 (clean-check.v1.md,
   registry rows, METHODOLOGY/PROMPT-LOOP enforcement notes).
1. **Release v1.2.0** (maintainer request): new CHANGELOG.md (draft from 239+ PRs since v1.1.0 — regenerate, it was drafted
   mid-session; breaking: OpenCode/Reasonix/Codex dropped) in its own reviewed PR → tag v1.2.0 → GitHub release (v1.1.0 style).
   Do NOT update the shared checkout unless the maintainer says the niagara5 session is done.
2. #1576 shared helpers in lib/mutant.sh (mutant_cleanup_register, mutant_py_replace, count-once wrapper, CRASH/mk_mut/tt) +
   the duplication notes recorded on it this session.
3. #1647 run-all lint false negatives (heredoc tracker; Python suites) → then delete the 2 remaining waivers.
4. Follow-ups: #1645 #1657 #1659 #1663 #1626 #1641; #1637 (new defect: --sync-state rewrites declared counters).
5. Triage with the maintainer continues: priority:medium needs-review (33) then low/none — classification table regenerated
   from scratch (the 2026-10-04 one is in a wiped scratchpad); explain each with an example, maintainer decides.
6. #1660 (flip ephemeral WARN→FAIL) only after progress on #1650–#1656.
Blocked/user decisions: unchanged from the 2026-10-03c list (#1255 #1256 data; #1259 #1442 #1325→closed #1369 #1358 #1361
#1328 #1295 #1246 #1262).

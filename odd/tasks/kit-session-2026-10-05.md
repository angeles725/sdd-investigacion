# Kit session 2026-10-05 — target wiring (W3), reinstall (R1), follow-up chain, needs-review triage

Engram mirror: `odd/kit-session-2026-10-05/tasks` (project sdd-investigacion).
Operational resume file (agent ids, worktrees, ship scripts): scratchpad `RESUME-2026-10-05.md` of session 07bf93fb.

## Objective
Wire every present target (W3), reinstall the harness homes (R1), close the approved follow-up queue, triage the
34 `status:needs-review` issues with the maintainer two at a time, then "fix everything" left open by the day's work.

## Authorization
Maintainer (2026-10-05): ODD + RDD all granted; commit, push, PR, PR view, issues and merge authorized; gentle-ai
review prompts granted; chain automatically; later "corrige todo lo que tengas que corregir". Triage decisions are
the maintainer's (recorded per issue as a "Maintainer decision 2026-10-05" comment).

## Constraints
- Kit CLAUDE.md: harness-worktree writers on origin/main, disjoint file sets, strict TDD + teeth, ~400 lines/PR.
- HOT-CORE budget (`hotcore-budget` T7) is 920/920: never grow §1 §2 §3 §4 §7 §8 §8b §9 §11 §17; never rewrap to fit.
- RDD cap ~3 rounds; destructive/correctness WARNINGs get one extra surgical fix; remainder filed as follow-up.
- PR bodies must not reference closed/merged-into issues (Check Issue Has status:approved fails).
- Doctrine describes merged code only (skip sections whose PR is not on origin/main).

## Delivery strategy
`auto-chain`, `stacked-to-main` (one PR per work unit against main).

## Tasks (route: D = delegated writer, I = inline)
### Rollout
- [x] W3 — shared checkout ff to origin/main 6aec1dbb; `research-sdd-init.sh --wire` on 17 present targets (kit repo excluded), all rc=0, settings backed up. All 17: return-token gate + pkill-guard. SessionStart wired on 5; 12 skipped (unadapted `<SUBJECT>` in research-protocol.sh). Route I.
- [x] R1 — `research-sdd-install.sh` all harnesses rc=0; `--verify` match for claude/pi/gentle-shell; kit current. Route I.
- [ ] W3b — re-run `--wire` on the 17 targets after PR #1807 (drift hook + pre-push) merges. Route I.
- [ ] W3c — adapt `<SUBJECT>` in research-protocol.sh for the 12 targets (human/judgment, per target).

### Follow-up queue (merged)
- [x] F #1747 → #1777 · [x] C #1766 → #1779 · [x] E #1770/#1771 → #1783 · [x] H1 #1711 s2 → #1781 · [x] B #1757 → #1778
- [x] A #1752/#1773 → #1785 · [x] D #1768 → #1791 · [x] H2 #1711 s3 → #1794 · [x] I2 #1271 doc → #1786
- [x] U3 lint-substitution CI → #1788 · [x] U2 sweep-all drift → #1789 · [x] U4 verify-corrections advisory → #1803
- [x] I1 #1277 s2 → #1801 · [x] G #1709 s2 regressed → #1806 · [x] D1 doctrine catch-up (closes #1173) → #1809

### Triage-approved work (merged)
- [x] #1613 → #1802 · [x] #1606 → #1795 · [x] #1173 → #1799 (+#1809) · [x] #1394/#1388 → #1798
- [x] #1389 → #1792 · [x] #1328 → #1796 · [x] #1178 → #1805

### In flight
- [ ] U1 #1787 item1 + #1271 pre-push — PR #1807 (final forced round; pre-push scans every pushed commit's changed blobs).
- [ ] J7 #1638 — PR #1810 (re-typed rows: per-row WARN in status + verify-state, aligned with §8b).
- [ ] J6 #1259 — unclassifiable table + tracker; final surgical fix + R2-002 merge of lookup helpers (writer).
- [ ] F1 #1784 + #1811 reconcile-issues (+ lib/retro-grammar.sh) · [ ] F2 #1780 verify-registry · [ ] F3 #1782 drift-hook tests
- [ ] F4 #1793 append-iteration-row · [ ] F5 #1797 powershell test · [ ] F6 #1790 verify-corrections false positive + fleet table
- [ ] F7 approved doctrine (#1808 #1208 #1175 #1185 #1186 #1187 #1179 #1096 #1385 #1542 #1094 #980) · [ ] F8 #1711 resume-state jq args

### Queued (blocked on a file in flight)
- [ ] #1800 + #1804 init (vendor-leak on wire-only path; .gitignore `.research-sdd/plan/`) — after #1807.
- [ ] #1277 follow-ups (status.sh unverified call site, `0[0]*` glob) — after #1810.
- [ ] Doctrine for init drift/pre-push, #1709 §18 regressed, #1259, #1638 §8b line — texts in scratchpad `doctrine-pending.md`; apply after their PRs merge.
- [ ] #1214 (rule pack under #1365) — backlog, no writer today.

### Needs-review triage (DONE — 0 left)
Approved (22): #1613 #1638 #1606 #1173 #1208 #1394 #1388 #1389 #1259 #980 #1328 #1214 #1178 #1175 #1185 #1186 #1187 #1179 #1096 #1385 #1542 #1094.
Merged-into (4): #1198→#1606 · #1189→#1173 · #1390→#1389 · #1607→#1548. Already done (2): #1295 #1246.
Dismissed/deferred (6): #896 #1180 #1610 #1255 #1256 #1262.

## Follow-up issues filed today
#1780 #1782 #1784 #1787 (unwired-mechanisms tracking) #1790 #1793 #1797 #1800 #1804 #1808 #1811 #1812 (needs-review:
closure-evidence rule gives shipped=0 fleet-wide).

## Findings worth keeping
- Unwired re-audit: stale-KIT warning only in kit repo (fixed by #1807), sweep-all omitted drift (#1789), lint-substitution unwired (#1788), verify-corrections no caller (#1803; gate blocked on #1790).
- `reconcile-issues --all`: shipped=0, borderline=112 across 186 retros → #1812.
- verify-corrections fleet: 7/19 targets exit 1, one verified wrapped-line false positive → #1790.
- #1259 fleet: 10 retros with unclassifiable deltas (niagara-research 6, panccadia-3d-viewer 3, Pancaddia 1); 4/4 sampled true.
- WSL host: timed waits stall ~3.7 s ≈1/250 (H4e root cause).

## Next step
Finish in-flight units (ship each through rdd-ship/ship-wait → merge-gate), then the queued init/status/doctrine units,
W3b re-wire, close this doc (Close section) and update the next-session agenda memory.

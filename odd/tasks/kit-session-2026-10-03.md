# Kit session 2026-10-03

**Objective:** execute the 2026-10-02b agenda in chain, automatically: unit A docs, #1463, #1299 2–7,
follow-ups #1455/#1469/#1472, then backlog waves M2–M5 (only parts with no pending user decision).

**Authorization:** ODD + RDD (consent granted for every candidate), commit, push, PR, issues, merge.
**Delivery:** one PR per work unit, `auto-chain` strategy; each PR needs `Closes #N` of a `status:approved`
issue (create a slice issue for partial epics). Merge via `merge-gate.sh --merge`.

**Per-PR pipeline:** harness-worktree writer (sonnet `sdd-apply`) → parent spot check → full-range RDD
(`--base-ref <merge-base> --committed-only`, driver `scratchpad/rdd-drive.sh`) → fix real WARNs → PR →
CI → merge-gate.

## Tasks
- [x] T1 Unit A docs (8e9118c → rebased) — route: inline (already written). RDD medium, approved
      (review-bb227cd93d951498, 2 informational). PR #1477, slice issue #1478. Merge: pending CI.
- [x] T2 #1299(a) `lib/mutant.sh` MUTANT_TOOTH_DEBUG + teeth for codes 2/6 — delegated writer B (worktree).
- [x] T3 #1469 + #1472 + #1299(c) install-suite pins/portability — delegated writer C (one file, one writer).
- [x] T4 #1455 ci-path-filter UNCLASSIFIED → rc 2 — delegated writer D.
- [x] T5 #1228 verify-sources LEVEL 6 path form (M4) — delegated writer F (probe viability first).
- [x] T6 #1463 `run-all.sh -j N` — after T2–T5 (needs quiet-tree serial baseline; yield may be ~1.3x).
- [ ] T7 #1299(b) item 4 `--require-teeth` lint gate + run-all guard gaps — after T6 (same file).
- [ ] T8 #1299 items 2–3 — probe yield first (2026-10-02 probe found little).
- [x] T9 M2+M3 doctrine waves — ONE writer (hot-core budget 920 lines, hotcore-budget.test.sh).
- [x] T10 M4 rest (#1255 #1256 #1259 #1260 #1261 #1365) and M5 (#1293 #1271 #1262 #1274–#1277 #1244 #1245).
- [x] T11 Verify + close #1459–#1462 if resolved by #1465.

Route evidence: explorer map (2026-10-03) — writers B, C, D, F hold pairwise-disjoint file sets (§3).

## Pending user decisions (excluded)
#1442, #1325 (artifact-cite fallback, P6 WARN), #1369 (e) + #949 item 5, #1358 3/5/6, #1361 item 1, #1328, #1295.

## Progress log
- T1: CI issue-reference check failed on `Refs` only → created slice issue #1478, PR body now `Closes #1478`.
- T2: 73e7d09+bdc5dc1, RDD high approved ×2 → PR #1481 (slice issue #1480); advisories → #1479.
- T3: 7898358+a114a77+71e4ba9, RDD high approved ×2, clean → PR #1484 (Closes #1469 #1472).
- T4: a1439e8+aa109fb, RDD high approved ×2 (quote-aware strip fix) → PR #1482 (Closes #1455); advisories+item 3 → #1479.
- T5: 0ceb098, RDD high approved clean; fleet exit vector unchanged, 1 true fix → PR #1485 (Closes #1228); follow-up #1483.
- T11: #1459–#1462 closed as resolved by #1465 (e1b108f).
- Policy: one fix-first round per PR on real WARNs; second-round advisories filed, not looped.
- T6: writer A launched (measure-first, viability ≥1.5x projected).
- Merged: #1477, #1481, #1484, #1485, #1486. #1482 fixed for pipefail-SIGPIPE lint (a969da6) — CI failure root: writer did not run the repo-wide lint; now in every writer prompt.
- T9 M2: PR #1486 merged (8 applied; #1219 #1238 #1239 #1231 closed as already applied). M3: PR #1489 (10 closed, #1215/#1242 doc halves; code halves #1488/#1487).
- T6 #1463: viable (projected 5.5x; measured serial 884 s vs -j 6 277 s = 3.2x, identical aggregate). PR #1490, RDD ×2; follow-ups #1491.
- T10 M4 (writer G): #1261 done, #1260 partial (stage-retro-issues.sh); #1259 #1365 #1255 #1256 #1283 #1284 deferred (over budget / new tools / doctrine-first / owner decision on per-retro issue creation for #1259). Fleet dry-run byte-identical.
- #1479 writer I: mutant.test.sh half committed; ci-path-filter half waits on #1482 merge.
- M5 triage: #1293 #1326 closed as already applied. Doctrine → PR #1494 (10 issues). Code: #1245 + #1244 → PR #1497; its first-round WARNs were merged unfixed (pipeline defect, see Lessons) and fixed in #1501 (#1499) and #1503 (#1502). #1487 → #1498 (fix round: per-line waiver), follow-ups #1504 (#1500).
- #1479 advisories → PR #1495.

## Outcome (close 2026-10-03)
16 PRs merged: #1477 #1481 #1482 #1484 #1485 #1486 #1489 #1490 #1493 #1494 #1495 #1497 #1498 #1501 #1503 #1504,
plus this close PR. ~60 issues closed (incl. already-applied: #1219 #1231 #1238 #1239 #1293 #1326 #1459–#1462).
Gate: `run-all.sh -j 6` measured 277 s vs 884 s serial (3.2x), identical aggregate.

## Lessons
1. An approved RDD with WARNINGs is not clean. The auto-merge pipeline must stop before the PR on the FIRST
   round (fix-first); only after one fix round may remaining advisories be filed and merged. #1497 shipped a
   credential-bearing URL in `gh` argv because the pipeline merged on "ACKNOWLEDGED" alone.
2. Every writer that touches shell must run `pipefail-sigpipe-lint.test.sh`: #1482 passed its own suite,
   teeth, shellcheck and RDD, then failed CI on a `producer | grep -q` line.
3. Polling `gh pr checks` from several loops at 30–60 s exhausted the API budget; `merge-gate` then reports
   `degraded: cannot read PR` — treat it as transient and retry at ≥180 s.
4. Never rewrite a script in place (`open(p,'w')` keeps the inode) while a background bash is executing it.
5. Triage first: 4 of 13 M2 issues and 2 of 20 M5 issues were already encoded on main.

## Next session — agenda (in order)
1. #1299(b) item 4: `--require-teeth` lint as an exit-1 gate + remaining run-all guard gaps (T7); #1299 items 2–3 after a yield probe (T8).
2. #1491 run-all `-j` follow-ups (per-suite leak attribution, DEGRADED reason, full `--prove-teeth -j 6`).
3. #1496 wire the pkill-guard hook in `research-sdd-init.sh`; #1492 (#1260 halves); #1483 (non-web `sources/<f>` rows; calibration change — own unit); #1488 (java-fidelity experiment script).
4. M4 deferred: #1365 lint-block slice 2+, #1255, #1256, #1283, #1284 (doctrine first), M5 code: #1271 leak guard, #1277 clean-check, #1262, #1274, #1276 slicing script.
User decisions pending: #1259 (open one issue per unclassifiable retro?), #1442, #1325, #1369 (e) + #949 item 5, #1358 3/5/6, #1361 item 1, #1328, #1295; #1246 needs a TARGETS.md schema change (human-only edit).

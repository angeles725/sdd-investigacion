# Kit session 2026-10-03b — agenda chain

**Objective:** execute the 2026-10-03 "Next session — agenda" in chain, automatically: #1299 items 4/5/7,
#1491, #1496, #1492, #1483 (own unit), #1488, then M4/M5 deferrals that are buildable without a pending
user decision.

**Authorization:** ODD + RDD (consent granted for every candidate), commit, push, PR, PR view, issues,
merge. Gentle AI review prompts: grant and run the review without asking.
**Delivery:** one PR per work unit, `auto-chain`; each PR `Closes #N` of a `status:approved` issue (slice
issue for partial epics). Merge via `research-sdd/toolbelt/merge-gate.sh --merge`.

**Per-PR pipeline:** harness-worktree writer (sonnet `sdd-apply`, prompt includes the repo-wide
pipefail-SIGPIPE lint) → parent spot check → full-range RDD (`--base-ref <merge-base> --committed-only`)
→ first-round real WARNs: fix-first, no PR → PR → CI → merge-gate.

## Tasks
- [x] T1 #1299 items 4/5/7 — PR #1515 (slice issue #1513) — `--require-teeth` helper-lint gate, lint precision, kit-tree guard gaps (run-all.sh).
- [x] T2 #1491 run-all `-j` follow-ups — PR #1537.
- [x] T3 #1496 wire pkill-guard — PR #1510; follow-up #1509 → PR #1551.
- [x] T4 #1492 — PR #1520.
- [x] T5 #1483 — PR #1508 (count-only; hash-verify stays a calibration unit).
- [x] T6 #1488 — PR #1525.
- [x] T7 M4/M5 deferrals — #1283 PR #1512 (+#1511 → #1539), #1365 slice 1 PR #1518 (+#1517 slice → #1549), #1271 slice 1 PR #1523 (+#1522 → #1546), #1277 slice 1 PR #1528, #1276 PR #1530, #1274 slice 1 PR #1533, #1284 PR #1535; #1255/#1256 not built (yield 0 / probe failed); #1262 deferred. (#1365 #1255 #1256 #1283 #1284 #1271 #1277 #1262 #1274 #1276) — triage
      needs-review issues, build what has no pending user decision.

## Pending user decisions (excluded)
#1259, #1442, #1325, #1369 (e) + #949 item 5, #1358 3/5/6, #1361 item 1, #1328, #1295; #1246 (TARGETS.md schema, human-only).

## Progress log
- Start: main = origin/main = cf33b31. `--require-teeth` exit-1 gate already exists (SENTINEL-REQUIRE-TEETH-EXIT);
  #1299 remaining = items 4 (helper lint promotion), 5 (lint precision), 7 (guard gaps; codes 2/6 done in #1481).
- Batch 1 launched (harness worktrees, disjoint sets): T1 #1299, T3 #1496, T4 #1492, T5 #1483 — route: delegated (writer trigger, 2+ files each).
- Triage explorer (M4/M5 + #1488): buildable now #1283, #1488, #1365 slice 1 (launched as batch 2); #1255 yield 0 (largest bog ~3 KB) → commented, not built;
  #1256 probe-first (real .hdb under distech-merida-harbor); doctrine/user-decision: #1271 (vendor prefix declaration), #1277 (keep-list format, stale age),
  #1284 (owned fields, in-place vs patch), #1274 (state.json schema), #1276 (lens budget value), #1365 R4 convention, #1262 (scope; after #1255).
- T3 #1496: 1146a8b + 65fb1f3 (PROMPT-LOOP doc, inline). RDD approved but 3 first-round WARNs (scaffold --wire dedup exact-only vs 5-form) → fix-first sent back to writer. Items 2/3 deferred (doctrine-first; needs live session).
- T5 #1483: 84f57d4, count-only (hash-verify = calibration, deferred). Fleet: 2 lines changed, both TRUE, 0 exit flips. RDD approved (2 suggestions). Shipping.
  Deferred doc: METHODOLOGY §5 one-liner on root-form File cells (after #1488 releases METHODOLOGY.md).
- PRs open (CI): #1508 (#1483), #1510 (#1496; follow-up #1509), #1512? (#1283; follow-up #1511), #1515 (#1299 slice issue #1513; follow-up #1514).
- Fix-first round sent back: #1365 slice 1 (empty pack list fails open, R9/R2 collision), #1488 (DEBUGINFO unmeasured→no, engine provenance, real-run accepts all-FAILED; + tool-registry row), #1492 (dead token list, PARTIAL branch unproved).
- #1256 writer launched with a mandatory viability probe (stop with evidence if framing not decodable).
- Driver lesson: re-running rdd-drive restarts its step numbering, so the round-N captures overwrite 05-08.json.
- #1256 probe: proof standard NOT met (epoch offset unresolved; only 1 fixed-width numeric .hdb) → evidence on issue, not built.
- Decisions taken under the "don't ask" authorization (recorded on issues, labels → approved): #1271 slice 1 vendor-leak.conf contract; #1277 slice 1 keep.txt + 24 h stale. Writers launched.
- Merged: #1508 (#1483), #1510 (#1496), #1512 (#1283). In CI: #1515 (#1299 slice), #1518 (#1365 slice 1), #1492 PR, #1271 slice 1 PR, #1488 PR, #1277 slice 1 PR.
- Decisions recorded + writers launched: #1276 (`--max-lines`, default 400), #1284 (diff-only proposer, mechanically recomputable fields), #1274 (git-derived state.json to stdout).
- Next: #1491 after #1515 merges; docs unit (registry rows clean-check / scan-vendor-leak / lint-block --pack, METHODOLOGY §5/§8/§15 texts, seeder/reconcile output) after the code PRs merge; follow-up WARN wave over #1509 #1511 #1514 #1519+ grouped by destination file.
- #1274: RDD round 1 produced 3 corroborated CRITICAL (clean worktree dirty=1) → native correction driven by parent (capture-correction-plan → corrected commit 8bf1c3b → capture-validation → approved → acknowledged); WARNs fixed in 9ebe5a8; round 2 approved → shipping.
- #1276: shipping after round 2. Native-correction lesson: unquoted $args does not word-split in zsh → use a python step helper (scratchpad/rdd-step.py).
- Merged so far: #1508 #1510 #1512 #1515 #1518 #1523. In CI: #1520 #1525 #1528 #1530 #1533 + #1284 PR. #1491 in fix-first.
- Follow-up WARN wave 1 launched (parents merged, disjoint files): #1509 init, #1511 n4-type-catalog, #1522 scan-vendor-leak, #1517 lint-block (advisories only; calibration items stay as own units).
  Pending for wave 2 (after parents merge): #1514 (run-all, after #1491), #1519, #1524, #1527, #1529, #1532, #1534.
- CI lesson: 3 new suites printed a non-contract summary ("malformed summary, exit 0" in run-all) and the #1492 12-char title floor broke retro-gate SL14 → fixed (summary line `== N passed · M failed ==`; fixture widened); re-RDD'd the 4 branches (any commit after an acknowledged review makes merge-gate refuse review_due).
- Follow-up wave 1 (#1509 #1511 #1517-slice #1522): fix-first + round 2 approved, shipped.

- Close: 17 PRs merged (#1508 #1510 #1512 #1515 #1518 #1520 #1523 #1525 #1528 #1530 #1533 #1535 #1537 #1539 #1546 #1549 #1551); origin/main advanced 17 commits from cf33b31.

## Lessons (session 2026-10-03b)
1. A NEW suite must end with exactly `== N passed · M failed ==` (run-all `summary_re`); writers that skip run-all miss it — put it in every new-suite writer prompt.
2. A behaviour change in a shared tool must grep `tests/*.test.sh` for other consumers and run them (stage-retro-issues title floor broke retro-gate).
3. Native RDD correction is drivable by the parent: capture-correction-plan (needs real argv — zsh does not split `$args`) → corrected commit → bound STATUS → capture-validation → acknowledge.
4. Under the "don't ask" authorization, open design questions were decided with doctrine-consistent defaults and recorded on the issue before the writer started (#1271 #1277 #1276 #1284 #1274).
5. Viability probes stopped two units cheaply: #1255 (largest bog 3 KB) and #1256 (hdb epoch offset unresolved).

## Next session — agenda (in order)
1. Follow-up wave 2 (parents now merged): #1514 (run-all helper gate advisories), #1519 (#1492), #1524 (#1488), #1527 (#1277), #1529 (#1276), #1532 (#1274), #1534 (#1284) — group by destination file, one writer each.
2. Docs unit (one writer, doc files only): tool-registry rows for clean-check, scan-vendor-leak, plan-review-slices, resume-state, state-update, lint-block `--pack`; METHODOLOGY §5 (root-form `sources/<f>`), §8/§15 (clean-check terminal trigger, vendor-leak guard), §8b (state-update), §17/§7 (resume-state), §23 (review pipelining); seeder/reconcile output text. Proposed texts are in the writers' reports (PR bodies / follow-up issues).
3. Slice-2 work: #1271 (init seeding + hook + CI wiring for PUBLIC remotes; per-target confs), #1277 (leaking suites / per-run TMPDIR + run-all /tmp assertion, terminal trigger), #1274 (prose handoff from JSON), #1365 (R2 viability probe, R4 doctrine, verify-block wiring), #1517 calibration units (R9 heading units, R5 auth\w*/Bypass, R1 prose FPs, R8 negation filter), #1511 `Flags.A + Flags.B` decode change, #1483 hash-verify non-web rows (calibration).
4. #1299 item 1 (migrate 81 waived suites to lib/mutant.sh; delete waiver lines as they migrate), items 2–3, 6; #1262 (after #1255 data exists).
Blocked on data: #1255 (no large bog), #1256 (numeric .hdb with known write time).
User decisions still pending: #1259, #1442, #1325, #1369 (e) + #949 item 5, #1358 3/5/6, #1361 item 1, #1328, #1295; #1246 (TARGETS.md schema, human-only).

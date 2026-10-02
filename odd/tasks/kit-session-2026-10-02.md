# Kit session 2026-10-02

## Objective
Work the next-session agenda from `kit-session-2026-10-01b.md` in order, chained and automatic,
plus the improvement items surfaced in prior sessions.

## Authorization
User granted: ODD + RDD (consent granted for every candidate), commit, push, PR create/view, issues,
merge; chain automatically; do not ask; accept Gentle AI prompts and run their review. Mid-session
the user added permission rules for `tests/lib/mutant.sh` edits and the 5 stale-branch deletions.

## TDD
Strict TDD (global CLAUDE.md). Runner: `bash research-sdd/toolbelt/tests/run-all.sh`
(+ `--prove-teeth` / `--require-teeth`), shellcheck gate per kit CLAUDE.md §5.

## Per-PR pipeline (as run)
Triage against `origin/main` → writer in a harness worktree (strict TDD, executed RED, mutants via
`tests/lib/mutant.sh`) → RDD on the merge-base range (scripted driver, consent granted) → Sonnet
adversarial review (Opus weekly limit until 2026-10-03 19:00 America/Mexico_City) → FIX-FIRST →
CI polled until every shellcheck/toolbelt-tests check is `pass` → `merge-gate.sh --merge N`.

## Outcome
- **PRs merged (18):** #1400 (#1373), #1402 (#1352), #1403 (#1356, #1369 part), #1405, #1406
  (#1354), #1407, #1408 (#1350), #1409 (#1367), #1410 (#1358 part), #1411 (#1412), #1414 (#1413),
  #1417 (#1415), #1420 (#1404), #1422 (#1418, #1325 part), #1423 (#1416), #1424 (#1291, #1294,
  #1361 part), #1425 (#1419), #1428 (11 Hilton/niagara5 doctrine deltas; #1293 #1295 #1326 part).
- **#1299 teeth rollout:** yield probe (99 hand-rolled suites, not ~120); 12 suites + 5 sweep hooks +
  5 doc guards migrated to exact GOOD/BAD verdicts; shared `mutant_chain` / `mutant_built` /
  `mutant_tooth` in `tests/lib/mutant.sh` (#1423). Real defects found in old teeth: dead sed stage,
  never-run tooth, syntax-broken mutant accepted as teeth (scan-secrets); tautological teeth
  (wall-protocol-doctrine); vacuous absence tooth (verify-block p9); sentinel that never matched
  (sweep-tools-hook); `rc != N` "any failure" teeth in most migrated suites.
- **Instrument fixes with real-data acceptance:** sync-state keep is bounded but never overwrites
  (keep + WARN when declared exceeds what the parser can count); verify-block target-root resolution
  bounded ($HOME/ancestors refused, project marker required, `ok (target-root)` visible); row-drift
  checker reproduces niagara5's documented 7/12 drifted rows with 0 FP on pending rows.
- **Close gate (quiet tree, origin/main b58027e, `run-all.sh --prove-teeth`):** 140/140 suites,
  6675 cases passed, 0 failed, hermeticity 0/0. Teeth debt: suites not using lib/mutant.sh 99 → 82.
- **Issues filed:** #1401, #1404, #1412, #1413, #1415, #1416, #1418, #1419, #1421, #1426, #1429.
- **Housekeeping:** 5 stale branches verified superseded and deleted; all session PRs labelled; the
  18 session branches verified against their merged PR heads, deleted on origin; 10 local worktrees
  and branches removed. 8 harness worktrees stay locked by this session's process (clean, merged).

## Lessons
- **merge-gate does not gate on CI (#1426):** #1422 was merged while toolbelt-tests was pending,
  because `gh pr checks --watch; merge-gate --merge` continued after `--watch` exited on a network
  blip. Poll until every required check is `pass`; never chain a merge after `--watch`.
- **pr-check metadata is silent drift:** the repo requires one `type:*` label and `Closes #N`; the
  check is not required, so the first 11 PRs lacked both. Slices of an epic get their own issue.
  `gh pr edit` fails (Projects-classic) → use `gh api` REST for labels and bodies.
- **Fleet sweeps keep catching what fixtures miss:** 51 false UNPARSED (row-drift), 4/5 false
  NO-BULLET in the old Python checker, the $HOME-parent false resolution (verify-block).
- **Adversarial reviews found a real defect in most PRs:** silent zero on unreadable files, an eval
  test seam live in production, data-losing overwrite, unbounded root walk, hang on a missing flag
  value, broken-checker exit 1 hidden by its caller.
- **Never `pkill -f` from the harness shell** (the pattern matches the harness's own command line);
  kill by exact PID, parent first, so a `;`-chained merge step cannot run.
- Editing a worktree while its run-all runs makes the kit-tree guard blame whichever suite is active.
- Hot core is at exactly 920/920 lines: new doctrine goes to situational sections.
- **CI path filter gap:** `toolbelt-tests` (and shellcheck) do not run for PRs touching only
  `METHODOLOGY.md` / `PROMPT-LOOP*.md` / `skills/`, although the doc-consistency suites guard those
  files. #1428 was merged on local evidence (writer run-all 139/139; reviewer ran the 5 doc suites).

## Flaky under load (#1349 evidence; all passed standalone, concurrent writers active)
focus-partition-audit, lint-block, retro-gate (EN3-e, #1311 S9, T-SEEDABLE-PFX), research-sdd-install
("dry-run did not plan the config.toml write"), sweep-tools-hook case 10, scan-secrets test 60,
stage-retro-issues (one unexplained 209/1).

## Needs the user
- **#1328:** approve hilton-bms → Spanish as a language override, or retire the rule.
- **#1295 / TARGETS.md:** an "artifact roots" field in the TARGETS.md schema (kit sessions never edit
  TARGETS.md).

## Next session — agenda (in order)
0. Cleanup carry-over: remove the 8 harness worktrees under `.claude/worktrees/agent-*` (all clean,
   heads equal to merged PRs #1402-#1428 set) plus their local branches and the 18 local
   `worktree-agent-*` branches; prune old remote branches from earlier sessions after verifying each
   against a merged PR head (`gh pr list --state merged --head <b>`).
1. #1426 merge-gate CI gate (refuse on pending/failed/unreadable checks) — do it first; it protects
   every later merge.
2. #1299 remaining: switch the ~12 suites carrying local `TODO(#1299)` helper copies to the shared
   `mutant_tooth`/`mutant_chain`; harden `mutant_tooth` (refuse GOOD_RC == BAD_RC with no pattern);
   remaining families (corroborate/decompile, hooks/gate/state, residue, sweep-breakthroughs,
   sweep-audits, sweep-all, harness-sweep-parity, hotcore-budget, skill-invariants); items 2–4, 7.
3. Follow-ups: #1401, #1421, #1429, #1349 (flaky list above), #1361 item 1, #1369 rest, #1352 items
   5–6, #1358 items 3/5/6, #1325 rest (§11 wording, artifact cites, P6 WARN policy).
4. CI path filter: run the doc-consistency suites on PRs that touch METHODOLOGY/PROMPT-LOOP/skills
   (and extend ci-path-filter-coverage to assert it).
5. #1365 lint-block slice 2+.
6. Backlog waves M2–M5.

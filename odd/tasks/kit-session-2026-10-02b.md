# Kit session 2026-10-02b (closed 2026-10-03)

## Objective
Work the agenda from `kit-session-2026-10-02.md` in order, chained and automatic, plus the
requests that arrived during the session (GNU parallel, Pi/gentle-shell, dropping harnesses).

## Authorization
User: ODD + RDD (consent granted for every candidate), commit, push, PR, issues, merge — chained and
automatic. Delivery per PR: harness-worktree writer (sonnet, `sdd-apply` agent type, ODD prompt,
TDD with executed RED, lib/mutant.sh mutants) → parent spot check → full-range RDD (merge-base..head)
→ fix-first on real WARNs → PR with `type:*` + `Closes #N` → CI polled to pass → `merge-gate.sh --merge`.

## Outcome — 20 PRs merged, 0 open
| PR | Issue | What |
|---|---|---|
| #1432 | #1426 | merge-gate refuses pending/failed/missing CI on the exact head; latest run per (name, app) by highest id |
| #1438 | #1437 | toolbelt-tests job timeout 20 → 35 min (5/13 runs were cancelled at the cap) |
| #1435 | #1434 (#1299 A) | `mutant_tooth` refuses non-discriminating teeth; 7 suites on the shared helper |
| #1436 | #1433 | merge-gate surfaces gh stderr on unreadable check runs |
| #1440 | #1439 (#1299 B) | last 6 suites migrated; no `TODO(#1299)` left |
| #1441 | #1401 | `--no-renames` defence in archive and sweep-audits |
| #1443 | #1421 | retro-gate tags killed hooks; S16 kill tests poll instead of sleeping; python3 probe |
| #1445 | #1349 | flake root causes PROVEN: pipefail + `printf \| grep -q` SIGPIPE race; installer physical vs logical kit path |
| #1447 / #1451 / #1453 / #1458 | #1444 A/C/B/D1 | SIGPIPE idiom removed from every test suite |
| #1467 | #1444 D2 | same race removed from production scripts (deterministic RED: >1 MiB inputs, 20/20) |
| #1473 | #1444 (closed) D3 | ONE shared lint `pipefail-sigpipe-lint.test.sh`; explicit `# sigpipe-lint: allow` exemptions only |
| #1449 | #1448 (#1365 slice 2) | lint-block R3 flags inline `[CERT-hw]` evidence citing only ephemeral paths (14 true fleet findings) |
| #1456 | #1454 | CI runs the full suite on doctrine-only changes; coverage test derives the doc inputs |
| #1465 | #1464 | GNU parallel catalogued; §11b R7 bats -j silent zero; DYNAMIC-SETUP §8 hard caps (niagara retro applied, kit e1b108f) |
| #1470 | #1468 | `/research-sdd` for Pi and gentle-shell (pi + gentle-shell harnesses, prompt template); installed into the real homes |
| #1474 | #1471 | Reasonix and Codex harnesses dropped (supported: claude, pi, gentle-shell); TOML MCP machinery removed |

## Lessons
- RDD advisory WARNs can be real defects: a [started_at, id] ordering was a false ALLOW (a queued rerun
  has null started_at). Read every WARN; fix-first the real ones; file follow-ups for the rest.
- merge-gate reviews the WHOLE PR range: after fix-first commits run one more RDD on merge-base..head.
- A flaky failure whose printed output already contains the expected text is the SIGPIPE race
  signature. A test-only sweep was not enough: production scripts had the same race.
- Writers must keep scratch files outside the worktree: untracked files make `review assess` unassessable.
- PR branches carry their own workflow file: after a workflow fix, merge main into open PR branches.
- After 3 RDD rounds on a regex scanner, stop and file a follow-up (CLAUDE.md §6) — #1455.
- Parent spot checks run with GNU parallel under the operator's hard caps (`-j` ≤ 6, refuse when
  load > 6, `--keep-order --halt now,fail=1`, result count == input count).

## Needs the user
- Decisions: #1442 (retro-gate total Part C budget), #1325 (artifact-cite target-root fallback, P6 WARN
  policy), #1369 (e) `\uXXXX` + #949 item 5, #1358 items 3/5/6 (close as documented limitations?),
  #1361 item 1 (re-read), #1328 (hilton Spanish override), #1295 (TARGETS.md artifact roots).
- Unit A docs (#1429 items 1–2, #1325 §11 wording): commit 8e9118c on branch
  `docs/1429-1325-template-skill-methodology` — the push was denied by the auto-mode classifier for the
  subagent; the user pushes it or authorizes the push. Its worktree is kept.
- Cleanup of locked harness worktrees (force remove was denied by the classifier): a verified script
  was handed to the user at close.

## Next session — agenda (in order)
0. Confirm the cleanup ran (worktrees/branches of merged PRs gone; unit A worktree kept).
1. Push + PR unit A docs (8e9118c) once the push is allowed.
2. #1463 opt-in `run-all.sh -j N` — measure first; redesign the per-suite kit-tree hermeticity snapshot.
3. #1299 remaining items 2–7 (VBDBG opt-in note included).
4. Follow-ups: #1455 (ci-path-filter scanner), #1469 (template-deploy cleanup test pin),
   #1472 (`_normkit_for` comment edge), #1442 once decided.
5. Backlog waves M2–M5.

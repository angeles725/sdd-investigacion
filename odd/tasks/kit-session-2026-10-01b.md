# Kit session 2026-10-01b

## Objective
Work the next-session agenda from `kit-session-2026-10-01.md` in order, chained and automatic.

## Authorization
User granted: ODD + RDD (consent granted for every candidate), commit, push, PR create/view, issues,
merge; chain automatically; answer own questions; accept Gentle AI prompts.

## TDD
Strict TDD: enabled (global CLAUDE.md). Runner: `bash research-sdd/toolbelt/tests/run-all.sh`
(+ `--prove-teeth`), shellcheck gate per kit CLAUDE.md §5.

## Outcome
- **PRs merged (15):** #1323 (TARGETS Cancun paths, closes #1324), #1351 (#1319 sync-state
  malformed rows + escaped pipes), #1353 (#1311 retro-gate directory symlinks via git), #1355 (#1313
  fetch-doc cancellation / `--replace` versioning), #1357 (#1332 label probe + `### D<N> —` entry form),
  #1359 (#1320 decompile-java coverage sweep), #1360 (#1258 retro-gate Stop log), #1362 (docs batch 1:
  #1309, #1354 item 3, #1166 items 1–2), #1364 (#1272 `merge-gate.sh`), #1366 (#1206 `lint-block.sh`
  slice 1), #1368 (docs batch 2: merge-gate HARD RULE, Stop log, lint-block wiring), #1370 (#1304 CRLF
  fence + status test), #1372 (#1371 CI timeout + merge-gate summary), #1374 (#1043 #1031 #1034: atomic init settings write, truthful stage-retro advice, verify-state physical roots), #1376 (#1375: #1299 teeth slice 1).
- **New instruments:** `merge-gate.sh` (pre-merge check bound to the PR; merged its own PR and every
  later one), `lint-block.sh` (generic R3/R6 block linter, fleet FP 0 on real blocks).
- **Issues:** closed as already applied after verification: #1166, #1182, #1237. Created: Hilton
  deltas #1325–#1331 (TARGETS path fix unblocked staging), defects #1332 #1349 #1371, follow-ups #1350
  #1352 #1354 #1356 #1358 #1361 #1363 #1365 #1367 #1369 #1373, slice #1375. Open at close: 150.
- Every PR: writer in a harness worktree (strict TDD, executed RED, mutants via `tests/lib/mutant.sh`)
  → RDD (per commit and whole branch / merge-base range) → adversarial review (Opus; Sonnet after the
  Opus weekly limit) → FIX-FIRST rounds → CI → merge via `merge-gate.sh --merge`.

## Lessons
- **Triage before writers:** #1166 (items 3–6) and #1304 (items 1–4, 6) were already on main; a
  1-minute grep of origin/main for the issue's sentinels/test ids saves a writer run.
- **The Stop hook evaluates the whole branch**, not each commit; for multi-commit branches also review
  the cumulative range. After `update-branch` (merge of main), review the **merge-base range** —
  that is what `merge-gate.sh` assesses.
- **Stubs must reject unknown fields:** the gh stub invented `baseRefOid`, hiding that gh 2.45 has
  no such field (real `--merge` would always degrade).
- **CI timeout is a silent gate killer:** `toolbelt-tests` (`run-all.sh --prove-teeth`) was cancelled at
  the 12-minute cap on every run, main included; cancelled ≠ passed. Raised to 20 (runs now ~14 min).
- Adversarial reviews caught real defects every round: evidence deletion and cross-row retarget
  (fetch-doc), 12–16 s Stop latency (retro-gate), gson false units (decompile-java), caller-steerable
  base (merge-gate), durable-evidence false negative (lint-block), a log that dirtied a tracked
  `.claude/` (retro-gate), a non-atomic settings.json write (init).
- Opus weekly limit reached mid-session (resets 2026-10-03 19:00 America/Mexico_City).

## Next session — agenda (in order)
1. #1299 remaining slices: migrate ~100 suites to `lib/mutant.sh` (item 1), #943 verdict checks
   (items 2–4), rest of item 7.
2. #1365 lint-block slice 2+ (packs, R2/R4, inline CERT evidence, verify-block wiring).
3. Follow-ups filed this session: #1350 #1352 #1354 #1356 #1358 #1361 #1363 #1367 #1369 #1373; #1349
   flaky suites; a runtime budget for the full gate (#1371 note).
4. Hilton deltas #1325–#1331 and niagara5 deltas #1288–#1297 (doctrine; METHODOLOGY hot core is at its
   920-line budget — any new hot-core line needs a trim).
5. Backlog waves M2–M5 (triage found ~25 doctrine deltas still genuinely open).

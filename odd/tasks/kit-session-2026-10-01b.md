# Kit session 2026-10-01b

## Objective
Work the next-session agenda from `kit-session-2026-10-01.md` in order, chained and automatic.

## Authorization
User granted: ODD + RDD (consent granted for every candidate), commit, push, PR create/view, issues,
merge; chain automatically; answer own questions; accept Gentle AI prompts.

## TDD
Strict TDD: enabled (global CLAUDE.md). Runner: `bash research-sdd/toolbelt/tests/run-all.sh`
(+ `--prove-teeth`), shellcheck gate per kit CLAUDE.md §5.

## Tasks
- [x] T1 — TARGETS.md: fix `tunnel/Cliente/Cancun` → `tunnel/clientes/cancun` for rows #17 and #27;
  refresh counts (Hilton 233 blocks / 11 retros; Palace 4 blocks). Route: inline (1 file, mechanical).
  Evidence: verify-registry now reconciles 20 targets (was 18); Hilton/Palace drift WARNs cleared.
  The 13 other absent rows have no corpus anywhere under `$HOME` (searched by name, depth 6) —
  not relocatable on this machine; left as-is.
- [ ] T2 — stage HotelHilton retros with `stage-retro-issues.sh` (2026-09-18; 2026-08-01 partial).
- [ ] T3 — #1320 decompile-java registry row + METHODOLOGY §6 wording, then code follow-ups.
- [ ] T4 — #1319 sync-state: malformed rows trigger the lower-bound keep.
- [ ] T5 — #1299 teeth rollout to `tests/lib/mutant.sh` (chained slices).
- [ ] T6 — #1304 / #1311 / #1313 / #1309 / #1166 items 1–2.
- [ ] T7 — backlog waves (M2–M5, #1206, #1228/#1242a, status.sh B, #1015/#1014, #973, #1288–#1297).

## Progress
- T1 delivered in the PR that introduced this document.

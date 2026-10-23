<!-- review-status: pending -->
<!-- Marker lifecycle: the maintainer flips 'pending' above to 'applied <date> · kit <sha>' once this retro's proposed deltas are reviewed and applied (or 'dismissed') in the kit; sweep-retros.sh reads this marker to report which retros are still open (METHODOLOGY §18). -->
# Retro — sdd-investigacion (the kit itself) · flock + GNU parallel lock leak, plain-mode-only test failures, lib-copy lists · 2026-10-22 · Research-SDD self-retrospective

> Run reviewed: quality round 8 kit items (issues #2305 #2306, PRs #2307 #2308, the c_escpipe_guard fix). Trigger: coordinator request.
> Method: inline (coordinator wrote it from the writers' reports; no separate fresh-context agent), so discount its self-review accordingly.

> **Provenance:** base `18b4b206` · head `18b4b206` (origin/main at writing) · gate-run `none for this retro; the cited runs are in the PR bodies` · reruns `none`

## Proposed kit deltas

| ID | Delta | Target | Evidence | Priority |
|---|---|---|---|---|
| D1 | **FLOCK FD INHERITED BY PARALLEL WORKERS.** `flock <lock> run-all.sh -j N` passes the lock fd to every GNU parallel worker; killing the flock wrapper (or run-all) leaves the workers alive and holding the lock, so every peer waiting on it blocks. Start shared-lock runs under `setsid` and stop them with `kill -- -<PGID>`; find a holder through `/proc/*/fd` (lsof-style), because `/proc/locks` may show no owner. | `PROMPT-LOOP-APPENDIX.md#hard-rules-loop-mechanics` (next to PKILL -F WRAPPER-SHELL MATCH) | 2026-10-22: a stopped `-j 4` run left a worker tree (stuck on `unzip -tqq cfr.jar` in detect-tools.test.sh) holding the shared lock about 1 h; released only by killing its exact PIDs | MED |
| D2 | **A suite must pass in plain mode, not only under `--prove-teeth`.** CI always runs `run-all.sh --prove-teeth`, so a check that only works when the teeth helpers are loaded stays green in CI and red locally. Source helper libraries (they only define functions) in every mode, and make a mutant-build failure print its log instead of an empty reason. A cheap guard: run each changed suite once without `--prove-teeth` in the writer's verification. | `CLAUDE.md` §5 (gate table) + writer brief | `stage-retro-issues-delta-forms.test.sh` c_escpipe_guard: 18 passed · 1 failed plain on 18b4b206 vs 48/0 with `--prove-teeth` since b9d15ca1 (#2135/#2147); `toolbelt-tests.yml:129,231` | MED |
| D3 | **Hand-maintained lib-copy lists make lib extractions uneconomic; stage libs through one helper.** Deduplicating the backlog_rows / DEF-AWK parsers was declined because about 70 lib-copy sites and in-tool mutation cuts across 8 suites would need edits for about 75 production lines saved. | `research-sdd/toolbelt/tests/` (issue #2306, slices S2–S7) | #2306; PR #2308 ratchet of 43 suites | MED |

## Already covered
- PKILL -F WRAPPER-SHELL MATCH (`PROMPT-LOOP-APPENDIX.md`) covers the sibling hazard of matching one's own wrapper when killing by pattern.
- Mirror/cmp tests (T-BACKLOG-ROWS-MIRROR, the DEF-AWK cmp guard) already keep the duplicated parsers in sync until #2306 lands.

## Lessons
- A shared lock is only as safe as the process tree that inherits it; stop the group, not the wrapper.
- A test mode that CI never runs is a blind spot: the default local invocation must be as healthy as the CI one.

Port toolbelt/retro-gate.sh (918 lines) + templates/hook-stop-retro-gate.sh to Go as `rsdd gate retro` (kit issues #2367 U2.10a, #2368 U2.10b; perf #2168).
Branch: feat/2367-retro-gate-go (harness worktree). Delivery: chained slices ≤ ~1.5k lines, RDD per commit, strict watcher. Runner: go test / make teeth; toolbelt suites via run-all.sh.

## Specs
- S1 (#2367 verbatim): "Port to rsdd (Go): retro-gate.sh (front half), templates/hook-stop-retro-gate.sh ... Keep the old entry point as a shim (toolbelt/lib/rsdd-exec.sh); callers (.claude/settings.json, install/pi/research-sdd-hooks.ts, templates) must keep working unchanged. Suites that must stay green with --prove-teeth: retro-gate, hook-sessionstart."
- S2 (#2368 verbatim): "Port to rsdd (Go): retro-gate.sh (back half) ... Suites that must stay green with --prove-teeth: retro-gate, enforcement-e2e."
- S3 (session-1 relay): "Keep the hook output byte-identical. Measure the characters of the decoded output against the 8,000-character SessionStart budget. Measure wall time before and after on Pancaddia and in a fleet sweep, and put both numbers in the PR. Acceptance is a fleet sweep diffed against main (CLAUDE.md §7), not just the fixtures."
- S4 (#2168): the untracked-retro scan must not fork one process per path (was >300 s on niagara-research). Behaviour (which paths count) unchanged.
- S5 campaign pre-push rules: CI-like teeth 0 LIVED, goldens for oracle-only logic, staticcheck, gofmt, cross builds, planted-lib entry, removed-case map, RDD per commit, strict watcher.

## Tasks
- T1 S1,S2,S4: Go package + shim + tests + suite reduction — delegated writer (reason: context backstop, parallel with sweep-retros unit) — pending
- T2 S3,S5: fleet sweep on COPIES of targets with gh stubbed, timings, teeth, RDD, PR — parent — pending

## Log
- L1 (2026-11-02, session 1): "Your queue: 1. retro-gate.sh, issues #2367/#2368 (U2.10a/b). Take both. ..."
- L2: baseline: retro-gate.sh on Pancaddia 44.6 s (main 8ab62326). Note: the timing run executed the real gate once on Pancaddia (stop-log line, seeding skipped-duplicate=1, created=0); acceptance runs use copies.
- L3: writer T1 done; parent rebuilt 8 compiling commits on feat/2367-rg-v2 (worktree rg-review); fleet 21 targets byte-identical (niagara5 1312.5 s -> 7.5 s); teeth gate 1143/0; RDD per commit done. T2 PENDING: merge main, rerun impacted gate (pi-hooks rc=1 uninvestigated), push, PR (body sri-data/pr-rg.md).

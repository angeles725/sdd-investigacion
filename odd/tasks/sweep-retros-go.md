Port toolbelt/sweep-retros.sh (604 lines) + sweep-retros-hook.sh (79 lines) to Go as `rsdd sweep retros` (kit issues #2358 U2.4a, #2359 U2.4b; flake #2525).
Branch: feat/2358-sweep-retros-go (harness worktree). Delivery: chained slices ≤ ~1.5k lines, RDD per commit, strict watcher.

## Specs
- S1 (#2358 verbatim): "Port to rsdd (Go): sweep-retros.sh (scan) ... Keep the old entry point as a shim (toolbelt/lib/rsdd-exec.sh); callers (.claude/settings.json, install/pi/research-sdd-hooks.ts, templates) must keep working unchanged. Suites that must stay green with --prove-teeth: sweep-retros, discriminator-parity, harness-sweep-parity."
- S2 (#2359 verbatim): "Port to rsdd (Go): sweep-retros.sh (output), sweep-retros-hook.sh ... Suites that must stay green with --prove-teeth: sweep-retros-hook, harness-sweep-parity."
- S3 (session-1 relay): same hook rules as retro-gate: byte-identical hook output, decoded-character budget 8,000, wall time before/after on Pancaddia and fleet, acceptance = fleet sweep diffed against main.
- S4 (#2525): sweep-retros.test.sh fails under CPU load (case 33); the port must not keep that load sensitivity.
- S5 campaign pre-push rules (as retro-gate).

## Tasks
- T1 S1,S2,S4: Go package + shim + tests + suite reduction — delegated writer (parallel with retro-gate unit) — pending
- T2 S3,S5: fleet sweep diff vs main, timings, teeth, RDD, PR — parent — pending

## Log
- L1 (2026-11-02, session 1): "2. sweep-retros.sh, #2358/#2359, which includes flake #2525."
- L2: baseline: sweep-retros.sh fleet sweep 54.6 s (main 8ab62326).
- L3: writer T1 done (fc442758/a6b6d8fa); parent re-sliced to 9 commits, fixed a non-compiling differential (unused import), fleet sweep byte-identical (52-57 s -> 19-24 s), teeth 202/0, RDD per commit; FLIP-SW skip added; PR #2558 MERGED (77c28eaa). T1, T2 done.

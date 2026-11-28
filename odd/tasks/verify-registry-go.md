# verify-registry-go — finish `rsdd verify registry` and shim verify-registry.sh + verify-registry-hook.sh (issues #2362, #2363, #2364)
Objective: plug the real hook-wiring and session-budget checks into the existing Go port, make both scripts rsdd-exec shims, byte-identical output.
Branch: feat/2364-verify-registry-shim on origin/main. Delivery: ask-on-risk. Runner: go test + bash suites.

## Specs
- S1 (#2362/#2363/#2364, verbatim): "Keep the old entry point as a shim (toolbelt/lib/rsdd-exec.sh); callers (.claude/settings.json, install/pi/research-sdd-hooks.ts, templates) must keep working unchanged."
- S2: replace unportedHooks (internal/verify/registryhooks.go) with the real implementation: internal/core/hookwiring for the stop-hook states and wired-exec report, and the Go verify-session-budget for SessionBudget; the "degraded: N hook-wiring/session-budget check(s) skipped" line disappears from a normal run.
- S3: byte-identical stdout/stderr/rc against the frozen legacy scripts (differential, oracle under module testdata — #2592 "avoid adding new out-of-module reads in tests"), plus a fleet run against the real TARGETS.md (CLAUDE.md §7 acceptance).
- S4 (campaign, verbatim excerpt): "necesitamos que el codgio de progrmaacion sea modular, paraq ue en caso de tengamos que modificar algo, anadir algo sepamos en donde tener que hacer eso."

## Tasks
- T1 · S1-S4 · delegated writer (sonnet, worktree) — Writer trigger (b) context backstop · done 4f5ba315 71106b7f f84776a0 36dfc547 63c5ec5f
- T2 · S3 · parent: real-registry diff done (0 diffs); merge main 029bfb4d; RDD slices, gate, PR pending; merge after #2597

## Log
- L1 (s1 assignment, verbatim): "then the verify family: verify-block (#2456) first, then verify-registry(+hook), verify-corrections, verify-sources, verify-cd-physical, verify-doc-consistency, verify-parity, verify-tool-catalog(+hook), lib/block-files.sh"
- L2: Go registry exists on main with a hooks seam (unportedHooks); lib/hook-wiring.sh is ported to internal/core/hookwiring (#2356/#2357 closed).
- L3 (2026-11-03): writer done. reason-codes.test.sh 92/1 because go_view only keeps call lines and registryjson.go assigns states. s2 folds the Go assign form into #2597 (agreed), and this PR merges after #2597. Latency with RSDD_BIN: shim 29 ms vs legacy 104 ms.
- L4 (2026-11-03): real fleet (frozen copies in s3-data/vr-sweep, real TARGETS.md, 37 targets): text, --json, stderr and hook are byte-identical between legacy and shim. hook-emit conflict with #2596 resolved by keeping both shims (19/0).
- L5 (2026-11-03): PR #2602 opened. All RDD slices are approved; 63c5ec5f was re-sliced into three, tree-equal. The s1 L7 verifier found 1 BLOCKER: two session-budget rules unpinned after the bash cases were deleted. Fixed in 81c0bc87 with RED executed against both mutants. s1 recheck: PASS. Advisories filed as #2610. Merge order per s1: #2606 → #2604 → #2602, and rebase on #2603 if it lands first.

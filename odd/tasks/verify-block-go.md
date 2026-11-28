# verify-block-go — port verify-block.sh to `rsdd verify block` (issue #2456)
Objective: Go port with the bash script kept as an rsdd-exec shim, byte-identical output. Branch: feat/2456-verify-block-go, based on #2477's head
(feat/2457-verify-state-v2) until #2477 merges, then rebased onto origin/main. Delivery: ask-on-risk → chained PRs if over budget. Runner: go test + bash suites.

## Specs
- S1 (issue #2456, verbatim): "Port toolbelt/verify-block.sh (1,484 lines) to internal/verify, keep verify-block.sh as an rsdd-exec shim, byte-identical output proven by a differential test against the frozen legacy script and by a fleet sweep over the real corpora (CLAUDE.md §7: acceptance is a fleet sweep, not fixtures)."
- S2 (campaign, verbatim excerpt): "necesitamos que el codgio de progrmaacion sea modular, paraq ue en caso de tengamos que modificar algo, anadir algo sepamos en donde tener que hacer eso."
- S3 (s1 rule #2592, verbatim): "avoid adding new out-of-module reads in tests." — the frozen oracle lives under the module's testdata, not ../../../toolbelt.
- S4 (s2, verbatim): "If verify-block's Go emits a code only through a shared core package, add a GO_SHARED entry rather than listing a script that no longer emits it." — reason-codes.test.sh gets the right list entry for verify-block.sh.
- S5: the slow bash suites (verify-block*.test.sh, ~202 s in CI) are replaced by Go tests where they only re-test the port; any case kept in bash runs against the shim.

## Tasks
- T1 · S1-S5 · delegated writer (sonnet, worktree) — Writer trigger (b) context backstop · done · 3d8f90b9..e08941dd (re-sliced by the parent for RDD), parent fixes 3891b346
- T2 · S1 · parent: fleet sweep diff legacy vs Go over $RESEARCH_HOME corpora, RDD (slices), heavy-run gate, PR, watcher · pending

## Log
- L1 (2026-11-02, s1 assignment, verbatim): "then the verify family: verify-block (#2456) first, then verify-registry(+hook), verify-corrections, verify-sources, verify-cd-physical, verify-doc-consistency, verify-parity, verify-tool-catalog(+hook), lib/block-files.sh"
- L2: CLAIM broadcast to s1, s2, s4 (file set in T1 brief). s2 ack: no overlap.
- L3: writer done; parent re-sliced the port into compiling commits for RDD. Approved+acknowledged: modules (3), Go tests, shim, suite-thin (backpointer/possibility), fixes. Not reviewable (budget): oracle copy (verified byte-equal to main's verify-block.sh) and verify-block.test.sh thinning (deletions; cases moved to the Go differential).
- L4: RDD advisories fixed in 3891b346: filtered golden re-record refused; missing tool fails (not skips); BP-4 compares against default; PF-3 corpus checksum; teeth require usage rc 2. Suites with --prove-teeth (heavy-run): 6/0, 5/0, 17/0.
- L5: fleet sweep LC_ALL=C: 8,936 runs, 166 diffs, all back-pointer section (byte vs character counting), no exit-code change; the 166 match under C.UTF-8 (host locale). Full C.UTF-8 sweep running. Intended differences documented in tool-registry.d/verify-block.md.

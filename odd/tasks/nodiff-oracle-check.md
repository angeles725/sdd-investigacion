# nodiff oracle check (PR B, issue #2480)
Objective: no oracle test file runs inside `make teeth` (TEETHTAGS=nodiff); a static check enforces it.
Branch: test/nodiff-static-check-2480 (base origin/main 31bb4be5). Delivery: chained slices, ask-on-risk. Runner: go test + gremlins (make teeth via heavy-run, CI-like PATH).

## Specs
- S1 (session-4 queue item 1, verbatim): "a static Go test that fails when a `_test.go` file execs an oracle (exec.Command plus "python3"/.py/testdata/legacy) without the `nodiff` build tag. Its allowlist starts with the packages not yet fixed and shrinks as each is fixed."
- S2: "Fix the packages as chained slices, each with a tool-free teeth run (Lived 0): core/fsx parity_linux_test.go, core/proc parity_linux_test.go, formats LAST, based on main after s1's #2551".
- S3: "core/adapter (4 files) and core/adapter/helpers stay allowlisted for s1 T2."
- S4 (session 1, 2026-11-02): "Old PRs #2481 and #2502 (nodiff kit/proc/fsx, fsx/kit unit teeth) overlap PR B: fold them in or close them as superseded with evidence."

## Tasks
- T1 S2,S4: fold #2502 (fsx + kit unit kills, equivalent-mutant simplifications, `!nodiff` tags) — inline — cherry-picked 353b670e, 9b9d868c, 65b39eaa; Makefile comment conflict resolved to main's text.
- T2 S2,S4: core/proc parity `!nodiff` (#2481's proc line) + kills for any mutant only parity killed — inline — teeth run pending.
- T3 S1,S3: archtest.CheckOracleTags + allowlist (14 entries) — inline — RED: proc untagged -> TestOracleTagsRealTree FAIL; hand mutants killed.
- T4 S2: formats slice (squashfs, zipcmd, zipparity) — next PR in the chain.
- T5 S4: close #2481 and #2502 as superseded, link PR B.

## Log
- L1 (2026-11-02, session 1 to s4): "Deliver your queue: PR B (static nodiff check + fsx/proc/formats slices), then #2549 (`rsdd status show`)." ... "Old PRs #2481 and #2502 ... overlap PR B: fold them in or close them as superseded with evidence."
- L2: detection is per file (an exec in a helper file and the oracle path in another is not seen; budget, verify are such cases) and only string literals count, not comments. Known limit, stated in the doc comment scope.
- L3: equivalent mutants removed by simplification: `on(false) &&` (only the nodiff linux build matters), the post-package `break` (gofmt hoists every //go:build line).

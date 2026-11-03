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
- T2 S2,S4: core/proc parity `!nodiff` (#2481 proc line) + unit kills for the 4 mutants only parity killed (run.go grace/reached, run_unix.go kill/final reason) — inline — c9e786fa + 37803a1a.
- T3 S1,S3: archtest.CheckOracleTags + allowlist (14 entries) — inline — RED: proc untagged -> TestOracleTagsRealTree FAIL; hand mutants killed.
- T4 S2: formats slice (squashfs, zipcmd, zipparity) — inline (delegated writer) — commits: see L6.
- T5 S4: close #2481 and #2502 as superseded, link PR B.

## Log
- L1 (2026-11-02, session 1 to s4): "Deliver your queue: PR B (static nodiff check + fsx/proc/formats slices), then #2549 (`rsdd status show`)." ... "Old PRs #2481 and #2502 ... overlap PR B: fold them in or close them as superseded with evidence."
- L2: detection is per file (an exec in a helper file and the oracle path in another is not seen; budget, verify are such cases) and only string literals count, not comments. Known limit, stated in the doc comment scope.
- L3: equivalent mutants removed by simplification: `on(false) &&` (only the nodiff linux build matters), the post-package `break` (gofmt hoists every //go:build line).
- L4: teeth CI-like (python3+jq on PATH, no bwrap): fsx 75 killed/0 lived, kit 310/0, proc 38/4 before the kills. One unexplained FAIL of `go test -tags nodiff ./internal/core/proc/` right after adding spec_unit_test.go; 13 reruns green, not reproduced, test name not captured.
- L5: RDD: 0194abfc approved (high) with advisories exec-alias blindspot, GOOS file-name suffix, misplaced //go:build; slices 1-4 (escalated item 3) and 37803a1a (escalated item 4) approved with advisories (fsx publish clamp, kit rest guard, unconditional leader Kill, the unreproduced flake) judged acceptable: findState paths always start with dir; the clamp change is declared in #2502; Kill on a finished process sends no signal. Advisories fixed in the next commit: os/exec's local import name and build.Context.MatchFile (GOOS/GOARCH suffix + //go:build, as the go command).
- L6 (T4, formats slice): squashfs_test.go no longer execs Python (its `verifyManifest` moved into the `!nodiff` squashfs_parity_test.go; the nodiff tests verify the manifest with the in-process `verifyInProcess`). zipcmd_linux_test.go and zipparity_linux_test.go are `linux && !nodiff`; their non-oracle helpers moved to zipcmd_helpers_linux_test.go. Oracle outputs are frozen as 8 goldens under testdata/zip/golden (the `!nodiff` parity tests assert golden == oracle, `RSDD_UPDATE_GOLDEN=1` regenerates; zipgolden_linux_test.go replays them through the Go code under nodiff). Two cases (nested.zip --max-depth 4/3) added to pin the inclusive depth cap, a mutant that survived the old parity corpus. Hand mutants killed under -tags nodiff: zipstored.go `> lim.maxDepth` -> `>=` (TestZipStoredCommandGolden, TestZipStoredInspectGolden), zipout.go pyName `return ""` -> `"x"` (TestPyPathGolden), zipname.go hangul `(s%hangulNCount)` -> `(s%hangulNCount+1)` (TestZipNFCGolden). oracleAllow lost its 3 formats entries.

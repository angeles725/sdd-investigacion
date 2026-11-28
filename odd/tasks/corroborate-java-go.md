Port toolbelt/corroborate_java.py to Go as `rsdd corroborate java` (kit issue #2534).
Branch: feat/2534-corroborate-java-go (harness worktree). Delivery: ask-on-risk → chained slices of ~400 lines, merged via strict watcher.
Test runner: `go test` (make test / make teeth), toolbelt suites via run-all.sh.

## Specs
- S1 (session-1 relay, verbatim): "port `toolbelt/corroborate_java.py` (849 lines) to Go. main still runs it: corroborate-java.sh does `exec python3 corroborate_java.py ... --manifest-module analysis_manifest.py`."
- S2: "Check s3's existing `internal/corroborate/classfile` (#2442) and `fidelity`, and reuse their class-file reader instead of writing a second one."
- S3: "the port must also drop the classfile-facts fallback note and the parity-oracle dependency on corroborate_java.py in the same change."
- S4: "Keep the manifest call to analysis_manifest.py as is; I'm consolidating that in core at the end."
- S5 pre-push rules: "CI-like teeth at 0 LIVED, goldens for oracle-only logic, staticcheck, gofmt, cross builds, planted-lib entry for the shim, a map from each removed bash case to its Go test, RDD per commit, and a strict watcher."

## Tasks
- T1 S1,S2,S4: Go package internal/corroborate/java + golden/differential tests against the frozen oracle — delegated (writer reason: context backstop; parent context is long) — done (commits 3ada781b b012c576 c199e036 ad2d9ee8, worktree branch feat/2534-corroborate-java-go) [x]
- T2 S1,S5: shim corroborate-java.sh via rsdd_exec + planted-lib entry + bash suite reduced — same writer (one behaviour) — done (commits 3ada781b b012c576 c199e036 ad2d9ee8, worktree branch feat/2534-corroborate-java-go) [x]
- T3 S3: drop decompile-java.sh classfile-facts Python fallback, move classfile parity_test and cf-* parity specs to frozen goldens, delete corroborate_java.py, update docs — same writer — done (commits 3ada781b b012c576 c199e036 ad2d9ee8, worktree branch feat/2534-corroborate-java-go) [x]
- T4 S5: teeth CI-like, cross builds, staticcheck, RDD per commit, PR with removed-case map, strict watcher — parent — done (PR #2542; teeth java 420/0, classfile 204/0; RDD per commit acked; strict watcher on)

## Log
- L1 (2026-11-02, session 1 relay of the user's campaign request): "take this unit: port `toolbelt/corroborate_java.py` (849 lines) to Go ... Open the issue first (status:approved, type:feature) ... Pre-push rules, all in the README ..."
- L2: issue #2534 opened.
- L3: session 1 accepted option (a) for S4 (in-process manifest) and asked for a never-loaded test; added.
- L4: rebuilt as 7 slices on main; first CI-like teeth 36+7 LIVED, killed by two parallel writers; second run 0 LIVED; PR #2542 opened.

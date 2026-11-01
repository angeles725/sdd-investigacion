# budget-verify-port: port verify-session-budget.sh to `rsdd budget verify` (kit issue #2446)
Branch: feat/rsdd-budget-verify-2446 · Delivery: single PR (orchestrator opens it) · Runner: go test (research-sdd/rsdd), bash lint suites

## Specs
- S1: `rsdd budget verify [--harness claude|pi|both] <target-dir>` replaces `research-sdd/toolbelt/verify-session-budget.sh` in Go: "byte-identical output and exit codes on every fixture".
- S2: "a parity test against a frozen copy of the shell script over the existing `tests/fixtures/verify-session-budget/` cases (including the 11 `_frozen` outputs)".
- S3: "`verify-session-budget.sh` becomes an rsdd_exec shim; its bash suite is replaced by Go tests in the same PR."
- S4: "`lib/session-budget-pi.mjs` stays in Node (pi measurer), called from Go the same way the script calls it today."
- S5: "teeth run with real gremlins (TEETH_TEST_CPU=0 until the Makefile fix lands), the suite's CI time removed." (The orchestrator schedules the heavy gremlins run; this unit proves teeth by hand with 3 mutants.)
- S6 (assumption from the task brief): typed states stay distinct (CLAUDE.md section 7): absent-input, empty-input, degraded, ok.

## Tasks
- [x] T1 (S2) freeze legacy script (sha-pinned) + goldens from fixtures - inline
- [x] T2 (S2) RED parity/differential test - inline
- [x] T3 (S1,S4,S6) implement `rsdd budget verify` in internal/budget (args, settings, sandbox, hookrun, measure, report, pi) - inline
- [x] T4 (S3) shim + delete bash suite after case->Go mapping - inline
- [x] T5 reference sweep, checks, hand mutations, push - inline

## Log
L1 (issue #2446 body, verbatim):
Python/shell port unit (go-port Phase 3, `budget verify`; epic #2270).

`research-sdd/toolbelt/verify-session-budget.sh` (321 lines) measures the SessionStart hook output budget (decoded characters, under 8,000 total). Its suite `verify-session-budget.test.sh` costs 404 s in CI (SLOW-SUITES.md, run 40666531812), the largest unowned slow suite outside Niagara.

Scope:
- `rsdd budget verify` in Go, with a parity test against a frozen copy of the shell script over the existing `tests/fixtures/verify-session-budget/` cases (including the 11 `_frozen` outputs).
- `verify-session-budget.sh` becomes an rsdd_exec shim; its bash suite is replaced by Go tests in the same PR.
- `lib/session-budget-pi.mjs` stays in Node (pi measurer), called from Go the same way the script calls it today.

Acceptance: byte-identical output and exit codes on every fixture, teeth run with real gremlins (TEETH_TEST_CPU=0 until the Makefile fix lands), the suite's CI time removed.

L2 (apply log): RED observed with the oracle, goldens and tests before any implementation (`rsdd: unknown command "budget"`), then GREEN. Parity is live (TestParity runs the sha-pinned frozen script and the Go command on the same fixture copy) plus recorded goldens (14 pi cases are diff-only: the kit extension's section length depends on the scratch path length, so only the live comparison applies). The old suite's cases map to Go tests listed at the head of behavior_test.go. Hand mutations that went red: wc -m to wc -c; capped command re-run; empty-input guard removed; fieldCap 10000 to 20000; --unshare-net dropped.
Out-of-surface follow-ups for the orchestrator: remove tests/impact-blindspot.txt line 96 (the suite is gone); drop verify-session-budget.sh from the absent-input and empty-input emitters of reason-codes.v1.md and regenerate internal/core/reasons/table_gen.go; refresh the tool-registry.md row (shim note); the CI workflow comments still name the deleted suite.

# verify-skill-drift port (kit issue #2365, unit U2.8)
Objective: port verify-skill-drift.sh and verify-skill-drift-hook.sh to `rsdd verify skill-drift` / `rsdd verify skill-drift-hook`.
Branch: feat/rsdd-verify-skill-drift-2365 (base origin/main 73c79729). Delivery: sliced commits, no PR. Runner: go test (focused packages only).

## Specs
- S1 "Port to rsdd (Go): verify-skill-drift.sh, verify-skill-drift-hook.sh … Keep the old entry point as a shim (toolbelt/lib/rsdd-exec.sh); callers (.claude/settings.json, install/pi/research-sdd-hooks.ts, templates) must keep working unchanged."
- S2 "Suites that must stay green with --prove-teeth: render-profile, research-sdd-init, harness-sweep-parity."
- S3 "Acceptance: parity against the bash output over the suite fixtures (testkit/parity), strict TDD with RED executed on the pre-change SUT, mutation teeth, Go build hygiene (GOTMPDIR per lane, no leftover binaries)."
- S4 All code lives in `research-sdd/rsdd/internal/verify/skilldrift/`; `internal/verify/commands.go` gets exactly one entry line and one import line.
- S5 Every legacy case of `tests/verify-skill-drift.test.sh` and `tests/verify-skill-drift-hook.test.sh` has a passing Go test before its bash suite is deleted (mapping recorded in the Log).
- S6 `adapters.sh` is not ported here: the bash functions it defines are reached through a narrow exec seam (`adapters.go`).

## Tasks
- T1 (S3) freeze both scripts sha-pinned in testdata/legacy; record goldens. inline.
- T2 (S3) RED parity test, executed against the missing command. inline.
- T3 (S1,S4,S6) implement `skilldrift` package, one concern per file. inline.
- T4 (S1,S5) behaviour tests mapped to every legacy case. inline.
- T5 (S1) switch both .sh to shims; delete both bash suites; fix every reference. inline.
- T6 (S2,S3) checks, hand mutants. inline.

## Log
L1 (issue #2365 body, as given by the lane brief): "Port to rsdd (Go): verify-skill-drift.sh, verify-skill-drift-hook.sh … Keep the old entry point as a shim (toolbelt/lib/rsdd-exec.sh); callers (.claude/settings.json, install/pi/research-sdd-hooks.ts, templates) must keep working unchanged. Suites that must stay green with --prove-teeth: render-profile, research-sdd-init, harness-sweep-parity. … Acceptance: parity against the bash output over the suite fixtures (testkit/parity), strict TDD with RED executed on the pre-change SUT, mutation teeth, Go build hygiene (GOTMPDIR per lane, no leftover binaries)."

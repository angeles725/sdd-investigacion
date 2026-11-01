# corpus-archive-port — port research-sdd-archive.sh to `rsdd corpus archive` (kit issue #2459)
Branch: feat/rsdd-corpus-archive-2459 (base origin/main) · Delivery: small Conventional Commits, no PR · Runner: `go test` from research-sdd/rsdd + bash lints

## Specs
- S1: "`rsdd corpus archive` in Go (`internal/corpus`), with a parity test against a frozen, sha-pinned copy of the script."
- S2: "This tool WRITES into a target (unlike the read-only verifiers). Every parity or fleet comparison runs the legacy script and the Go command on separate scratch COPIES of the same input (mktemp -d), never on a live corpus or on TARGETS.md (kit CLAUDE.md §8), and compares the resulting trees (paths, bytes, modes) as well as stdout, stderr and exit code."
- S3: "`research-sdd-archive.sh` becomes an rsdd_exec shim; its bash suite is replaced by Go tests in the same PR."
- S4: "Acceptance: byte-identical output and identical result trees on every fixture case; real gremlins teeth with a hand non-vacuity check; RDD per slice; CI green."
- S5 (task brief): every legacy case of `research-sdd-archive.test.sh` maps to a passing Go test; the bash suite is deleted only after that mapping; registry references (impact-blindspot.txt, reason-codes.v1.md + `go generate`, tool-registry.md) are fixed.
- S6 (task brief): at least 4 hand mutations (one per archive step, one typed state, one tree-writing step), each red then restored. No make teeth, gremlins, -race, whole-module tests or run-all.sh in this unit.

## Tasks
- T1 (S1,S2) odd doc, frozen sha-pinned oracle, goldens incl. result trees — inline — [x] done
- T2 (S1) RED parity test (command missing) — inline — [x] done
- T3 (S1) implement internal/corpus archive (args, discovery, gates, secrets, retro, consolidate, report) — inline — [x] done
- T4 (S3,S5) shim + case->test mapping + delete suite + registry fixes — inline — [x] done
- T5 (S4,S6) checks and hand mutations — inline — [x] done

## Log
- L1 (issue #2459 body, verbatim):
  "Phase 3 port unit (epic #2270, `corpus archive`).

  `research-sdd/toolbelt/research-sdd-archive.sh` (749 lines) archives a research corpus; its suite `research-sdd-archive.test.sh` (2,367 lines) costs 188 s in CI (SLOW-SUITES.md).

  Scope:
  - `rsdd corpus archive` in Go (`internal/corpus`), with a parity test against a frozen, sha-pinned copy of the script.
  - This tool WRITES into a target (unlike the read-only verifiers). Every parity or fleet comparison runs the legacy script and the Go command on separate scratch COPIES of the same input (mktemp -d), never on a live corpus or on TARGETS.md (kit CLAUDE.md §8), and compares the resulting trees (paths, bytes, modes) as well as stdout, stderr and exit code.
  - `research-sdd-archive.sh` becomes an rsdd_exec shim; its bash suite is replaced by Go tests in the same PR.

  Acceptance: byte-identical output and identical result trees on every fixture case; real gremlins teeth with a hand non-vacuity check; RDD per slice; CI green."
- L2 route: all tasks inline (single sequential unit; no parallel-writer reason). Risk: item 3 (replaces a script others call; the shim keeps argv, stdout, stderr, exit codes).

- L3 case->test mapping (old suite case -> `TestArchiveCases/<name>` in `archive_cases_test.go`, whose `legacy:` field names the old case number; every case runs the frozen script and the Go command on separate copies and compares stdout, stderr, exit code and the result tree, then compares Go to the goldens): 1-40b and the 17a-17x, 20a-25, 22a-22f, AR1/AR2, AR-VCORR (#1857, #1868) groups map one-to-one by that field. PATH-shim and stub-lib cases (15 touch stub, 17q/17u find stubs, 17x BASH_ENV cd override, 33/34 state-files stubs) run through the `archiveHooks` seams on the Go side and the real shim/stub on the legacy side. 17h (dubious ownership) is skipped where the host cannot create it. 17l was already removed. 36b (structural `--no-renames` guard) is `TestArchiveGitLogCallsPassNoRenames`. The old --prove-teeth mutant block is replaced by the hand mutations recorded in the apply report.
- L4 known divergence: `cli.Run` appends a generic `DEGRADED:` line to stderr of any command that ends on exit 3; for this tool 3 means REFUSED. The parity harness calls the command function directly; the shim test strips that one line and asserts it is the only difference. Needs a change in `internal/cli` (out of surface).

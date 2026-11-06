# go-impact (#2613): map Go-only changes to the suites that reach them
Objective: `suite-impact.sh` stops escalating every Go-only change to FULL; it maps an internal/<pkg> change to the toolbelt suites that reach the commands built from it. Branch: feat/go-impact-2613 (PR a), then chained PRs (b), (c). Delivery: chained PRs (ask-on-risk resolved: chain, stacked-to-main). Test runner: `go test` (focused), teeth via heavy-run; suite-impact.test.sh for (b).

## Specs
S1 (issue #2613, verbatim): "`suite-impact.sh` resolves an `internal/<pkg>` file to the rsdd commands registered from that package (`commands.go`), then to the toolbelt shims that `rsdd_exec` those commands, then to the suites that reach those shims; `_test.go`/`testdata` changes under the module select no toolbelt suite (they are covered by the Go bridge). Anything it cannot place still escalates (typed, as today)."
S2 (s1 ruling): "Go, new package internal/maint/goimpact + `rsdd maint go-impact`, go/parser only (no go list), computed from source (no generated manifest: nothing to drift), fail closed to FULL, three chained PRs."
S3 (C1, verbatim): "Prove the enumerator. A test must assert: {commands the parser recovers from cli.Command literals} == {commands of the assembled registry (internal/commands)}. A registration form the parser cannot see then fails a test instead of shrinking selections. Same for shims: every toolbelt script that execs rsdd must map to a recovered command, else that script is `unclassifiable` → FULL."
S4 (C2, verbatim): "Enumerate every form by which bash reaches a command, against the real tree, and declare recognised vs unclassified: `rsdd_exec <group> <name>`, `\"$RSDD_BIN\" <group> <name>`, a literal `rsdd <group> <name>`, templates/hook-*.sh, install/*.sh, suites that call the binary directly without a shim. A suite that calls the binary directly must be selected for that command exactly like a shim caller."
S5 (C3, verbatim): "Test-only edges: build the reverse import closure with test imports marked. `*_test.go`, testdata that no bash file names, and a package whose only importers are _test.go files (internal/testkit/*) are `go-test-only`: they add no toolbelt suite. testdata that a bash suite or script names goes through the existing word graph first. The aggregate must print the go-test-only file count on its own line, and the always-run set still runs, so the selection is never empty by this path."
S6 (C4, verbatim): "Binary and tree: go-impact parses the files under --repo (working tree), not what the binary was built from; suite-impact uses the run's RSDD_BIN; `rsdd: DEGRADED` or SKIPPED → FULL with that reason."
S7 (C5, verbatim): "Use a traced run instead: point RSDD_BIN at a thin wrapper that appends `<suite>\t<group> <name>` to a log outside the tree ... during ONE full `--tier all` gate run that some PR needs anyway. ... Commit it as a frozen fixture (dated, sha) and assert: for every suite, static reach ⊇ traced reach. Any traced edge the static map lacks is a defect to fix before wiring (b)."
S8 (C6): the 30-PR dry-run is a savings report only (suites selected vs FULL per PR), not acceptance.
S9 (C7, verbatim): "Core changes: closure wider than the threshold → FULL is accepted for the first version; print the closure size so we can see later whether core needs its own treatment."
S10 (fixed by s2 plan, approved): go.mod, go.sum, Makefile, cmd/**, internal/cli/**, internal/commands/** → FULL with a typed reason. Output lines are tab-separated and typed: `SHIM <file> <script>`, `NONE <file> go-test-only`, `FULL <file> <reason>`, plus the closure size per file.

## Tasks
- T1 (S2-S6, S9, S10) PR (a): internal/maint/goimpact package + `rsdd maint go-impact` + C1/C2 enumerator tests + tool-registry.d/go-impact.md. Route: delegated (kit CLAUDE.md §1: 2+ non-trivial files → one writer). Status: open.
- T2 (S7) traced-run wrapper + frozen fixture + static ⊇ traced test. Route: inline (parent), piggybacks one full --tier all gate. Status: open.
- T3 (S1, S5, S6) PR (b): suite-impact.sh wiring + suite-impact.test.sh cases + go-test-only aggregate line. Route: TBD. Independent verifier + s10 cross-read. Status: open.
- T4 (S8) PR (c): doc rows (CLAUDE.md §5 Impacted row, tool-registry) + 30-PR savings report. Status: open.

## Log
L1 (2026-11-06, s1 WAVE 2 item 2): "#2613: make suite-impact map a Go-only change to the suites that reach it, so a Go-only PR stops escalating to the FULL gate (about 1 h of heavy slot per PR, ~40 units left: this is blocker-class, it goes before flake-hunt)."
L2 (2026-11-06): s1 design ruling C1-C7 received; PR (a) authorized to start. Risk items 6 + 3: independent verifier after own checks, RDD escalated, s10 cross-reads (b).

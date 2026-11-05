# Port migrate-backlogs.sh to Go (`rsdd corpus migrate-backlogs`) — kit issue #2684
Objective: `research-sdd/toolbelt/migrate-backlogs.sh` becomes a `rsdd_exec` shim over `rsdd corpus migrate-backlogs` (package `internal/corpus/migratebacklogs`); legacy defects fixed on the Go side. Branch: worktree-agent-a9d24400fbc1ba134. Delivery: `ask-on-risk`, commits of ~400 lines, no push. Runner: `go test ./internal/corpus/... ./internal/testkit/archtest/` (both tag sets, `-tags nodiff`) and the bash suites under `toolbelt/tests`.
Mirror (Engram `odd/migrate-backlogs-go/tasks`): pending, the mirror is written by the orchestrator session.

## Specs
- S1 "Port `research-sdd/toolbelt/migrate-backlogs.sh` (312 lines) to rsdd as `rsdd corpus migrate-backlogs` in a new package `internal/corpus/migratebacklogs`, and keep the script as an `rsdd_exec` shim."
- S2 "The tool is a PROPOSE-ONLY §8b gap-backlog migration (kit #1543). It prints the mechanical heading, skeleton, priority, status and focuses transforms as a unified diff per file, and a typed MANUAL line for anything not mechanical. It never edits the target (CLAUDE.md §8)."
- S3 "The tool parses tables through core/gfm, using the Padded API: migrate-backlogs keeps cell padding and the `\|` escape (core/gfm/READERS.md)."
- S4 "a frozen sha-pinned oracle, a differential and golden replay;"
- S5 "RED executed;"
- S6 "legacy defects fixed, pinned by tests and documented in `tool-registry.d/migrate-backlogs.md`;"
- S7 "the target tree proven byte-identical after every run (read-only invariant);"
- S8 "a recorded subprocess list (L29);" — the Go command starts none (the unified diff is computed in process); the frozen script starts awk, diff, find, sort, mktemp, cut, wc, basename, dirname.
- S9 "no host-tool branching (L60);"
- S10 "hand mutants and package-scoped gremlins with 0 lived (L56, L72, L73);" (the orchestrator forbids gremlins in this unit: hand mutants only)
- S11 "latency measured."
- S12 Kept for callers: the unified-diff format (`PROPOSE <label> <file>` + `diff -u --label a/<rel> --label b/<rel>`), the `MANUAL <label> <reason> rows=<N> first-line=<L>` format, the typed `absent-input:` / `empty-input:` / `ok` / closing-summary lines, exit 0 inspected · 1 operational failure (typed `degraded:` on stderr) · 2 bad args or target not a directory.

## Tasks
- T1 (S4, S5) freeze the script + `lib/state-files.sh` sha-pinned, harness, cases, differential, golden, RED — route inline — commits: 603f86d8, 5b804637, 32b77244 (RED against the stub)
- T2 (S1, S2, S3, S6, S7, S8) the port: scan, lines, cells, backlog, priority, focuses, manual, unidiff, command, registered from `internal/corpus/commands.go` — inline — commits: 272fa091, 7a57d258
- T3 (S6, S7, S9) divergence and edge tests (go-only), read-only invariant — inline — commits: 85e72457, 9f12658e, 3d9bfe28
- T4 (S1, S6, S11) shim switch, shrunk bash suite, reason-codes, tool-registry, sibling suites repointed — inline — commit: dc89dd42
- T5 (S10) hand mutants under `-tags nodiff` in an out-of-repo copy — inline — commit: none

## Log
L1 (2026-11-03, verbatim, issue #2684 body):
Unit of epic #2270 (Go port), s2 lane.

Port `research-sdd/toolbelt/migrate-backlogs.sh` (312 lines) to rsdd as `rsdd corpus migrate-backlogs` in a new package `internal/corpus/migratebacklogs`, and keep the script as an `rsdd_exec` shim.

The tool is a PROPOSE-ONLY §8b gap-backlog migration (kit #1543). It prints the mechanical heading, skeleton, priority, status and focuses transforms as a unified diff per file, and a typed MANUAL line for anything not mechanical. It never edits the target (CLAUDE.md §8).

The tool parses tables through core/gfm, using the Padded API: migrate-backlogs keeps cell padding and the `\|` escape (core/gfm/READERS.md).

Acceptance:
- a frozen sha-pinned oracle, a differential and golden replay;
- RED executed;
- legacy defects fixed, pinned by tests and documented in `tool-registry.d/migrate-backlogs.md`;
- the target tree proven byte-identical after every run (read-only invariant);
- a recorded subprocess list (L29);
- no host-tool branching (L60);
- hand mutants and package-scoped gremlins with 0 lived (L56, L72, L73);
- latency measured.
L2 (2026-11-03, coordinator note from s3, PR #2681): `table-reader-parity.test.sh` still reads `lib/gap-rows.sh`, which s3 keeps; when editing it, touch ONLY the migrate-backlogs reader lines and never drop or alter the gap-rows reader.
L3 (2026-11-05, s2) merged origin/main 743af41e (clean). Package gremlins (L56) had left 7 LIVED: backlog.go:183 boundary, focuses.go:25 boundary, focuses.go:40/81 INVERT_NEGATIVES + ARITHMETIC_BASE, priority.go:79 boundary. Fixed in b474e58e: the `statusCol := -1` initial value is never read (the header row sets it first), so it is a zero-valued var (two equivalents gone); priority.go uses `i != -1` (a blank at index 0 cannot reach a ^-anchored status regex, so the boundary mutant was equivalent); new nodiff tests for registryHeader with Status in column 0, appendSkeleton on an empty file, and planStatus tokens. Behaviour proof: full package tests without -tags nodiff (oracle differentials) pass. Latency (S11), frozen script vs `rsdd corpus migrate-backlogs`, 3 runs each, outputs byte-identical: niagara-research 2245–2906 ms vs 187–226 ms; cloudflare 53–62 ms vs 10–12 ms; sullair 46–54 ms vs 10–16 ms. RDD: b474e58e medium, under budget.

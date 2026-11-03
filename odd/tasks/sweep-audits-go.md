# sweep-audits-go — port sweep-audits.sh and sweep-audits-hook.sh to `rsdd sweep audits` (kit issue #2577)
Branch: worktree-agent-a09b1cc233baa87aa (base origin/main 0c339974) · Delivery: Conventional Commits ending `(#2577)`, no push · Runner: `go test` from research-sdd/rsdd (`./internal/sweep/...`, `./internal/testkit/archtest/...`, with and without `-tags nodiff`) + bash lints

## Specs
- S1 (parity): "Byte parity. stdout, stderr and the exit code match the frozen script. The differential test runs the sha-pinned legacy oracle and is `!nodiff`; a nodiff-visible test replays the goldens."
- S2 (typed states, read-only): "Read-only corpora, WARN-only findings (CLAUDE.md §8). An operational failure still exits 1, and typed states stay distinct (§7)." absent-input / empty-input / no-match stay three different lines; the port writes nothing under a target.
- S3 (reuse): "Reuse. Target-path derivation comes from `internal/core/kit`, and the shared sweep helpers from `internal/sweep`." Marker reading is `core/retrogrammar.ReviewStatus`.
- S4 (shim): `sweep-audits.sh` and `sweep-audits-hook.sh` become `rsdd_exec` / `rsdd_exec_hook` shims (the sweep-retros idiom); their bash suites shrink to shim and wiring cases and every removed case maps to a Go test (table in the Log, L3).
- S5 (registry): `planted-lib-scripts.txt` keeps listing both shims; `tool-registry.md` rows and `reason-codes.v1.md` emitters are updated only when their text or emitters change.
- S6 (teeth): "Mutants. No lived mutant in the bridge job." Boundaries (range checks, regex alternatives, counters) are pinned by unit tests that go red under hand mutants.

## Tasks
- T1 (S1,S6) feature doc, frozen sha-pinned legacy oracle, pin test — inline — [x]
- T2 (S1) case table from sweep-audits*.test.sh, differential, RED against a stub — inline — [x]
- T3 (S1,S2,S3) implement `rsdd sweep audits` and `--hook` until 0 diffs — inline — [x]
- T4 (S1) goldens recorded from the frozen script + nodiff replay — inline — [x]
- T5 (S6) boundary unit tests + hand mutants — inline — [x]
- T6 (S4,S5) shims, reduced bash suites, case map, registry — inline — [x]

## Log
- L1 (issue #2577 body, verbatim):
  "Part of the Go port (go-port-lanes/PORT-QUEUE.md, s2 retro/sweep family).

  Port `research-sdd/toolbelt/sweep-audits.sh` (160 lines) and `sweep-audits-hook.sh` (64 lines) to Go in `internal/sweep`, next to the existing `sweep retros` port. Both scripts become `rsdd_exec` shims.

  Acceptance:
  - **Byte parity.** stdout, stderr and the exit code match the frozen script. The differential test runs the sha-pinned legacy oracle and is `!nodiff`; a nodiff-visible test replays the goldens.
  - **Read-only corpora, WARN-only findings** (CLAUDE.md §8). An operational failure still exits 1, and typed states stay distinct (§7).
  - **Reuse.** Target-path derivation comes from `internal/core/kit`, and the shared sweep helpers from `internal/sweep`.
  - **Mutants.** No lived mutant in the bridge job.
  - **Fleet sweep.** Across the real TARGETS.md fleet, the new output is byte-identical to main's."
- L2 route: all tasks inline (one sequential unit, no parallel-writer reason). Risk: item 3 (replaces two scripts others call, the SessionStart hook included; the shims keep argv, stdout, stderr and exit codes). Base: origin/main 0c339974.

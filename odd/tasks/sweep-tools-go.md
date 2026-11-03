# sweep-tools-go — port sweep-tools.sh and sweep-tools-hook.sh to `rsdd sweep tools` (kit issue #2361, sweep-tools half)
Branch: worktree-agent-ac1d82a4400f7769c · Delivery: Conventional Commits ending `(#2361)` with a `Refs #2361` line (the issue also covers verify-tool-catalog, so never `Closes`), no push · Runner: `go test` from research-sdd/rsdd (`./internal/sweep/`, `./internal/testkit/archtest/`, with and without `-tags nodiff`) + bash suites and lints

## Specs
- S1 (parity where a caller depends): "Port `research-sdd/toolbelt/sweep-tools.sh` and `sweep-tools-hook.sh` to Go as `rsdd sweep tools` in `research-sdd/rsdd/internal/sweep`. Keep the old entry point as a shim (toolbelt/lib/rsdd-exec.sh); callers (.claude/settings.json, install/pi/research-sdd-hooks.ts, templates) must keep working unchanged." The report lines and the hook text keep their bytes; only the divergences of L4 differ.
- S2 (typed states, read-only): absent-input, empty-input ("no tools/ directory", "exists but is empty") and no-match stay distinct (CLAUDE.md section 7); an operational failure still exits 1; the port writes nothing under a target.
- S3 (reuse): target-path derivation from `internal/core/kit`, the walk / find predicates / skipped-target naming / hook envelope from `internal/sweep`; no second copy.
- S4 (shim): both scripts become `rsdd_exec` / `rsdd_exec_hook` shims; their bash suites shrink to shim and wiring cases and every removed case maps to a Go test (L3).
- S5 (registry): `reason-codes.v1.md` emitters, `planted-lib-scripts.txt`, `tool-registry.d/sweep-tools.md` (intended divergences).
- S6 (teeth): "Suites that must stay green with --prove-teeth: sweep-tools(-hook)". Hand mutants of the Go code are killed or proved equivalent.
- S7 (latency): per-call latency of the shim against the old script is measured (first call, warm calls) and reported.

## Tasks
- T1 (S1,S6) feature doc, frozen sha-pinned legacy oracle, pin test — inline — [ ]
- T2 (S1,S2) scenario table + differential + RED against a stub — inline — [ ]
- T3 (S1,S2,S3) implement `rsdd sweep tools` and `--hook` until 0 diffs — inline — [ ]
- T4 (S1) goldens recorded from the frozen scripts + nodiff replay — inline — [ ]
- T5 (S6) boundary unit tests + hand mutants — inline — [ ]
- T6 (S4,S5,S7) shims, reduced bash suites, case map, registry, latency — inline — [ ]

## Log
- L1 (issue #2361 body, verbatim):
  "Phase 2 unit of epic #2270 (plan: odd/tasks/go-port.md, Phase 2 table).

  Port to rsdd (Go): sweep-tools.sh(+hook), verify-tool-catalog.sh(+hook) (paths under research-sdd/toolbelt/ unless prefixed).
  Keep the old entry point as a shim (toolbelt/lib/rsdd-exec.sh); callers (.claude/settings.json, install/pi/research-sdd-hooks.ts, templates) must keep working unchanged.
  Suites that must stay green with --prove-teeth: sweep-tools(-hook), verify-tool-catalog(-hook).
  Depends on: U2.1.
  Acceptance: parity against the bash output over the suite fixtures (testkit/parity), strict TDD with RED executed on the pre-change SUT, mutation teeth, Go build hygiene (GOTMPDIR per lane, no leftover binaries)."
  (title: "feat(rsdd): U2.6 sweep tools and verify tool-catalog"; verify-tool-catalog belongs to session s3, not to this unit.)
- L2 route: all tasks inline. Risk: item 3 (replaces two scripts others call, the SessionStart hook included; the shims keep argv, stdout, stderr and exit codes). Base: origin/main 11569223.
- L3 case->test map: filled in with T6.
- L4 intended divergences: filled in with T3.

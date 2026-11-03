# sweep-breakthroughs-go — port sweep-breakthroughs.sh and its hook to `rsdd sweep breakthroughs` (kit issue #2360, breakthroughs half)
Branch: worktree-agent-a1270f7aa2e001e58 · Delivery: Conventional Commits ending `(#2360)`, no push; the audits half merged in #2596, so the PR closes the issue · Runner: `go test` from research-sdd/rsdd (`./internal/sweep/`, `./internal/testkit/archtest/`, with and without `-tags nodiff`) + bash suites and lints

## Specs
- S1 (parity where a caller depends): "Port to rsdd (Go): sweep-audits.sh(+hook), sweep-breakthroughs.sh(+hook) (paths under research-sdd/toolbelt/ unless prefixed). Keep the old entry point as a shim (toolbelt/lib/rsdd-exec.sh); callers (.claude/settings.json, install/pi/research-sdd-hooks.ts, templates) must keep working unchanged." The report lines and the hook text keep their bytes; only the divergences of L4 differ.
- S2 (typed states, read-only): absent-input, empty-input and no-match stay distinct (CLAUDE.md section 7); an operational failure still exits 1, a finding never does; the port writes nothing under a target or the ledger.
- S3 (reuse): target derivation and the block-file filter from `internal/core/kit`, the walk, skipped naming, options and hook envelope from `internal/sweep`; no second copy.
- S4 (shim): both scripts become `rsdd_exec` / `rsdd_exec_hook` shims; their suites shrink to shim and wiring cases and every removed case maps to a Go test.
- S5 (registry): `reason-codes.v1.md` emitters, `reason-codes.test.sh` GO_SRC / GO_FILES, `tool-registry.md` rows, `tool-registry.d/sweep-breakthroughs.md` (intended divergences).
- S6 (teeth): "Suites that must stay green with --prove-teeth: sweep-audits(-hook), sweep-breakthroughs(-hook)." Hand mutants of the Go code are killed or proved equivalent.
- S7 (latency): per-call latency of the shim against the old script is measured (first call, warm calls) and reported.

## Tasks
- T1 (S1,S6) feature doc, frozen sha-pinned legacy oracle, pin test — inline — [ ]
- T2 (S1,S2) scenario table + differential + RED against a stub — inline — [ ]
- T3 (S1,S2,S3) implement `rsdd sweep breakthroughs` and `--hook` until 0 diffs — inline — [ ]
- T4 (S1) goldens recorded from the frozen scripts + nodiff replay — inline — [ ]
- T5 (S6) boundary unit tests + hand mutants — inline — [ ]
- T6 (S4,S5,S7) shims, reduced bash suites, case map, registry, latency — inline — [ ]

## Log
- L1 (issue #2360 body, verbatim):
  "Phase 2 unit of epic #2270 (plan: odd/tasks/go-port.md, Phase 2 table).

  Port to rsdd (Go): sweep-audits.sh(+hook), sweep-breakthroughs.sh(+hook) (paths under research-sdd/toolbelt/ unless prefixed).
  Keep the old entry point as a shim (toolbelt/lib/rsdd-exec.sh); callers (.claude/settings.json, install/pi/research-sdd-hooks.ts, templates) must keep working unchanged.
  Suites that must stay green with --prove-teeth: sweep-audits(-hook), sweep-breakthroughs(-hook).
  Depends on: U2.1.
  Acceptance: parity against the bash output over the suite fixtures (testkit/parity), strict TDD with RED executed on the pre-change SUT, mutation teeth, Go build hygiene (GOTMPDIR per lane, no leftover binaries)."
- L2 route: all tasks inline. Risk: item 3 (replaces two scripts others call, the SessionStart hook included; the shims keep argv, stdout, stderr and exit codes). Base: origin/main 4acd8c9f.
- L3 hook guard: `core/hookenv` (#2629) is not on origin/main at base, so the hook calls `writeSessionStart` with `// TODO(#2610)`. Exit 1 of the breakthroughs sweep only means could-not-run (a finding never fails), so a later guard needs no `finished` flag.

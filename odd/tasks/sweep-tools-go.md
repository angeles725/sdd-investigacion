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
- T1 (S1,S6) feature doc, frozen sha-pinned legacy oracle, pin test — inline — [x] done
- T2 (S1,S2) scenario table + differential + RED against a stub — inline — [x] done
- T3 (S1,S2,S3) implement `rsdd sweep tools` and `--hook` until 0 diffs — inline — [x] done
- T4 (S1) goldens recorded from the frozen scripts + nodiff replay — inline — [x] done
- T5 (S6) boundary unit tests + hand mutants — inline — [x] done
- T6 (S4,S5,S7) shims, reduced bash suites, case map, registry, latency — inline — [x] done

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
- L3 case->test map (old case -> scenario of `toolScenarios()` in `research-sdd/rsdd/internal/sweep/tools_scenarios_test.go`; each runs in `TestToolsScenarios`, against the frozen scripts in `TestToolsDifferential` and, when golden, in `TestToolsGoldenReplay`):
  - sweep-tools.test.sh: 1 "abs path two tools"; 2 "RESEARCH_HOME form resolves"; 3 "no tools dir is empty-input"; 4 "empty tools dir"; 5 "non-tool file is counted apart"; 6 "retro T-row recorded"; 7 "missing TARGETS.md" (+ "TARGETS.md that is a directory"); 8 "no usable path"; 9 "truncated path is skipped and named"; 10 (broken lib) no equivalent, declared in the header of tools.go; 11 "retros without a tools table"; 12 "ledger only"; 13 "retro and ledger no double count"; 14 "ledger without a table"; 15 "dependency dirs are excluded"; 16 "_lib dir is disclosed"; 16b "package internals are disclosed"; 17 "absent target is disclosed"; 18 "unreadable retro file warns" (+ "unreadable retro warns", a directory named like a retro, + TestToolsRetroRowsCounts); 19 and 19b "unreadable ledger is an error not a zero" (+ TestToolsReadLedgerStates, TestToolsUnreadableThroughTheSeam)
  - its `--prove-teeth` mutants: A extension -> TestToolsIsToolFile; C ledger match -> "ledger only", TestToolsInLedger; B / B-noarg (stub lib) -> no equivalent (the lib is core/kit); D dependency dirs -> "dependency dirs are excluded", TestToolsInDepDir; E `*_lib` -> "_lib dir is disclosed", TestToolsIsLibModule; F absent INFO -> "absent target is disclosed"; G / H / H2 (grep rc) -> the unreadable scenarios and the readFunc seam tests
  - sweep-tools-hook.test.sh: 3 "all-ledgered silent" -> TestToolsHookContext "all ledgered and reached is silent" + scenario silent rows; 4 -> "unrecorded is surfaced"; 5 -> "failure is reported unfiltered" + scenario "missing TARGETS.md" hook; 6 -> "no Summary line is a broken instrument"; 7 -> "absent targets with the PARTIAL warning" / "unrecorded orders warn before absent"; 8 (grep exit 2 on the WARN extraction) no equivalent; 9 -> "absent targets alone are not silent" + scenario "only absent targets still speaks"; 10 -> "unrecorded orders warn before absent"; cases 1-2 and the five hook mutants stay in the shim suite
- L4 intended divergences (documented in research-sdd/toolbelt/tool-registry.d/sweep-tools.md): (1) the dependency-directory exclusion is judged below tools/; (2) a tool name is a literal in T-rows and ledger (no option, no regex); (3) a symlinked tools/ is followed; (4) no helper-missing exits and no grep-extraction messages in the hook. Kept on purpose: unreadable file = typed WARN, NUL file matches nothing.
- L5 RED: `go test ./internal/sweep/ -run TestToolsDifferential` against a stub RunTools that printed nothing: 36 subtests failed, first "abs path two tools: report differs from the frozen script, go rc=0 stdout: (empty), bash rc=0 stdout: TARGET  targetA / tools: 2 found ...". GREEN: 0 diffs over every scenario. Mutants: 62 hand mutants in a module-only copy under -tags nodiff; 56 killed at once, 2 equivalent (dead remainder guard `dir != "/"`, redundant `state == ledgerParsed` conjunct: both removed from the source), 1 lived and was killed by a new case (overlapping ledger occurrence), 3 did not build and were redone as `st.Size()` variants (1 lived: TARGETS.md that is a directory, killed by a new scenario).
- L6 fleet sweep (real TARGETS.md, 21 targets, 15 absent, host locale C.UTF-8): frozen scripts vs `rsdd sweep tools` and `--hook`: stdout, stderr and exit code byte-identical (report 79 lines, hook 6 lines, 410 tools, 53 recorded (retro), 79 recorded (ledger), 278 unrecorded). Latency (RSDD_BIN set, this box): report old first 7860 ms / warm avg 4879 ms, shim first 177 ms / warm avg 163 ms; hook old first 5417 ms / warm avg 6595 ms, shim first 307 ms / warm avg 299 ms.

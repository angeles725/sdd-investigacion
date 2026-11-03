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
- T1 (S1,S6) feature doc, frozen sha-pinned legacy oracle, pin test — inline — [x] done
- T2 (S1) case table from sweep-audits*.test.sh, differential, RED against a stub — inline — [x] done
- T3 (S1,S2,S3) implement `rsdd sweep audits` and `--hook` until 0 diffs — inline — [x] done
- T4 (S1) goldens recorded from the frozen script + nodiff replay — inline — [x] done
- T5 (S6) boundary unit tests + hand mutants — inline — [x] done
- T6 (S4,S5) shims, reduced bash suites, case map, registry — inline — [x] done

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
- L3 case->test map (old case of `research-sdd/toolbelt/tests/sweep-audits.test.sh` -> test in `research-sdd/rsdd/internal/sweep`; scenario names are rows of `auditScenarios()` in `audits_scenarios_test.go`, which also run against the frozen script in `TestAuditsDifferential` and, when marked golden, against `testdata/audits/golden/cases.txt` in `TestAuditsGoldenReplay`):
  - 1 -> scenario "pending marker is surfaced"; 2 -> "applied marker is not pending"; 3 -> "absent marker is pending with status none"; 4 -> "multi-target totals"
  - 5 -> "truncated path is skipped and named" (+ TestAuditSkipped); 6 -> "no truncated path no WARN"
  - 7 -> "missing TARGETS.md" (+ TestAuditsOperationalExits "TARGETS.md that is a directory")
  - 8 -> "aged audit is escalated and sorted first" (+ TestAuditEscalation, TestAuditAgeDays, TestAuditAgeDaysOf, TestSortAuditRows)
  - 9 -> "nested research/audits is listed and aged"; 10 -> "index files are not audits" (+ TestAuditsFindAudits, TestAuditsInAuditsPath)
  - 11 (a broken `lib/target-paths.sh` fails closed) -> no equivalent: the lib is `core/kit` now, there is no helper to break; declared in the header of `audits.go`
  - 12 -> "RESEARCH_HOME form resolves"; 13 -> "no usable path"
  - 14 -> "renamed audit is dated from the rename"; 14b -> "renamed audit with diff.renames true"; 14c -> TestEveryAuditAddDateCallPassesNoRenames + TestAddedDateArgs
  - 15 -> "partial sweep with nothing pending"; 16 -> "clean sweep says nothing to review"; 17 -> "absent target is disclosed"; 18 -> "corpus without audits is disclosed"; 19 -> "absent target and nothing pending"
  - its `--prove-teeth` mutants: the applied|dismissed skip -> TestAuditClosed; the `skipped_count` conjunct and the guidance gate -> TestWriteAuditsReport; the absent INFO emit -> "absent target is disclosed"; `--follow` and the dropped `--no-renames` -> TestAddedDateArgs
  - `sweep-audits-hook.test.sh` cases 3-10 -> TestAuditsHookContextFailure, TestAuditsHookContextHeader, TestAuditsSummaryFilterAbsentCollapse, TestAuditsHookFullIsUnfiltered, TestAuditsSummaryFilterEmptyCollapse (single, early and late); cases 1-2 and the five shim mutants stay in the shim suite
- L4 declared differences (header of `audits.go`): no helper-missing exits; the bash `[: integer expression expected` line of a non-numeric RSDD_RETRO_AGE_DAYS is not printed (the audit is still never escalated); ties sort bytewise; the hook envelope is always JSON. A trailing `--kit` with no value or a caller-passed `--hook`/`--full` act on the Go command, as for `sweep retros`.
- L5 evidence: RED = `TestAuditsDifferential` against a stub `RunAudits` that printed nothing: 52 subtests failed, first "pending marker is surfaced: report differs from the frozen script, go rc=0 stdout: (empty), bash rc=0 stdout: PENDING ... ~3 audited claims ... Summary: 1 pending / 1 audits across targets." GREEN = 0 diffs over every scenario, the threshold and order tests. Fleet sweep: the real kit's TARGETS.md run through the frozen scripts and the Go command (report, hook, hook --full) is byte-identical (rc 0, 43 lines, 1 PENDING, 16 absent-input).
- L6 rebase onto origin/main 0a383e8a (2026-11-03), PR-readiness pass. Findings and fixes:
  - `reason-codes.test.sh` (#2585/#2591 Go scan): `sweep-audits-hook.sh` is a Go-backed `rsdd_exec_hook` shim, which the scan does not read as a shim (it looks for `rsdd_exec `), so the registry row `empty-input` listed an emitter the scan could not find. The row now lists `sweep-audits.sh` only (the Go package behind both scripts is mapped under it); the hook's filter line is emitted by the same package. No row removed, no `reasons.` constant touched; `table_gen.go` regenerated (one cell). 93/93 plain, 178/178 `--prove-teeth`.
  - `hook-emit.test.sh` case 10: the hook shim announces `lib/rsdd-exec.sh`, not `hook-emit.sh`, when its lib is missing (the sweep-retros idiom).
  - `lib-resolution-lint.test.sh` tooth 9 mutated `sweep-audits-hook.sh`, which is now a shim whose planted lib defines no `rsdd_exec_hook`, so the mutant exited 127 ("could not run") instead of executing the planted lib. The tooth now mutates `sweep-breakthroughs-hook.sh`, a bash hook that sources its lib directly.
  - Mutation pass (hand mutants of `audits.go`, `auditsfs.go`, `auditshook.go` under `-tags nodiff`, run in a copy of the module only): 75 mutants tried, 70 killed, 3 equivalent (`max(1, ..)` in the age, `<=` on an unreachable equal epoch, `len("md")`), and two lived because `inAuditsPath` carried a dead remainder-length conjunct (a path ending in ".md" cannot overlap the "/" that ends "/audits/"). The conjunct is removed (`strings.Contains` + `HasSuffix`); `TestAuditsInAuditsPath` already pins the bare "/audits/.md" and the near misses. The new mutants of that function are killed.
  - nodiff tests read only inside the module (`testdata/audits/**`); the `!nodiff` differential reads the toolbelt and is excluded from the bridge job. No new out-of-module path added by this port. No test writes an executable stub after `t.Parallel()` (the audits tests do not use `t.Parallel`).
  - Fleet sweep (real TARGETS.md of this kit, `$HOME` corpora, read-only): frozen script vs `rsdd sweep audits` for the report, `--hook` and `--hook --full`: stdout and stderr byte-identical in all three (report 43 lines, hook and full 6 lines, rc 0), 0 diffs; 1 PENDING, 3 audits, 15 absent-input and 20 empty-input INFO lines.

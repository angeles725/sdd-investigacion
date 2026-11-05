# sweep-all-go — port sweep-all.sh to `rsdd sweep all` (kit issue #2664)
Branch: worktree-agent-a6f5133091dfe14df · Delivery: Conventional Commits ending `(#2664)`, no push · Runner: `go test` from research-sdd/rsdd (`./internal/sweep/`, `./internal/testkit/archtest/`, with and without `-tags nodiff`) + bash suites and lints

## Specs
- S1 (parity where a caller depends): "The aggregator runs the eight canonical session-start sweep scripts. Each runs independently, under a per-script timeout (`RSDD_SWEEP_TIMEOUT`, default 30 s), with stderr merged into stdout. It prints a PASS/FAIL banner per script and exits non-zero when any script fails or times out." The banners, the order and the exit code keep their bytes; callers: `install/adapters.sh`, `install/pi/research-sdd-hooks.ts`, the docs.
- S2 (exec the shims, no cross-domain import): "the Go side execs the toolbelt shims rather than importing other domains. It sets `cmd.Env = kit.ShimEnv(s.Environ(), os.Executable)` and bounds each run through `core/proc`."
- S3 (oracle): "a frozen, sha-pinned oracle with a differential and golden replay; RED executed on the unported command."
- S4 (defects): "legacy defects fixed and pinned, and documented in `tool-registry.d/sweep-all.md`."
- S5 (subprocess record, no host branching): "a recorded subprocess list (L29); tests that do not branch on host tools (L60): the timeout and the missing-script paths come from stub scripts."
- S6 (teeth): "hand mutants killed, and a package-scoped gremlins run with 0 lived (L56)" (gremlins is the orchestrator's heavy slot: not run here).
- S7 (latency): "latency measured."
- S8 (shim): `sweep-all.sh` becomes an `rsdd_exec` shim; its suite shrinks to shim and wiring cases; every removed case maps to a Go test.

## Tasks
- T1 (S3) feature doc, frozen sha-pinned legacy oracle, pin test — inline — [x]
- T2 (S1,S3,S5) scenario table + differential + RED against the unported command — inline — [x]
- T3 (S1,S2,S4) implement `rsdd sweep all` until 0 diffs — inline — [x]
- T4 (S3) goldens recorded from the frozen script + nodiff replay — inline — [x]
- T5 (S6) boundary unit tests + hand mutants — inline — [x]
- T6 (S7,S8) shim, reduced suite, case map, registry, latency, real-kit comparison — inline — [x]

## Log
- L1 (issue #2664 body, verbatim):
  "Unit of epic #2270 (Go port), s2 lane (sweep family).

  Port `research-sdd/toolbelt/sweep-all.sh` to rsdd (Go) as `rsdd sweep all` in `internal/sweep`, and keep the script as an `rsdd_exec` shim. Its callers keep working unchanged: `install/adapters.sh`, `install/pi/research-sdd-hooks.ts` and the docs.

  The aggregator runs the eight canonical session-start sweep scripts. Each runs independently, under a per-script timeout (`RSDD_SWEEP_TIMEOUT`, default 30 s), with stderr merged into stdout. It prints a PASS/FAIL banner per script and exits non-zero when any script fails or times out.

  The scripts span several domains (sweep and verify), so the Go side execs the toolbelt shims rather than importing other domains. It sets `cmd.Env = kit.ShimEnv(s.Environ(), os.Executable)` and bounds each run through `core/proc`.

  Acceptance:
  - a frozen, sha-pinned oracle with a differential and golden replay;
  - RED executed on the unported command;
  - legacy defects fixed and pinned, and documented in `tool-registry.d/sweep-all.md`;
  - a recorded subprocess list (L29);
  - tests that do not branch on host tools (L60): the timeout and the missing-script paths come from stub scripts;
  - hand mutants killed, and a package-scoped gremlins run with 0 lived (L56);
  - latency measured."
- L2 route: all tasks inline (no parallel-unit writer reason). Risk: item 3 (replaces a script that adapters, the Pi hook and the docs call; the shim keeps argv, stdout, stderr and exit code). Base: origin/main b01e706b.
- L3 case->test map (old case of `tests/sweep-all.test.sh` -> scenario of `allScenarios()` in `research-sdd/rsdd/internal/sweep/all_scenarios_test.go`; each runs in `TestAllScenarios`, against the frozen script in `TestAllDifferential` and, when golden, in `TestAllGoldenReplay`):
  - 1 (exists) and 2 (executable) -> shim case 1 of the reduced suite; 3 (all-pass) -> "all eight pass", "an empty timeout means the default"; 4 (one-fail) -> "first script fails", "second script fails", "last script fails with exit 3", "exit codes are reported as they are", "every script fails"; 5 (run-all, no early bail) -> every failing row asserts the PASS banners of the scripts after it, TestAllSubprocessRecord (eight children, in order), and the early-bail teeth mutant -> mutants M03/M07 of the evidence below; 6 (banners) -> "each banner holds the script output", "a failing script keeps its output"; 7 (timeout) -> "a hanging script is killed and the rest run", "a hanging grandchild is killed with its script", "a fractional timeout", "a script within the timeout passes", TestAllTimeoutReachesTheRunner; 8 (timeout banner) -> the same rows ("timed out after 1s" / "0.5s"); 9 (parity with the registered SessionStart hooks) and 10 (real scripts exist and are executable) -> kept in the reduced bash suite as cases 10 and 11, reading `allscripts.go` (with their teeth); TestAllScriptsAreTheEight pins the Go list; its teeth mutants (early-bail, dropped, extra, missing script) -> the reduced suite's parity/real-script teeth and Go mutants S01-S03.
  - new rows with no old case: the missing-script rows ("first script is missing", "last script is missing", "no script exists", "a directory is not a script"), the stream rows (stderr merged in order, stderr only, no trailing newline, silent script), "scripts run in the caller's directory", "the environment reaches the scripts", "a script reads an empty stdin", "a script is run by bash without the execute bit".
- L4 intended divergences (documented in research-sdd/toolbelt/tool-registry.d/sweep-all.md; no oracle, `all_divergence_test.go` and `all_unit_test.go`): (1) a script that exits 124 is "exit 124", not a timeout; (2) a SIGTERM-ignoring script is killed after the grace period instead of hanging the aggregator; (3) a signal-killed script is "killed by signal N"; (4) RSDD_SWEEP_TIMEOUT must be a positive number of seconds (<= 1 year), else 30 s plus a `sweep-all: warning:` line (the script failed all eight with exit 125 for `abc`, ran unbounded for `0`, printed `2ms` for `2m`); (5) per-script output bound of 4 MiB; (6) a typed `cannot start` banner; (7) a process group that cannot be stopped is a FAIL; (8) the children get RSDD_BIN (kit.ShimEnv). Kept on purpose: a non-executable script still runs (the header's FAIL promise was never true); the real toolbelt's modes are checked by the shim suite.
- L5 reason-codes: the timeout fallback line is deliberately `sweep-all: warning:` and not a `degraded:` line, so no registry row (and no `table_gen.go` change) is needed; the sweep still ran with a valid bound, so the measurement is not invalid. Only `GO_SRC` / `GO_FILES` got a `sweep-all.sh` entry (`all*.go` matches exactly all.go, allrun.go, allscripts.go, alltimeout.go; `audits*.go` does not match them).
- L7 evidence. RED (stub command registered in commands.go, scenarios and differential run before the port): `RED: rsdd-go.test.sh internal/sweep TestAllScenarios/all_eight_pass — all_scenarios_test.go:189: exit code 2, want 0 ... stderr: sweep-all: not ported` (every TestAllDifferential row failed too: go rc=2 against the frozen script's rc 0). Mutants: 71 hand mutants over all.go, allrun.go, alltimeout.go and allscripts.go (module-only copy outside the repo, `-tags nodiff`, copy deleted): 69 KILLED, 2 equivalent (T12 `def.shown` -> literal "30" is the same string; T14 `[0-9]+` -> `[0-9]*` in the whole-number branch only admits the empty string, which returns before the regexp is used). First-round survivors were closed with tests (kit resolution without --kit, signal 1, the 4 MiB default, the exact warning text). Real kit (the kit checkout and its fleet TARGETS.md, RSDD_BIN set, RSDD_SWEEP_TIMEOUT=300): the frozen script and the shim print eight banners each; stdout (55865 bytes), stderr (empty) and the exit code (1: verify-kit-clean reports the worktree dirty) are byte-identical. Latency, whole run over the real kit (ms, shared machine): frozen script first 21590 / warm 18256, 18838; shim first 15643 / warm 15192, 15291.
- L6 suites changed because a failing suite required it: `tests/pi-hooks.test.sh` read the script list out of `sweep-all.sh` (`$TOOLBELT/<name>.sh`); it reads `rsdd/internal/sweep/allscripts.go` now (the same eight names, both directions).
- L8 (2026-11-05, s2) rebase + RDD rerun: branch merged with origin/main 743af41e (clean; `go generate` of core/reasons: no diff). Per-commit RDD on the merged shas: a66b452b (oracle) and 13b87007 (shim) high, approved+acked; 4a3bdd04 (port) high, correction_required R3-ignored-args: `RunAll` reused sweep's shared `parseOptions` and dropped `--json`, `--hook`, `--full` and stray words with rc 0. Fixed in 967ca19b as an intended divergence (own `parseAllOptions`: `--kit DIR` only, anything else exits 2 before any banner; row in tool-registry.d/sweep-all.md; RED executed: TestAllCommandLine failed with rc=0 and the full report for each of the four arguments). 967ca19b assessed medium, under budget. The 4a3bdd04 lineage stays at correction_plan_required and binds nothing on the new commit. Follow-up (pre-existing, not this unit): sweep's shared `parseOptions` also ignores unknown arguments for retros/audits/tools/breakthroughs.

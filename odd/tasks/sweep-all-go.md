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
- T1 (S3) feature doc, frozen sha-pinned legacy oracle, pin test — inline — [ ]
- T2 (S1,S3,S5) scenario table + differential + RED against the unported command — inline — [ ]
- T3 (S1,S2,S4) implement `rsdd sweep all` until 0 diffs — inline — [ ]
- T4 (S3) goldens recorded from the frozen script + nodiff replay — inline — [ ]
- T5 (S6) boundary unit tests + hand mutants — inline — [ ]
- T6 (S7,S8) shim, reduced suite, case map, registry, latency, real-kit comparison — inline — [ ]

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

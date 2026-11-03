# Port stage-retro.sh to Go (`rsdd retro stage`) — kit issue #2663
Objective: `research-sdd/toolbelt/stage-retro.sh` becomes a `rsdd_exec` shim over `rsdd retro stage` (package `internal/retro/stage`); legacy defects fixed on the Go side. Branch: worktree-agent-a4129bfe103a7a8ac. Delivery: `ask-on-risk`, commits of ~400 lines, no push. Runner: `go test ./internal/retro/... ./internal/testkit/archtest/` (both tag sets) and the bash suites under `toolbelt/tests`.
Mirror (Engram `odd/stage-retro-go/tasks`): pending, the mirror is written by the orchestrator session.

## Specs
- S1 "Port `research-sdd/toolbelt/stage-retro.sh` to rsdd (Go), as a new `internal/retro/stage` package registered from the retro domain. The script creates a review branch in the kit repository for one pending §18 retro and prints its deltas and next steps. Keep `stage-retro.sh` as an `rsdd_exec` shim, so docs, `verify-cd-physical.sh` and templates keep working unchanged."
- S2 "Reuse `core/retrogrammar` for the review-status marker logic that `lib/retro-status.sh` provides, `core/kit` for target paths and `core/git` for git plumbing; never copy them. The lib itself stays bash while `research-sdd-status.sh` still sources it."
- S3 "a frozen, sha-pinned oracle with a differential and golden replay;"
- S4 "RED executed on the unported command;"
- S5 "legacy defects fixed and pinned, and documented in `tool-registry.d/stage-retro.md`;"
- S6 "hand mutants killed, and a package-scoped gremlins run with 0 lived (L56);" (the orchestrator forbids running gremlins in this unit: hand mutants only)
- S7 "tests that do not branch on host tools (L60);"
- S8 "the git side effects asserted (branch created, nothing else touched);"
- S9 "latency measured."
- S10 Exit codes unchanged where a caller can depend on them: 0 staged, 1 usage / helper, 2 excluded or already applied|dismissed, 3 dirty kit repo, 5 branch cannot be created or checked out, 6 fetch failed, 7 self-referential retro not on origin/main, 8 retro unreadable after checkout.

## Tasks
- T1 (S3, S4) freeze the legacy script + libs sha-pinned, harness, cases, differential, RED — route inline — commit: d3e020e1 (oracle freeze)
- T2 (S1, S2, S5, S8) the port: plan/slug/sections/selfref/git steps/command, registered from `internal/retro/commands.go` — inline — commit: 9ca47125
- T3 (S3, S7, S8) goldens recorded from the frozen script, go-only divergence tests — inline — commit: c5c7d971, 95929636, fec1883a (nodiff edge tests)
- T4 (S1, S5, S9) shim switch, shrunk bash suite, reason-codes, tool-registry — inline — commit: 777fd348 (suite shrink, script still live), 1532f06f (shim switch)
- T5 (S6) hand mutants under `-tags nodiff`, dead-code removal — inline — commit: none (16 hand mutants killed in an out-of-repo copy, deleted; dead helpers dropped in 95929636)

## Case map (every case of `tests/stage-retro.test.sh`)
Go tests live in `research-sdd/rsdd/internal/retro/stage`. "golden" = recorded from the frozen script by `TestDifferential`, replayed by `TestGoldenReplay` (case names `parity/<n>`).
- 1 happy path -> parity/01-pending-stages-branch
- 2 applied refused, no branch -> parity/02-applied-refused
- 3, 4 broken retro-status helper fail-closed -> no Go equivalent (the grammar is linked in; shell wiring). Replaced by `TestNoHelperFilesAreNeeded` (the port runs with no lib/ beside it).
- 5 missing retro arg with broken helper -> parity/05-missing-retro-arg
- 6 Retro: trailer -> parity/06-trailer-sha
- 6b relative retro path keeps the sha -> parity/06b-relative-retro
- 7 excluded -> parity/07-excluded-refused
- 8 tools table printed -> parity/08-tools-table
- 8b tools range bounded -> parity/08b-tools-range-bounded
- 9 fetch failure -> parity/09-fetch-fails
- 10, 10b branch at origin/main, no upstream -> parity/10-behind-origin (state records the upstream)
- 11 checkout -b failure exit 5 -> parity/11-checkout-b-fails
- 12 symlinked toolbelt -> `TestResolvedKitToolbeltStagesThroughTheKit` + shim e2e case 5b of the bash suite
- 13 self-ref unpushed -> parity/13-selfref-unpushed
- 14 existing branch held by another worktree -> parity/14-existing-branch-held
- 15 stale branch predates the retro (exit 8) -> parity/15-stale-branch
- 15b plain `branch -D` succeeds after exit 8 -> asserted in the state fingerprint of parity/15 (HEAD is back on main) and `TestExit8LeavesBranchDeletable`
- 15c switch-back fails -> `TestExit8SwitchBackFails` (git wrapper, wrapper-in-use asserted)
- 15d switch-back ok wording -> parity/15-stale-branch
- 16 stale blob on origin -> parity/16-selfref-stale-blob
- 16b/c/d/e advice texts -> parity/16b-.., 16c-.., 16d-.., 16e-..
- 17 symlinked retros dir -> parity/17-selfref-symlinked-retro
- 20 registered name != basename -> parity/20-registered-name
- 21 nested corpus -> parity/21-nested-corpus
- 22 nearest ancestor (both orders) -> parity/22a-nearest, parity/22b-nearest-reversed
- 23 unregistered -> parity/23-unregistered
- 24 absent / empty TARGETS.md -> parity/24a-no-targets, parity/24b-empty-targets
- 25 missing target-paths helper -> no Go equivalent (shell wiring); same as 3/4
- teeth block (mutation controls that `sed` the old script) -> replaced by the hand mutants of T5 and typed SKIP lines naming these tests in the bash suite.

## Log
L1 (2026-11-03, verbatim, issue #2663 body):
Unit of epic #2270 (Go port), s2 lane (retro family).

Port `research-sdd/toolbelt/stage-retro.sh` to rsdd (Go), as a new `internal/retro/stage` package registered from the retro domain. The script creates a review branch in the kit repository for one pending §18 retro and prints its deltas and next steps. Keep `stage-retro.sh` as an `rsdd_exec` shim, so docs, `verify-cd-physical.sh` and templates keep working unchanged.

Reuse `core/retrogrammar` for the review-status marker logic that `lib/retro-status.sh` provides, `core/kit` for target paths and `core/git` for git plumbing; never copy them. The lib itself stays bash while `research-sdd-status.sh` still sources it.

Acceptance:
- a frozen, sha-pinned oracle with a differential and golden replay;
- RED executed on the unported command;
- legacy defects fixed and pinned, and documented in `tool-registry.d/stage-retro.md`;
- hand mutants killed, and a package-scoped gremlins run with 0 lived (L56);
- tests that do not branch on host tools (L60);
- the git side effects asserted (branch created, nothing else touched);
- latency measured.

L2 planned legacy defects to fix (each pinned by a Go test): D1 `git checkout -q main` pointlessly moves the shared checkout and fails (exit 4) when main is held by another worktree; D2 a slug/label that is not a valid ref name fails only after the checkout of main and the fetch; D3 an all-non-ASCII file name gives an empty slug, so two retros share one branch; D4 a mistyped second argument is silently ignored and `--force` still prints "Use --force"; D5 `sed '$d'` drops the last CONTENT line when the section runs to EOF; D6 a retro with no Proposed deltas section prints nothing, silently; D9 a kit root that is not a git repo is read as "clean"; D10 git fetch is unbounded; D13 a single quote in the target label or file name breaks the suggested shell commands; D14 an unreadable retro is staged (branch created) and only refused after the checkout.

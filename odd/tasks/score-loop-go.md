# score-loop-go: port score-loop-transcript.sh to `rsdd eval score-loop`
Objective: Go port in internal/eval/scoreloop, thin rsdd_exec shim. Branch feat/score-loop-go, delivery single-pr.
Runner: go test (internal/eval/...) + score-loop-transcript.test.sh --prove-teeth.

## Specs
- S1. `rsdd eval score-loop <same args>` reproduces score-loop-transcript.sh: identical stdout, stderr and exit code on every case of score-loop-transcript.test.sh and on a differential test that runs the frozen legacy script (copy it to research-sdd/rsdd/internal/eval/scoreloop/testdata/legacy/, test file tagged `//go:build ... && !nodiff`) against the Go command over every fixture plus generated edge cases (empty/absent/unreadable transcript, malformed JSONL, out-of-span commits, first/middle/last positions, single element).
- S2. A legacy defect found while porting is fixed in Go, pinned by a test, and documented as an intended divergence in research-sdd/toolbelt/tool-registry.d/score-loop-transcript.md (the differential declares it explicitly; never silently). Anti-silent-zero: absent-input / empty-input / no-match / degraded stay distinguishable; probe every runtime dependency (git, the status script) and emit a typed degraded state.
- S3. Layout: package research-sdd/rsdd/internal/eval/scoreloop (files of ~200 lines max, one responsibility each: args, transcript parsing, git window, each criterion, render), domain registry research-sdd/rsdd/internal/eval/commands.go, one new line in research-sdd/rsdd/internal/commands/commands.go. Reuse internal/core helpers (core/git, core/proc, core/kit, core/state, jsonout) - never re-implement a helper that exists; archtest must stay green.
- S4. research-sdd/toolbelt/score-loop-transcript.sh becomes a thin shim (`rsdd_exec eval score-loop "$@"`, same shape as sweep-retros.sh), added to research-sdd/toolbelt/tests/fixtures/lib-resolution/planted-lib-scripts.txt if required by lib-resolution-lint; the existing suite passes against the shim (cases that test bash internals move to Go tests, each removed case mapped to its Go test in the feature doc). Update reason-codes.v1.md / reason-codes.d (emitter now the Go command) and run `go generate ./internal/core/reasons/...` if the table changes; update help text.
- S5. Teeth: every logic branch is killed by a nodiff-visible unit or golden-replay test (freeze oracle outputs as goldens under testdata/), so `make teeth TEETH_PKG=./internal/eval/scoreloop` reads Lived 0 under a CI-like PATH (python3 and jq present, bwrap absent). RED executed: show the Go tests failing against a stub/empty implementation before GREEN.

## Tasks
- [ ] T1 S1,S5 inline: freeze legacy + black-box case table + goldens + differential (stub Run, RED) - commit: pending
- [ ] T2 S1,S2,S3,S5 inline: Go implementation (modular package) + unit tests, GREEN - commit: pending
- [ ] T3 S4 inline: shim, suite adaptation, registries, docs, planted-lib list - commit: pending
- [ ] T4 S5 inline: teeth Lived 0 under CI-like PATH, lint, cross build, bash suites - commit: pending

## Log
- L1: "necesitamos pasar todo lo que tenemos python a GO, todo lo que se pueda mejorar, necesitamos que se mejore el codigo, optimizacion de codigo, necesitamos que el codgio de progrmaacion sea modular, paraq ue en caso de tengamos que modificar algo, anadir algo sepamos en donde tener que hacer eso."
- L2 (2026-11-05): worktree agent-acbd6f388bbe8f65a reset to origin/main 743af41e, branch feat/score-loop-go. Route: inline (one unit; I am the bounded writer, no Writer trigger).

# maint-batch-go — port toolbelt/maint/{kit-maint-common,kit-gate,kit-wait-merge,kit-pr-pipeline,kit-size-check}.sh to `rsdd maint <tool>`
Branch feat/maint-batch-go · delivery single-pr (no push, no PR) · runner `go test` (focused, -p 1) + bash suites with --prove-teeth, teeth via heavy-run `make teeth TEETH_PKG=...`

## Specs
- S1. Each `rsdd maint <tool>` reproduces its script: identical stdout, stderr and exit code on every case of its existing suite and on a differential test against the frozen legacy script under testdata/legacy (test files `//go:build ... && !nodiff`), covering first/middle/last/single, absent/empty/unreadable inputs and every flag.
- S2. Legacy defects found while porting are fixed, pinned by a test, and documented as intended divergences in research-sdd/toolbelt/tool-registry.d/<tool>.md; typed absent-input / empty-input / no-match / degraded states stay distinct; every runtime dependency (git, gh, gentle-ai) is probed and a missing one is a typed DEGRADED. Each command has its own strict parser (unknown word = exit 2).
- S3. Layout: one package per tool under research-sdd/rsdd/internal/maint/<tool>/ (files ~200 lines max, one responsibility each), shared code once (in internal/core or an exported internal/gate API used by both gate and maint); registered in internal/maint/commands.go; archtest green; mergetrain uses the in-process code.
- S4. The five scripts become thin shims (`rsdd_exec maint <tool> "$@"`; kit-maint-common.sh is deleted if nothing sources it any more, else reduced); suites pass against the shims, with cases that test bash internals moved to Go tests (map each removed case -> Go test in the feature doc); update planted-lib-scripts.txt / planted-lib-exclusions.txt, reason-codes.v1.md / reason-codes.d/<tool>.md (+ `go generate ./internal/core/reasons/...`), tool-registry.md rows, suite-durations.txt rows, help text; delete the ./internal/maint line of research-sdd/rsdd/teeth-debt.txt only if teeth for ./internal/maint read Lived 0 with tests repointed through internal/testkit/kitroot.
- S5. Teeth: `make teeth TEETH_PKG=./internal/maint/<tool>` (each new package, and ./internal/gate if touched) reads Lived 0 under a CI-like PATH (python3 and jq present, bwrap absent); oracle-only logic gets frozen goldens + nodiff replay; RED executed against an empty implementation before GREEN.

## Design
archtest lets a domain import only the core tier, so gate (mergetrain) and maint share through internal/core:
- core/kitmaint: kit-maint-common (typed lines, retry, physical path, state dir, number parsing), child runners (git/gh), flock and process-group helpers.
- core/kitgate: the flock-serialised gate run (kit-gate). core/kitwait: CI wait + merge-gate + MERGED check (kit-wait-merge).
- maint/gate, maint/waitmerge, maint/prpipeline, maint/sizecheck: one command each; gate/mergetrain consumes core/kitgate + core/kitwait in process.

## Tasks
- [x] T1 shared extraction core/kitmaint + core/kitgate + core/kitwait; mergetrain consumes it (S3) · inline · commit: 66f26be4 · internal/gate ok (131 s)
- [x] T2 `rsdd maint gate` (kit-gate) (S1 S2 S3) · inline · commit: 29bae3f2 · 34-scenario differential green
- [x] T3 `rsdd maint wait-merge` (kit-wait-merge) (S1 S2 S3) · inline · commit: ac1775d7 · 41-scenario differential green
- [x] T4 `rsdd maint pr-pipeline` (kit-pr-pipeline) (S1 S2 S3) · inline · commit: 5cad7bcd · 50-scenario differential green
- [x] T5 `rsdd maint size-check` (kit-size-check) (S1 S2 S3) · inline · commit: 6b4d294b · 70-scenario differential green
- [x] T6 shims, suites, registry / reason-codes / planted-lib docs (S4) · inline · commit: 121623c4 · 14 bash suites green with --prove-teeth
- [ ] T7 teeth per package, RED evidence, checks (S5) · inline · commit: -

## Log
- L1 (2026-11-05, user, verbatim): "necesitamos pasar todo lo que tenemos python a GO, todo lo que se pueda mejorar, necesitamos que se mejore el codigo, optimizacion de codigo, necesitamos que el codgio de progrmaacion sea modular, paraq ue en caso de tengamos que modificar algo, anadir algo sepamos en donde tener que hacer eso."
- L2: CodeGraph init refused by the harness worktree-isolation guard; normal tools used.

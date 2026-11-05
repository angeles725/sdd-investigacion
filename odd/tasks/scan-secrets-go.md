# scan-secrets.sh port to Go (`rsdd secrets scan`)
Objective: port toolbelt/scan-secrets.sh (SECURITY scanner) to Go, engine in internal/core/secretscan (core tier, so internal/corpus can call it in process; archtest forbids a domain importing a domain), domain command in internal/secretscan, thin rsdd_exec shim. Branch feat/scan-secrets-go, delivery single-pr, runner go test (focused, GOMAXPROCS=2) + bash suites with --prove-teeth + make teeth per package.

## Specs
- S1. `rsdd secrets scan` reproduces scan-secrets.sh: identical stdout, stderr and exit code on every case of its existing suite and on a differential test against the frozen legacy script under testdata/legacy (test files `//go:build ... && !nodiff`; goldens replayed under nodiff), covering every rule/pattern, every flag (incl. --files-from), first/middle/last/single entries, absent/empty/unreadable inputs, binary files, symlinks, NUL/newline in names.
- S2. Legacy defects found while porting are fixed, pinned by a test, and documented as intended divergences in research-sdd/toolbelt/tool-registry.d/scan-secrets.md - a divergence may only make detection STRICTER or a state more explicit, never let a secret through. Typed absent-input / empty-input / no-match / degraded / unreadable states stay distinct; every runtime dependency is probed; own strict parser (unknown word = exit 2).
- S3. Layout: package(s) under research-sdd/rsdd/internal/secretscan/ (files ~200 lines max, one responsibility each: rules/patterns data separate from logic, file walking, reporting); exported API used in process by internal/corpus (archive_secrets.go) with the archive goldens byte-identical; registered via a domain commands.go and one line in internal/commands/commands.go; archtest green.
- S4. scan-secrets.sh becomes a thin shim (`rsdd_exec secrets scan "$@"`); its suite passes against the shim, with cases that test bash internals moved to Go tests (map each removed case -> Go test in the feature doc); update planted-lib lists, reason-codes.v1.md / reason-codes.d/scan-secrets.md (+ `go generate ./internal/core/reasons/...`), tool-registry rows, suite-durations.txt row, tests/reason-codes.test.sh GO_SRC (one line) if the emitter scanner needs it.
- S5. Teeth: `make teeth TEETH_PKG=<each new package>` and ./internal/corpus if touched reads Lived 0 under a CI-like PATH (python3 and jq present, bwrap absent); RED executed against an empty implementation before GREEN.

## Tasks
- T1 (S1-S5) feature doc - route: inline - status: done - commit: (this commit)
- T2 (S1) freeze legacy script under testdata/legacy - route: inline - status: pending
- T3 (S1, S2, S3) engine core/secretscan + domain command + registration - route: inline - status: pending
- T4 (S1) differential harness + golden corpus - route: inline - status: pending
- T5 (S3) corpus archive calls the engine in process - route: inline - status: pending
- T6 (S4) shim, suite, registries, planted-lib lists - route: inline - status: pending
- T7 (S5) teeth per package - route: inline - status: pending

## Log
- L1: "necesitamos pasar todo lo que tenemos python a GO, todo lo que se pueda mejorar, necesitamos que se mejore el codigo, optimizacion de codigo, necesitamos que el codgio de progrmaacion sea modular, paraq ue en caso de tengamos que modificar algo, anadir algo sepamos en donde tener que hacer eso."
- L2: "package named internal/secretscan because a global deny rule blocks directories named secrets (s1 decision)"
- L3 (finding): archtest forbids a domain importing another domain, and internal/corpus must call the scan in process, so the engine lives in internal/core/secretscan (core tier) and internal/secretscan is the thin domain package (commands.go, strict parser). The branch name feat/scan-secrets-go pre-existed as a stale ref at c0ccf0c2 with no unique commits; it was reset to origin/main.
- L4 (finding): the local grep is ugrep 7.8.4, not GNU grep; legacy output order of a multi-file walk is readdir order, so the Go walk is sorted by path and the differential compares such cases as line sets.

# writer-check-go — port toolbelt/maint/kit-writer-check.sh to `rsdd maint writer-check`
Branch feat/writer-check-go · delivery: one PR (commits < ~1200 changed lines each for the RDD lens budget) · runner: go test (both builds) + bash suites via run-all.
Risk: item 3 (a CLI others consume: the writer checklist, CLAUDE.md §4).

## Specs
- S1 (s1 assignment, verbatim): "Port toolbelt/maint/kit-writer-check.sh (382 lines) and toolbelt/maint/kit-flake-hunt.sh (336) to `rsdd maint writer-check` and `rsdd maint flake-hunt`."
- S2: "One package per command under internal/maint/ (internal/maint/writercheck, internal/maint/flakehunt). Reuse the core packages #2711 extracted (core/kitmaint: lock, git/gh helpers, typed degraded; core/kitgate; core/kitwait) — never duplicate."
- S3: "Same recipe as #2711: frozen legacy oracle, differential (!nodiff) + goldens (nodiff), scripts become rsdd_exec shims, divergences in tool-registry.d/, teeth Lived 0, one impacted gate. Mind L80–L96 (esp. L93 summary-line, L94 readdir order). Split every commit under ~1200 changed lines for the RDD lens budget."
- S4: user directive: "necesitamos que se mejore el codigo, optimizacion de codigo, necesitamos que el codgio de progrmaacion sea modular" — modules of about 200 lines or less, one responsibility each; fix legacy defects while porting and document each intended divergence.
- S5: `kit-writer-check` shares its name-kill verdict list with the PreToolUse hook; `tests/fixtures/kit-writer-check/name-kill-corpus.txt` and `production-paths.txt` are the frozen contract (CLAUDE.md §4) — keep both readers in agreement, and `--classify` in step with `.github/scripts/parse-red-evidence.cjs`. Contract files stay read-only.

## Tasks
- T1 (S1-S5) port + oracle + differential/goldens + shim + registry/reason-codes docs · route: delegated writer (parallel units, writer trigger a) · status: done on feat/writer-check-go (oracle+scenarios, port, unit/corpus/divergence tests, goldens, shim+docs); two files outside the writer's surface still need one line each: tests/reason-codes.test.sh (GO_NO_TYPED) and tests/fixtures/lib-resolution/planted-lib-exclusions.txt
- T2 (S3) teeth Lived 0 + impacted gate · route: parent via heavy-run · status: open
- T3 (S5) RDD per commit; independent verifier when the Risk line names item 5 · status: open

## Log
- L1 (user, verbatim excerpt): "necesitamos pasar todo lo que tenemos python a GO, todo lo que se pueda mejorar, necesitamos que se mejore el codigo, optimizacion de codigo, necesitamos que el codgio de progrmaacion sea modular ... Trabajen con commit + push + pr + pr view + issues + merge, etc."
- L2 2026-11-05: s1 assigned maint batch 2 to s2; PLAN sent, s3 no CONFLICT.
- L3 2026-11-05 (writer): S1-S5 covered. Intended divergences are listed in toolbelt/tool-registry.d/kit-writer-check.md and pinned by Go tests; the behaviour's mutation controls moved to the Go package, the bash suite's --prove-teeth now mutates the shim.

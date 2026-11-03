# reconcile-issues.sh -> rsdd retro reconcile (#2563)
Objective: port `research-sdd/toolbelt/reconcile-issues.sh` to Go in `internal/retro/reconcile`, keep the script as an `rsdd_exec` shim, and replace `tests/reconcile-issues.test.sh` with Go tests. Branch per slice from origin/main (`feat/2563-reconcile-s<N>`). Delivery: chained PRs, one per slice, each about 400 authored lines (goldens and fixtures excluded) and under the RDD lens budget. Runner: `go test` in research-sdd/rsdd (writers run focused package tests only), `--prove-teeth` suites via kit-writer-check.sh.

## Specs
- S1 Byte parity. `rsdd retro reconcile` prints the same stdout, stderr and exit code as the frozen `reconcile-issues.sh` for every case the bash suite covers. Proved by a differential test against the frozen legacy script (`testdata/legacy/reconcile-issues.sh`, sha-pinned; `//go:build !nodiff`), plus goldens replayed by a nodiff-visible Go test.
- S2 Package API, agreed with session 4 for #2549 (`rsdd status show`):
  `type Options struct { Retro string; IssuesCache *Cache /* nil = per-retro gh */; GH gh.Runner /* injected, bounded */; Timeout time.Duration }`
  `type Report struct { Untracked []Delta; Tracked []Delta; Degraded string /* "" = not degraded */; OutOfScopeMarker string /* "" = none */ }`
  `func Run(ctx context.Context, o Options) (Report, error)` — the error is operational only, and a context deadline is returned wrapped (`errors.Is(err, context.DeadlineExceeded)`).
  `func LoadCache(ctx, gh, repo) (*Cache, error)` — the batch prefetch, reusable across retros.
  `func (r Report) Render(stdout, stderr io.Writer) int` — legacy text plus exit code, for the shim.
  The per-retro gh re-verify, which runs when the batch cache reports untracked deltas, stays inside Run. Report may gain the other classes (orphaned, shipped, borderline, regressed) and notes, but it must keep these fields and their meaning.
- S3 Reuse. Retro parsing and marker logic come from `internal/retro/grammar` (Delta, entry/alt rows, MarkerScopeLine, StatusFromMarkerLine, MarkerOutOfScope ...), the gh calls from `internal/core/gh`, and git from `internal/core/git`. No re-implementation of a grammar rule.
- S4 Typed states (CLAUDE.md §7). absent-input, empty-input, no-match, degraded (`degraded:` + exit as legacy) and out-of-scope stay distinct; a missing gh or git, or an unknown main ref, is never a silent pass.
- S5 Shim and deletion. `reconcile-issues.sh` becomes `rsdd_exec retro reconcile "$@"` (the shared shim idiom; listed in tests/fixtures/lib-resolution/planted-lib-scripts.txt). Every removed bash case maps to a Go test in the PR body. Callers (research-sdd-status.sh issues_due_gate, sweep hooks) keep working unchanged.
- S6 Registry and docs. tool-registry.md row, reason-codes.v1.md emitters (Go source scanned by reason-codes.test.sh), and the rsdd help text, updated in the same slice that changes them.
- S7 Acceptance fleet sweep. The real retros across TARGETS.md are compared, old script against new, with the same --issues-cache/--closed-cache snapshot: byte-identical stdout, stderr and exit code, with every difference classified by hand.
- S8 Teeth. Lived 0 for internal/retro/reconcile under the CI-like PATH (python3 and jq present, bwrap absent); every oracle or differential test file is `!nodiff`.

## Tasks
- T1 S1 S2 S3 S4 — slice 1: freeze the legacy oracle; core classification of one retro against --issues-cache (tracked / untracked / orphaned, legacy signature, delta forms, marker scope); Report/Render; differential plus goldens for those cases. Route: delegated writer (context backstop; parallel with CI watchers). Status: done (PR, commits 3de12808..e0aeba26; merge sha recorded on merge).
- T2 S1 S4 — slice 2: --closed-cache: shipped / borderline / regressed, the closure-evidence grammar, git reachability (RECONCILE_ISSUES_MAIN_REF / _GIT_DIR), shallow-clone. Route: delegated writer. Status: done (branch feat/2563-reconcile-s2 on top of s1 28d2fd61; commits recorded on the PR).
- T3 S1 S2 S5 S6 S8 — slice 3: --all over TARGETS.md, live gh (LoadCache, per-retro re-verify), the `rsdd retro reconcile` command, shim, deletion of the bash suite with the case map, registry. Route: delegated writer. Status: open.
- T4 S7 — fleet sweep and acceptance. Route: inline. Status: open.

## Log
- L1 (2026-11-01, user, verbatim): "Vamosa a trabajar con ODD + RDD(granted), si GENTLE-AI pide revision, dale permisos para que revise. Ahora vamos a realizar lo siguiente: Primero, necesitamos pasar todo lo que tenemos python a GO, todo lo que se pueda mejorar, necesitamos que se mejore el codigo, optimizacion de codigo, necesitamos que el codgio de progrmaacion sea modular, paraq ue en caso de tengamos que modificar algo, anadir algo sepamos en donde tener que hacer eso. [...] Trabajen con commit + push + pr + pr view + issues + merge, etc." Full text: go-port-lanes/ORIGINAL-PROMPT.md. Follow-up: "todo lo que se pueda pasar [...] para que nos ayude en el tema de los test, para que sea rapido" (port to Go whatever makes tests slow).
- L2 (2026-11-02) s1 assigned this port to s2 ("it unblocks s4's #2549 going in-process"). s4 consumes only len(Untracked), Degraded != "", OutOfScopeMarker != "", ctx timeout -> unverified, and the error text. API accepted in package internal/retro/reconcile.
- L3 (2026-11-02) Issue #2563 opened. Sizes on origin/main 31bb4be5: script 1,232 lines; suite 3,389 lines (207 cases).
- L4 (2026-11-02) T1 delivered.
  - Package `internal/retro/reconcile`, with 135 differential cases (core 27, input 18, forms 31, markers 16, layout 10, matrix 32). Legacy vs Go: 0 diffs.
  - The goldens are replayed under nodiff.
  - Deviations from S2/S3:
    - `Options.GH` is `gh.Options`, because `core/gh` has no Runner.
    - `KitRoot`, `Cwd` and `Env` were added. `Cwd` and `Env` are required (archtest: `os.Getwd`/`os.Getenv` only in `cli/stdio.go`).
    - `Report` adds `Orphaned`, `Failure` and `Notes`.
    - The grammar lives in `internal/core/retrogrammar`, moved there by #2490.
    - `stageissues` keeps its signature builder and its table-row reader unexported, so the `Source retro:` prefix is built locally. Follow-up: export them from `stageissues`.
  - RDD: commit af7790d7 (frozen oracle) was approved and acknowledged. Every other commit, and the af7790d7..e0aeba26 range (2,098 lines), read medium `under_budget`, so the slice stays pending.
  - Impacted gate on e0aeba26: 186/186 suites, 13,165 cases, 0 failed, kit-tree 0.
- L5 (2026-11-02) T2 delivered on top of 28d2fd61.
  - `Options.ClosedCache` (`ClosedFile`, `ClosedBodies`); `Report` gains `Shipped`, `Borderline` and `Regressed`.
  - 91 new differential cases (closed 61, regressed 30; 226 goldens in all): 0 diffs against the frozen script. The goldens are replayed under nodiff.
  - Known divergences, none reachable by a case: the find error text for an unlistable retros dir is built in C-locale quoting; sibling order is bytewise (the C-locale sort); row ids and titles are compared as strings where awk would compare numeric-looking strnums (01 vs 1).
  - The test fixtures build a deterministic repository (pinned author and dates), so the goldens name its commit ids.

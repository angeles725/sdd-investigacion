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
- T1 S1 S2 S3 S4 — slice 1: freeze the legacy oracle; core classification of one retro against --issues-cache (tracked / untracked / orphaned, legacy signature, delta forms, marker scope); Report/Render; differential plus goldens for those cases. Route: delegated writer (context backstop; parallel with CI watchers). Status: open.
- T2 S1 S4 — slice 2: --closed-cache: shipped / borderline / regressed, the closure-evidence grammar, git reachability (RECONCILE_ISSUES_MAIN_REF / _GIT_DIR), shallow-clone. Route: delegated writer. Status: open.
- T3 S1 S2 S5 S6 S8 — slice 3: --all over TARGETS.md, live gh (LoadCache, per-retro re-verify), the `rsdd retro reconcile` command, shim, deletion of the bash suite with the case map, registry. Route: delegated writer. Status: open.
- T4 S7 — fleet sweep and acceptance. Route: inline. Status: open.

## Log
- L1 (2026-11-01, user, verbatim): "Vamosa a trabajar con ODD + RDD(granted), si GENTLE-AI pide revision, dale permisos para que revise. Ahora vamos a realizar lo siguiente: Primero, necesitamos pasar todo lo que tenemos python a GO, todo lo que se pueda mejorar, necesitamos que se mejore el codigo, optimizacion de codigo, necesitamos que el codgio de progrmaacion sea modular, paraq ue en caso de tengamos que modificar algo, anadir algo sepamos en donde tener que hacer eso. [...] Trabajen con commit + push + pr + pr view + issues + merge, etc." Full text: go-port-lanes/ORIGINAL-PROMPT.md. Follow-up: "todo lo que se pueda pasar [...] para que nos ayude en el tema de los test, para que sea rapido" (port to Go whatever makes tests slow).
- L2 (2026-11-02) s1 assigned this port to s2 ("it unblocks s4's #2549 going in-process"). s4 consumes only len(Untracked), Degraded != "", OutOfScopeMarker != "", ctx timeout -> unverified, and the error text. API accepted in package internal/retro/reconcile.
- L3 (2026-11-02) Issue #2563 opened. Sizes on origin/main 31bb4be5: script 1,232 lines; suite 3,389 lines (207 cases).

# status-show-go — port research-sdd-status.sh to `rsdd status show`
Objective: issue #2549 (epic #2270). Branch per slice (S1: `feat/rsdd-status-show-s1-2549`). Delivery: chained PRs, one per slice.
Runner: `go test` (focused: `go test -p 1 -parallel 2 ./internal/status/...`, with and without `-tags nodiff`).

## Specs
Each spec is the verbatim slice-table row of issue #2549 (columns: slice, script sections at origin/main, est. lines, suites mapped).

- S1: S1 | args and flag validation, `--emit-token`, state-file pick, BOOTSTRAP, helper sourcing (77–288), `is_blocked` | ~900 | `-root-pick`; main: emit-token, BOOTSTRAP |
- S2: S2 | `backlog_rows`, counters (743–934), FOCUSES token (934–1020), deferred scan; promote the gfm readers | ~1,300 | `-deferred-populations`, `-retyped`, `-inplace-blocked`; main: counters, unknown priority |
- S3: S3 | `--sync-state` (1021–1366), `cov_ratio`, `env_*` | ~1,300 | main: envelope and sync-state groups |
- S4: S4 | `--next` core: `resolve_next`, `queue_next`, unreadable stop, STALE gate, exit 3 | ~1,400 | `-next-scope`, `-focus-scope`, `-followups`, `-queue`, `-unreadable-stop`; main: `--next` ordering |
- S5: S5 | RETRO-DUE with covers_through, `issues_due_gate` (1401–1694, 1800–2000) | ~1,300 | main: RETRO-DUE, ISSUES-DUE |
- S6: S6 | default report (2456–2642), contradictions, clean-warn, saturation, visibility | ~1,300 | `-clean-warn`, `-visibility`; main: saturation, Stop hook |
- S7: S7 | §8c campaign queue (2047–2384), document cycle (2385–2455) | ~1,000 | main: campaign, document cycle |
- S8: S8 | `rsdd_exec` shim, differential against the frozen script, suite reduction | ~300 + deletions | all, with the cases that have no Go equivalent kept |

## Tasks
- [x] T1 (S1) route: delegated — commits: 964ab5c0 (frozen head + goldens), b94b0ca7 (args, pick, --emit-token), 686dda46 (is_blocked); RED: replay failed on a stub (rc 99) for all 114 scenarios and is_blocked stub (rc 7) failed the replay
- [x] T2 (S2) route: delegated — commits: 820a9467 (frozen excerpts + s2.golden), 85409c45 (backlog_rows, deferred_scan, counters, FOCUSES token), 2d969e9d (teeth fixes: shared byte-class helper, boundary tests); RED: TestReplayS2 failed on a stub for 182 of 182 scenarios (replay differs); no mode completed by S2 alone
- [x] T3 (S3) route: delegated — commits: 7cdfa816 (frozen excerpts + s3 goldens), 1382ffe8 (--sync-state, blocked_open_count), 989f3027 (teeth fixes); RED: against a stub (syncState rc 99, blockedOpen rc 99) the differential and TestReplayS3/TestReplayBlockedOpen failed for every scenario (rc 99, no envelope written); --sync-state now answers instead of not-yet-ported, every other mode still does
- [ ] T4 (S4) route: inline — commit: pending
- [ ] T5 (S5) route: inline — commit: pending
- [ ] T6 (S6) route: inline — commit: pending
- [ ] T7 (S7) route: inline — commit: pending
- [ ] T8 (S8) route: inline — commit: pending

## Log
- L1 (user, issue #2549 Goal): Port `research-sdd/toolbelt/research-sdd-status.sh` (2,642 lines, the largest bash in the kit) to Go as `rsdd status show`. This is the Phase 3 unit of the Go-port plan (`odd/tasks/go-port.md`, epic #2270). The script becomes an `rsdd_exec` shim.
- L2 (2026-11-02): T1 is delegated to one bounded writer (named reason: the parent launched it as one unit of a chained delivery); the bash script stays authoritative until S8.
- S3 (T3): `--sync-state` ported whole (the mode now completes in Go; `--next` and the default report stay not-yet-ported). Differential vs the frozen script assembled from 9 excerpts and run as the real entry: 171 sync runs plus 109 blocked_open_count cases, outputs, trees (bytes and modes) equal. Findings: (1) the mv keeps mktemp's 0600, so a rewritten state file becomes 0600 (ported, pinned in the goldens); (2) `awk -v repl=` processes escapes, so a preamble line with a backslash is rewritten (ported as awkVEscapes, verified against gawk, including backslash-newline vanishing); (3) core/kit FilterBlockFiles rejects a lone `)` that GNU grep -E takes as a literal (kit F8), worked around locally by escaping it, and a slug with `[`/`*` is a glob in bash `find -name` but a path.Match in kit.ResolveStateFile, not reachable from S3 and left to a core unit; (4) deliberate divergence: a failed temp-file create or rename is a typed exit 1 where bash would print mv's error and still claim "wrote". Hand-mutation: 19 mutants, 2 survived the first run and were fixed (a scenario; a redundant check dropped).
- S2 (T2): readers ported as internal functions (no mode finishes with S2 alone: --sync-state is S3, --next S4, default report S6). Differential vs the frozen excerpts: 190 scenarios, Go and bash outputs equal (stdout, stderr, rc). gfm gap: FOCUSES reader trims-free quirk (READERS.md 7) is reproduced by prefixing/suffixing a pipe before gfm.SplitRow; the Block column reader needs an unstripped split that gfm lacks, kept local in blockColumnValues.

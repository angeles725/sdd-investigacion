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
- [ ] T1 (S1) route: delegated — commit: pending
- [ ] T2 (S2) route: inline — commit: pending
- [ ] T3 (S3) route: inline — commit: pending
- [ ] T4 (S4) route: inline — commit: pending
- [ ] T5 (S5) route: inline — commit: pending
- [ ] T6 (S6) route: inline — commit: pending
- [ ] T7 (S7) route: inline — commit: pending
- [ ] T8 (S8) route: inline — commit: pending

## Log
- L1 (user, issue #2549 Goal): Port `research-sdd/toolbelt/research-sdd-status.sh` (2,642 lines, the largest bash in the kit) to Go as `rsdd status show`. This is the Phase 3 unit of the Go-port plan (`odd/tasks/go-port.md`, epic #2270). The script becomes an `rsdd_exec` shim.
- L2 (2026-11-02): T1 is delegated to one bounded writer (named reason: the parent launched it as one unit of a chained delivery); the bash script stays authoritative until S8.

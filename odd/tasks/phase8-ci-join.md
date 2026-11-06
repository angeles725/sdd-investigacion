# Phase 8 slice 8 — the Go CI join that keeps `toolbelt-tests` and `shellcheck`

Objective: Go tests become part of the required check `toolbelt-tests` and the required names survive the deletion of
the bash corpus. Issues: #2753 (umbrella), #2754 (slice 8.0). Owner: session 1. Branches: one per slice, off `origin/main`. Delivery: chained small PRs
(`ask-on-risk` resolved as `stacked-to-main`). Runner: `go test` per package under `research-sdd/rsdd`; workflow
changes are proven by Go guards in `internal/testkit/ciworkflow` and by the PR's own CI run.

## Specs

S1 (source: `odd/tasks/phase8-cutover.md`, slice table row 8, verbatim): "Go CI sharding beside the bash corpus | — |
a Go join that keeps the name `toolbelt-tests`; `shellcheck` kept | 1 | workflow fixture + merge gate updated in the
same commit | 5 | yes".

S2 (source: the same document, section 6a, verbatim): "The Go CI join that keeps the names `toolbelt-tests` and
`shellcheck`, with the workflow fixture guarded by a Go test in the same commit (slice 8 and trap 1) — session 1,
with the release workflow."

S3 — slice 8.0, the merge gate (ruling of 2026-11-06, sessions 1 and 10). Today `internal/gate/mergeci.go` counts the
conclusions `skipped` and `neutral` as green for every check, and `ciAbsent` only asks whether a required name was
seen, so a required check that GitHub reports as skipped yields `ok` (pinned by `mergeci_test.go` "skipped and neutral
count as green" and by `mergediff_test.go` against the legacy jq). Required:
- a name in the REQUIRED list must conclude `success`;
- `skipped` and `neutral` stay acceptable only for checks outside that list (`toolbelt-extras` is skipped on every PR);
- a required check that concluded `skipped` or `neutral` gets its own verdict `ci_skipped (name[,name])`, not
  `ci_failed`; precedence: `ci_failed`, `ci_pending`, `ci_skipped`, `ci_missing`;
- it is a declared divergence from `merge-gate.sh` (listed in the merge gate's `tool-registry.d` entry, and its typed
  state in the reason-code registry); the differential test keeps parity for every other case and names this one.
Acceptance: unit cases for a required skipped check, a required neutral check, a non-required skipped check (still
`ok`), and both together with a failed check (precedence); the existing passing case that used
`toolbelt-tests:completed:skipped` moves to the refused side.

S4 — slice 8.1, guards with no CI change. A reader `Jobs(src string) ([]Job, State)` in
`internal/testkit/ciworkflow` (`Job{ID, Name, Needs, If, Matrix, Body}`; `Unrecognised` for no block-form `jobs:`, a
flow-form job or zero jobs) and three guards over the real workflow files:
- `TestWorkflowJobsKeepTheirShape`: the job `toolbelt-tests` has no `name:`, an `if:` containing `always()`, `needs`
  naming every shard job, and a body that reads `needs.<id>.result` for each need; every shard job is a matrix job
  with no `${{` in its name and an upload step with `if: always()` and `if-no-files-found: error`; `shellcheck`
  exists, has no job-level `if:`.
- `TestPinnedWorkflowCopies`: `.github/workflows/toolbelt-tests.yml` equals
  `research-sdd/toolbelt/tests/fixtures/merge-gate/wf-real-toolbelt-tests.yml` and `pr-check.yml` equals
  `wf-real-pr-check.yml`; each reported `same`, `drifted` or `absent` (three controls: equal, one byte changed,
  file missing).
- in `internal/gate`: `TestDefaultRequiredChecksAreRealJobs`: each default required name is the check name of a
  non-matrix job with no job-level `if:` in a workflow that has a `pull_request` event.
Every finding has a table case built from a mutated copy of the source (the guard must bite).

S5 — slice 8.2a, `internal/maint/cishard` (pure, stdin to stdout, never runs `go test`):
- `rsdd maint ci-shard plan --shard I/N [--durations FILE]`: reads the package list on stdin, prints this shard's
  packages. Longest-first to the least-loaded shard (ties: path, lowest shard), the rule of `run-all.sh --shard`; a
  package without a weight weighs 6 s and is named on stderr; an absent or empty durations file is a typed
  `DEGRADED` note and the position-mod-N assignment; an invalid line is a typed `INVALID`, exit 1; the plans of the
  N shards are a disjoint and complete cover for every N from 1 to 32; an empty package list is exit 1, never an
  empty plan presented as a pass.
- `rsdd maint ci-shard manifest --shard I/N --exit RC --planned FILE`: reads `go test -json` on stdin and writes
  `# shard I/N suites=K exit=RC` then `<import path> PASS|FAIL|SKIP` per planned package (the format
  `shard-join.sh` reads). A planned package with no final package-level event is `FAIL`; an empty stream forces
  `exit=1`; a package in the stream that was not planned is a finding. The package-level action of a build failure
  and of a crashed test binary is pinned by a recorded fixture, not assumed.
- `Makefile`: `PKGS ?= ./...` used by `test`, default unchanged.

S6 — slice 8.2b, the wiring (the minimum that unblocks deletion PRs). In `.github/workflows/toolbelt-tests.yml`: a
matrix job `toolbelt-go-shard` (no `name:` line; `GO_SHARD_COUNT: "2"` asserted against `strategy.job-total`) that
builds `rsdd` once, lists the packages that have tests, plans its share, runs
`make test PKGS="$plan" TESTFLAGS="-json -count=1"`, writes the manifest and uploads it as `go-shard-manifest-I`
(`if: always()`, `if-no-files-found: error`; the prefix is NOT `shard-manifest-`, which the bash join's download
pattern would match). The join job `toolbelt-tests` gets `needs: [toolbelt-shard, toolbelt-go-shard]`, computes the
expected package list ITSELF from its own checkout (never from the shards; an empty list is a failure), runs the bash
join unchanged, then `shard-join.sh --expected go-expected.txt --shards "$GO_SHARD_COUNT" --strict-skip` over the Go
manifests, and its last step fails unless both `needs.*.result` are `success`. Same commit: the fixture copy
`wf-real-toolbelt-tests.yml`, the guard tables of S4, a seed `research-sdd/rsdd/ci/go-test-durations.txt`, and the
shard row of `CLAUDE.md`. `rsdd-go-test`, `rsdd-go-bridge` and `rsdd-go` stay separate checks, unchanged.

S7 — slice 8.3, `shellcheck`: the lint step builds an explicit list from `research-sdd/toolbelt`,
`research-sdd/install` and `research-sdd/templates` (`*.sh`, excluding `*/testdata/*`), prints `shellcheck: N files`,
fails when N is 0, and runs `xargs -r`. Warnings in `templates/*.sh` are fixed in the same PR. Guard cases for the
step text; fixture copy in the same commit.

S8 — slice 8.4, `rsdd maint ci-join`: a Go port of `shard-join.sh` (typed `JOIN:` findings and exit codes equal,
proved against a frozen copy under `testdata/legacy`), wired for both corpora. Deleting `shard-join.sh` is slice 12.

S9 — slice 8.5, filter completeness: every top-level entry under `research-sdd/` is covered by the `push` and
`pull_request` path filters of `toolbelt-tests.yml` through explicit entries (not `research-sdd/**`: teeth C of
`ci-path-filter-coverage.test.sh` deletes one entry and expects a gap), with a guard that is red on today's tree.

Out of scope here: removing `make test` from `rsdd-go-test` (slice 10), the doctrine test package (slice 9), the
`${{ }}` job name of `rsdd-go.yml` (a separate small CI issue), the release workflow (its own document).

Assumptions (marked, to be verified by the slice that depends on them): `go test -json` reports a build failure and
a crashed binary as a package-level `fail` (8.2a pins it); `shellcheck -S warning` on `templates/*.sh` is not yet
known to be clean (8.3 measures it first).

## Tasks

- [ ] T0 · S3 · merge gate: a required check must conclude success · route: inline or one writer · commit: —
- [ ] T1 · S4 · `ciworkflow.Jobs` + three guards · route: delegated (one Sonnet writer) · commit: —
- [ ] T2 · S5 · `internal/maint/cishard` plan + manifest, `PKGS` in the Makefile · route: delegated · commit: —
- [ ] T3 · S6 · wire the Go shards into the `toolbelt-tests` join · route: inline (workflow + fixture + tables) · commit: —
- [ ] T4 · S7 · `shellcheck` scope and floor · route: inline · commit: —
- [ ] T5 · S8 · `rsdd maint ci-join` · route: delegated · commit: —
- [ ] T6 · S9 · filter completeness guard · route: inline · commit: —

Risk per task: T0 item 2 and 5 (the gate that decides a merge); T1 none (tests only); T2 item 6 until its own tests
exist (a silent zero in the manifest writer); T3, T4, T6 item 5 (CI); T5 item 5.

## Log

L1 (2026-11-06, user, verbatim, the standing instruction this unit answers): "Y tambien siempre ataca a lo que nos
este bloqueando, para que todo siempre continue con la velocidad continua". Scope: S1 and S2 above, quoted from the
phase 8 rulings.

L2 (2026-11-06, design, Opus read-only study of origin/main 0a8c107a): verified facts used above — the join job is
`toolbelt-tests.yml` `toolbelt-tests` with `needs: toolbelt-shard` and `if: always()`, its last step fails on
`needs.toolbelt-shard.result != success`; shard jobs carry no `name:` on purpose; `shard-join.sh` accepts
`--expected FILE` and any list of names; no Go shard or join code exists; the default required list is
`shellcheck,toolbelt-tests` (`internal/gate/merge.go`), nothing is enforced server-side (branch protection 404,
rulesets empty); the Go merge-gate tests read the bash fixture directory and nothing pins `wf-real-pr-check.yml`;
`rsdd-go-test` took 8m22s and the slowest bash shard 8m27s on the last green main run (measured 2026-11-06 at
0a8c107a).

L3 (2026-11-06, decisions): the join reuses `shard-join.sh` until 8.4 (shipping a new join first would put unproven
code on the critical path); shard weights come from a durations file (as `run-all.sh`); two Go shards; the `rsdd-go*`
checks stay separate because a job cannot `need` a job of another workflow; the whole module's tests run twice per
PR until slice 10 (accepted, about 7 runner-minutes). Session 10 reads this document for three ways a join passes
without having looked: an empty shard set, an expected list derived from the run it judges, a renamed job.

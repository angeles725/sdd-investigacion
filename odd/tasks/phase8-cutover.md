# Phase 8 — retirement and cutover: slice plan

Plan of record for phase 8 of `odd/tasks/go-port.md` (epic #2270). Written by session 10 on 2026-11-06 from a
read-only study of origin/main 512db127 (nothing run, nothing written) plus spot checks, marked [checked]; the
rulings session 1 made the same day are in section 6a. Paths are repository-relative. Anything not verified in the
tree is INFERRED. Counts are measurements at that commit, not assertions: re-measure before using one as an
acceptance number.

## 0. The finding that changes the plan

The shims are load-bearing for the Go module itself, not only for outside callers. Deleting them is not the last
step of phase 8; removing the module's own dependence on them is the first.
- `internal/core/kit/kitresolve.go:39` refuses to resolve when `kit/<rel>` is not a regular file [checked]; 20 call
  sites of `ResolveKitScript`; `sweep/all.go:78` finds the kit through `sweep-all.sh`.
- `internal/sweep/allscripts.go:8-17` runs eight toolbelt shims by name [checked], and `tests/sweep-all.test.sh`
  parses that Go file for its parity check.
- More direct script runs: `status/show/stale.go:32` (needs `RSDD_TOOLBELT_DIR`), `retrogateseed.go:151`,
  `archive.go:113`, `archive_gates.go:113`, `skilldrift.go:239`, `resume/render.go:142`, `ensureremote.go:322`.
- 47 Go test files name live scripts; 24 load live `toolbelt/lib` code; 86 legacy copies sit in testdata.

## 1. Consumers of a script path or name

| Consumer | Evidence | Count |
|---|---|---|
| `.claude/settings.json` | :9, 22, 28, 34, 40, 46, 52, 58, 64 | 9 hooks: 7 shims, 1 still bash (`verify-tool-catalog-hook.sh`), the pkill template |
| pi extension `install/pi/research-sdd-hooks.ts` | :43-46 `SWEEP_HOOKS`, :197, :433, :444, :472 | 8 sweep hooks + 2 gates + pkill guard, all through `bash` |
| templates | `hook-kit-run.sh:70` (`exec bash "$kit/$rel"`), `hook-stop-retro-gate.sh:16`, `hook-prepush-vendor-leak.sh:24`, `vendor-leak-ci.template.yml:32` | 4 |
| CI | `toolbelt-tests.yml:169,223,271,287,293,304`; `rsdd-go.yml:138,166`; `flake-hunt.yml:122,137`; `pr-check.yml:33,49,184` | 4 workflows |
| installers | `install.sh:470-516`; `adapters.sh:210,329-348`; `research-sdd-init.sh:151,157,215-222,351` | 8 + 10 + 21 |
| other scripts | `research-sdd-status.sh` 16, `profile-target.sh` 7, `state-update.sh` 1, `decompile-native.sh` 1 | 25 |
| doctrine | METHODOLOGY 272, PROMPT-LOOP 83, README 64, CLAUDE.md 30, APPENDIX 28, skills 22, PROMPT-REFRESH 1 | 500 |
| registries | `toolbelt/*.md` 591 (`tool-registry.md` 276), `tool-registry.d` 133, `reason-codes.d` 26 | 750 |
| bash tests | 151 suites | 1,821 hits |

go-port.md's "about 440 mentions" is low by a factor of about three once the registries are counted. `BOOTSTRAP.md`
does not exist. The search recognises literal basenames only. It cannot see names built at run time, globs, names
written without the extension, target corpora, harness homes, other repositories, or GitHub branch protection.

## 2. Installed corpora (the kit never edits them)

An initialised target references the kit four ways: portable wiring (a tracked `tools/hooks/kit-run.sh`, copied
create-only at `research-sdd-init.sh:351` and never refreshed, which runs `toolbelt/return-token-gate.sh`,
`toolbelt/verify-skill-drift-hook.sh`, `toolbelt/retro-gate.sh`, `templates/hook-pretool-pkill-guard.sh`); absolute
wiring (`$KIT/toolbelt/...` at `init.sh:151,157` and `.claude/hooks/retro-gate-stop.sh`); the pre-push hook
(`$KIT/templates/hook-prepush-vendor-leak.sh`, then `scan-vendor-leak.sh`); CI in public corpora at a pinned kit ref.

Recommendation: a frozen compatibility set. Six stubs of about three lines forward to the dispatcher of section 3.
Each is a declared exception with a sunset condition: zero references in a read-only sweep of every `TARGETS.md` row
(35 path rows by my grep on 512db127; the study said 47 — recount before using it as an acceptance number), both
wiring forms. Add a migration note and a read-only `rsdd corpus migrate-wiring` that prints the change and applies
nothing. Rejected: deleting outright (an old `kit-run.sh` prints DEGRADED and exits 1, so the Stop gate stops
enforcing); keeping every shim (nothing is retired).

## 3. Missing or stale binary after "call rsdd directly"

- Direct `rsdd` in the hook command: a missing binary is exit 127, which the harness treats as non-blocking
  (INFERRED), so the gates would silently allow. It also loses the stale-binary rebuild (`rsdd-exec.sh:175-269`).
  This is the upstream weakness recorded in UPSTREAM-LESSONS.md ("Keep ours"). Reject.
- An inline guard in each hook: nine copies of JSON written in shell, and still no rebuild. Reject.
- Recommended: ONE dispatcher. Promote `templates/hook-kit-run.sh` and move the `rsdd-exec.sh` logic into it:
  binary order `RSDD_BIN`, `<kit>/bin/rsdd`, PATH; source-hash freshness; the event derived from the name; the typed
  degraded output per event kept exactly; old paths mapped to commands through one table (`rsdd compat argv`).
  Both harness families call it; pi keeps its degraded notices and its pkill `block:true`.

Ruled 2026-11-06: approved as declared exceptions (go-port.md section 8), under the conditions in section 6a.

## 4. CI check names that must survive

Today: `toolbelt-shard (1-4)`, `toolbelt-tests`, `toolbelt-extras` (nightly), `shellcheck`; `rsdd-go`,
`rsdd-go-bridge (n/3)`, `rsdd-go-test`; PR Validation (gate scripts, issue reference, status:approved, type label,
RED evidence); `flake-hunt` (nightly). Merge tooling requires `shellcheck,toolbelt-tests`
(`internal/gate/merge.go:116`) [checked]. Branch protection is not visible from the tree.

| Bash gate | After the cutover | Go equivalent today |
|---|---|---|
| `run-all.sh` + `shard-join.sh` | `go test` sharded per package + a join proving every package ran once | join: none |
| tiers | build tags or a package list | none |
| `--impacted` | package dependency closure + test cache | partial (s2's #2613 covers Go to suites, not this) |
| `--prove-teeth` | gremlins via `make teeth` + `teeth-debt.txt` | the decider is still bash (`rsdd-go.test.sh`, 1,727 lines) |
| flake hunt | `go test -count -shuffle` under load | none |
| writer check | — | none |
| RED-evidence check | — | none; the parser accepts only `*.test.sh|mjs|cjs|py` (`parse-red-evidence.cjs:93`) [checked] |
| release asset + sha256 (go-port.md 4.8) | — | no workflow exists |

## 5. The bash test corpus (188 `.test.sh`)

- (a) 57 suites (about 20.2k lines) test a script that is already a shim. 28 have a legacy copy used by a Go
  differential; for the other 29 Go coverage is by name only (case-level coverage INFERRED: check before deleting).
- (b) about 20 suites test bash infrastructure and die with it (`run-all*`, `shard-join`, `suite-impact*`, `mutant*`,
  the six bash-only lints, `stage-libs`, `test-lane`, `rsdd-exec`).
- (c) no Go test yet: 49 suites whose script is still bash, and about 60 behaviour and doctrine suites
  (`reason-codes` 1,321 lines, `skill-invariants` 992, `process-integrity` 779, `ci-path-filter-coverage` 702,
  `enforcement-e2e` 612, `pi-hooks` 314, `harness-sweep-parity` 310, twelve `research-sdd-status-*`).
- 190 suites source `lib/mutant.sh`: it goes last.

## 6. Slices ("early" = can start before the remaining ports land)

| # | Goal | Deletes | Adds | Needs | Acceptance | Risk | Early |
|---|---|---|---|---|---|---|---|
| 1 | Tag the last pre-cutover ref; build the consumer enumerator | — | `rsdd maint consumers` (declares what it cannot see) + committed baseline | — | baseline equals section 1 | 6 | yes |
| 2 | The Go module stops needing the shims | shim runs in Go, `RSDD_TOOLBELT_DIR` | in-process calls or runs of its own binary; kit found by a marker file; differentials use legacy copies | 1 | enumerator: no Go reference to `toolbelt/*.sh` | 3 | partly |
| 3 | Single dispatcher | logic of `rsdd-exec.sh` (468 lines) | dispatcher + `rsdd compat argv` | 1 | binary missing, stale, fine: each typed, per event, both harnesses | 2 | yes |
| 4 | Re-wire the kit's `settings.json` and the pi extension | — | dispatcher calls | 3, catalog-hook port | `harness-sweep-parity` + pi-hooks green | 5 | yes |
| 5 | Corpus compatibility set + migration note | — | 6 stubs, note, read-only migrator | 3 | read-only sweep of every registry row, both wiring forms | 1 | yes |
| 6 | Installer and init write only `rsdd` wiring; release asset | the `.sh` lines `adapters.sh` writes | release workflow + sha256 | phase 5 | a fresh init references no `.sh` | 2 | no |
| 7 | Doctrine rewrite, one PR per document | `.sh` mentions | `rsdd` forms + docs-to-code contract test | names stable | every quoted command is emitted by the code | 3 | partly |
| 8 | Go CI sharding beside the bash corpus | — | a Go join that keeps the name `toolbelt-tests`; `shellcheck` kept | 1 | workflow fixture + merge gate updated in the same commit | 5 | yes |
| 9 | Port the class (c) behaviour and doctrine suites | about 60 suites | Go `doctrine` test package | 8 | each case has a Go test | 6 | yes |
| 10 | Teeth decider, writer check, flake hunt, RED and linked-issue parsers, size-check deletion rule | `rsdd-go.test.sh`, the two `.cjs` | Go equivalents | 8 | check names unchanged | 5 | yes |
| 11 | Delete shims and class (a) suites, one domain batch at a time | 64 shims, 13 libs, about 20k test lines | — | 2, 4, 5, 10 | enumerator 0 for the batch | 5 | no |
| 12 | Delete `run-all`, `mutant.sh`, lints, waivers, tiers; amend section 8; re-run every enumerator | about 10k lines | — | all | real-corpus sweep in both harnesses | 6 | no |

Additions from the upstream study (session 1's list): the docs-to-code contract test rides slice 7 (every schema id and
command the docs quote must be emitted by the code; our `*.vN` envelopes and tool-registry); a dead-code ratchet
and a per-package "owns / do not put here" table in a module README ride slice 12; both reuse the shape of the
file-size ratchet (#2738).

Order that keeps both harness families working at every merge: 1, then 3 and 8 in parallel, then 2, 4, 5, 9, 10,
then 6 and 7, then 11 by domain, then 12.

## 6a. Owners and rulings (session 1, 2026-11-06)

- Dispatcher and stubs: approved as the only bash that survives the cutover besides the install bootstrap
  (go-port.md 4.8). Conditions: (a) the dispatcher only locates the binary (`RSDD_BIN`, `<kit>/bin/rsdd`, PATH),
  checks freshness and rebuilds, prints the typed degraded output per event, and execs; the old-path to command
  table lives in Go (`rsdd compat argv`), never in bash; about 250 lines at most. (b) Its tests are Go tests that
  run it in a scratch HOME (binary missing, stale, fine; per event; both harness families). (c) Each stub is at most
  three lines and byte-pinned by a Go test, with the sunset condition of section 2, the row count re-measured and
  dated. (d) Before slice 3 freezes its design, the INFERRED of section 3 is replaced by evidence per harness: the
  Claude Code hook contract (cited in the slice), and the pi and gentle-shell sources, read rather than assumed.
- Blockers first, because they gate every deletion PR: the RED-evidence parser accepts a Go test
  (`<package dir under research-sdd/rsdd> <TestName>`, the package must exist) and the size check stops counting
  pure deletions — session 2. The Go CI join that keeps the names `toolbelt-tests` and `shellcheck`, with the
  workflow fixture guarded by a Go test in the same commit (slice 8 and trap 1) — session 1, with the release
  workflow.
- Slice 1 (consumer enumerator and committed baseline, built as a ratchet: a new Go reference to a toolbelt script
  fails) — session 10. Slice 3 (dispatcher) — session 1. Slice 9 owners are assigned when slice 8 lands.
- Slice 2 is a lane rule from 2026-11-06: no new Go code may run or resolve a `toolbelt/*.sh` or `templates/*.sh`
  path, and every port PR that touches a file listed in section 0 converts that call to an in-process call or a run
  of its own binary in the same PR. By lane: retro and sweep — session 2; verify — session 3; status, state,
  archive and resume — session 4; `core/kit` and the rest — session 1.

## 7. Traps (each would break silently)

1. `merge-gate.test.sh:82-90` keeps `wf-real-toolbelt-tests.yml` byte-equal to the workflow; no Go test does.
   Deleting that suite drops the guard.
2. The shard job must have no `name:` line (`toolbelt-tests.yml:201-203`) or the merge gate reports `ci_missing`.
3. `merge.go:116` requires `shellcheck`; with no `.sh` left the `xargs shellcheck` step likely fails (INFERRED).
4. The `toolbelt-tests` path filters (:8-50) omit root `CLAUDE.md`, `README.md`, `PROMPT-REFRESH.md`: a rewrite of
   those runs neither gate.
5. `kit-size-check` counts deletions toward the 400-line budget: a pure-deletion PR is refused until slice 10 adds a
   rule. It also excludes fixtures by the path `toolbelt/tests/fixtures/**`, so moved fixtures start counting.
6. Goldens pin `.sh` text (`sizecheck/testdata/golden/scenarios.json:39`, `reasons/table_gen.go:117-169`).
7. Old `kit-run.sh` copies in corpora are create-only and never refreshed.
8. `sweep-all.test.sh` reads `allscripts.go` for its parity check.
9. Without the dispatcher's rebuild, a `git pull` leaves a stale binary running old logic with no signal.
10. The RED-evidence parser rejects a Go test file name: after the bash suites go, no PR can satisfy the check
    unless slice 10 lands first.

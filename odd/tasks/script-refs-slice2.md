# Retire run-or-resolve script references from Go code (phase 8 slice 2)

Objective: issue #2770. Two helpers in `internal/core`, each delivered with a real caller; the call sites then go
to the lane that owns each caller. Branches: `refactor/rsdd-kit-root-2770` for the first pull request, a new one cut
from main for the second. Delivery: two pull requests of this session, sequential to main (both touch
`internal/sweep/all.go`). Test runner: `go test` on the touched packages in `research-sdd/rsdd` (both tag sets),
pre-push checks, one impacted gate per pull request.

## Specs

Quoted text is the approved issue #2770 or the ruling of session 1 in L1, verbatim.

- S1 Kit root. "In `internal/core/kit`, one function that returns the kit root with the resolution order
  `ResolveKitScript` has today (`RESEARCH_SDD_KIT`, the launcher files, the default checkout; the first candidate
  that holds a `toolbelt/` directory) and the same typed warnings. `ResolveKitScript` is rebuilt on it, so the
  module keeps one resolution."
- S2 Anchor sites. "The 14 anchor sites call it." Twelve are edited by the first pull request: `internal/sweep/`
  `all.go:78`, `audits.go:77`, `breakthroughs.go:64`, `retros.go:150`, `tools.go:57`; `internal/retro/`
  `reconcile/command.go:120`, `stage/command.go:41`, `stageissues/run.go:177`; `internal/verify/registry.go:163`
  and `skilldrift.go:104`; `internal/budget/session.go:148`; `internal/corroborate/fidelity/fidelity.go:284`. "A
  file under a live claim is not edited by PR (a): its owner makes the one-line edit and the line stays in the
  consumers baseline until then": `internal/corpus/archive.go:113` (corpus lane) and
  `internal/gate/retrogate.go:136` (gate lane).
- S3 Intended difference. "a kit whose legacy script is missing no longer fails at the anchor", "pinned by a test
  and listed in the registry rows of the commands it touches". Every other output of the twelve commands is
  unchanged: stdout, stderr and exit code on every input where the legacy script exists.
- S4 Self-subcommand helper. "One helper in core, built on `core/proc`." "The binary comes through a seam read
  from the parent `Stdio`'s environment (`RSDD_BIN`), falling back to `os.Executable` only inside the helper, never
  in a domain. When the fallback resolves to a Go test binary (a name ending in `.test`), the result is a typed
  failure and nothing runs, so a test that forgot the seam cannot run itself again."
- S5 The child. "The child gets the parent's `Environ` (never nil, so nothing inherits the process environment),
  its working directory from `Stdio.Cwd`, stdin from `/dev/null`, a process-group kill and an output cap."
- S6 The bound. "The bound is a required argument. "No bound" is a named constant, and a call site that uses it
  carries a comment with the reason."
- S7 The result. "The result is stdout, stderr or the merged stream, the exit code, and typed states for
  could-not-start, timed-out and output-cut that are distinct from the callee's own exit codes (the 126 and 127
  that `status show` reads today stay distinguishable)."
- S8 Tests of the helper. "Tests inject a stub executable through the seam. No package test needs `go build`."
- S9 First consumer. "Its first consumer is `sweep all`: the loop keeps `RSDD_SWEEP_TIMEOUT`, the group kill and
  the 4 MiB cap, and its eight rows become `<binary> <group> <name> <arguments>` in place of `bash <script>`." The
  arguments each shim adds today are passed by the caller: `--kit <kit>` for `sweep retros`, `sweep audits`,
  `sweep breakthroughs`, `sweep tools` and `verify skill-drift`; `--kit <kit, resolved physically>` for `verify
  registry`; the toolbelt directory as the only argument of `verify kit-clean`. "The eighth row of `sweep all`,
  `verify-tool-catalog.sh` (`allscripts.go:15`), still holds logic; it joins the loop when its port (#2749) is on
  main."
- S10 Acceptance. "each pull request deletes its lines from the consumers baseline of #2758 (the baseline only
  shrinks); every difference from the bash is intended, pinned by a test and listed in `tool-registry.d`; the three
  defects in the problem description are gone at every converted site." Until the baseline of #2758 exists, the
  pull request lists the literals it removes.
- S11 Shape (owner rule, enforced by the file-size check). Every production file at 200 lines or less, data apart
  from logic; no domain imports another; no second resolution of the kit and no second process runner.
- S12 Not this unit: the call sites of the other lanes (the table of #2770), "moving the `verify state` engine to
  core", "a rule in the architecture test for ambient process state".

- S13 States of the kit-root function (condition of session 1 on the first pull request, L3). "the new helper
  must keep the three states apart (no kit found / kit found but no toolbelt directory / RESEARCH_SDD_KIT set and
  invalid, with the same warning line ResolveKitScript prints today), with a case for each." Decision of this
  session, not a quote: no candidate exists as a directory: the text `ResolveKitScript` prints today,
  `research-sdd kit not found (set RESEARCH_SDD_KIT)`; at least one candidate exists as a directory and none holds
  `toolbelt/`: a distinct typed error whose text names the first such directory; `RESEARCH_SDD_KIT` set and without
  `toolbelt/`: today's warning line, then the other candidates. `ResolveKitScript` itself keeps its output byte for
  byte (it is the port of `templates/hook-kit-run.sh` and its differential test pins it).
- S14 Bash suites (condition of session 1, L3). "the changed "…sh is missing" text is an output change of twelve
  commands, so run each command's bash suite that asserts that line (not only the Go tests) and list the suites in
  the body".
- S15 Same root text. Every anchor site keeps today's path text: `filepath.Dir(filepath.Dir("<kit>/toolbelt/x"))`
  is `filepath.Clean("<kit>")`, so a kit given with a trailing slash, as a relative path or with a `.` segment
  prints the same directory before and after (assumption of this session, to be pinned by a test per form).

## Tasks

- [ ] T1 (S1, S2, S3, S11) the kit-root function in `internal/core/kit`, `ResolveKitScript` rebuilt on it, the
  twelve anchor sites, their tests and registry rows (also S13-S15) · route: delegated (the kit contract sends a write of two or
  more non-trivial files to one writer) · pull request (a)
- [ ] T2 (S4-S9, S11) the self-subcommand helper in core with `sweep all` as its first consumer · route: delegated ·
  pull request (b) · needs T1 merged (both edit `internal/sweep/all.go`)
- [ ] T3 (S10) acceptance of both against the consumers baseline or, before it exists, the list of removed literals

Forecast: about 250 changed lines for T1, about 500 for T2.

## Log

- L1 Original request: the ruling of session 1 (orchestrator), 2026-11-06, after the measurement of the ten
  cross-domain sites. Verbatim: "do NOT build the in-process dispatch (form 3) [...] That grows the system for one
  site. Ruling: 1. `sweep all` = process form, as you propose: one loop, eight rows `<binary> <group> <name>
  <args>` under RSDD_SWEEP_TIMEOUT with group kill and the 4 MiB cap; the four same-domain sweep rows go with it.
  [...] So ONE helper, in core, on core/proc: "run my own subcommand". Contract: the binary comes through a seam
  read from the parent Stdio's Env (RSDD_BIN), falling back to os.Executable only in the helper, never in a domain;
  when the fallback resolves to a Go test binary (name ends in `.test`) it is a typed failure, never a run, so a
  test that forgot the seam cannot re-run itself; the child gets the parent's Environ (non-nil, so nothing inherits
  the process environment), an explicit Cwd from Stdio.Cwd [...], stdin from /dev/null, group kill and an output
  cap; the bound is a required argument, and "no bound" is a named constant whose call site carries a reason
  comment; the result is stdout, stderr or the merged stream, the exit code, and typed states for could-not-start,
  timed-out and output-cut, distinct from the callee's own exit codes (126/127 that status reads today must stay
  distinguishable). Tests inject a stub executable through the seam; nothing in a package test needs `go build`.
  Drop the archtest extension from this PR [...] Issue: open ONE new issue for slice 2 [...] Two PRs of yours under
  it: (a) kit-root helper + the A edits outside live claims; (b) the self-subcommand helper with `sweep all` as its
  first consumer, so the helper lands with a real caller and its teeth." Earlier the same day, on the anchor
  sites: "A (14): yours, one PR, one helper in internal/core/kit that returns the kit root without naming a script.
  Before you start, read CLAIMS: a file under a live claim is not edited by you; its owner makes the one-line edit
  in their own next PR and you leave that line in the baseline as legacy. Announce the final file set to all."
- L2 Evidence the specs rest on, main at 7d2a51d9: the measurement of #2758 (`odd/tasks/maint-consumers.md`, L6 to
  L8) and the site-by-site reading of the ten cross-domain runs (bounds, streams, environment, what each shim
  adds). CLAIMS read at 14:25Z: no live claim covers the twelve files of T1 or `internal/sweep/all*.go`;
  `internal/corpus/**` is locked by #2592. File sets announced to sessions 1, 2 and 3.
- L3 Conditions of session 1 on the first pull request, 2026-11-06, verbatim: "Two conditions on PR (a): the
  changed "…sh is missing" text is an output change of twelve commands, so run each command's bash suite that
  asserts that line (not only the Go tests) and list the suites in the body; and the new helper must keep the three
  states apart (no kit found / kit found but no toolbelt directory / RESEARCH_SDD_KIT set and invalid, with the
  same warning line ResolveKitScript prints today), with a case for each. internal/gate/retrogate.go:136 and the
  two gate call sites (retrogate.go:269, retrogateseed.go:151) are mine: the anchor goes in my next PR on that file
  after (a) merges, the two runs after (b)." Sessions 2 and 3 confirmed they hold no work on the twelve files.
- L4 Reading of the twelve sites at main 1302652b: ten keep the kit root (`filepath.Dir(filepath.Dir(p))`);
  `internal/budget/session.go:148` anchors on `toolbelt/lib/session-budget-pi.mjs` and
  `internal/corroborate/fidelity/fidelity.go:284` on `toolbelt/decompile-java.sh`, and both keep the toolbelt
  directory. Three of the files have an exact count in `modularity-debt.txt` (`internal/sweep/retros.go` 634,
  `internal/verify/registry.go` 674, `internal/verify/skilldrift.go` 539): a changed line count lowers their line
  in the same commit. Route of T1: delegated to one writer, by the kit contract (two or more non-trivial files).
- L5 Conditions of session 1 on the resolver's warnings, 2026-11-06, verbatim: "#2770 PR (a), the resolver's
  warnings: approved, and it stays in this PR: a set-but-invalid RESEARCH_SDD_KIT that falls through to another kit
  silently is exactly the family we remove. Conditions: the warning goes to stderr only, never into stdout and
  never into a hook's JSON; the exit code of each command is unchanged by it; every bash suite of those commands
  that asserts an empty stderr or a byte-exact stderr is in the list you run; and say in the body what `sweep all`
  prints when the variable is invalid (it runs eight children: one warning per child is acceptable if you state
  it, a silent zero is not). Pin one case per site as you planned."
- L6 Review of the first delivery of T1 (commits 318d2bf0 and 2df2f853, rebased on main 4494fb02), 2026-11-06. The
  edit surface was respected. The writer's reading corrects L4: seven sites keep the kit root and five keep the
  toolbelt directory (reconcile, stage, stage-issues, budget session, java-fidelity). Four corrections, sent as
  one batch: (1) the harness of the site tests is copied in seven packages, about 120 lines each: it becomes one
  shared package, `internal/testkit/kitsite`; (2) three listed files grew (`internal/sweep/retros.go` 634 to 640,
  over 400, where the list forbids growth; `internal/budget/session.go` 391 to 395;
  `internal/corroborate/fidelity/fidelity.go` 306 to 308): the kit lookup moves to a small file in each package,
  so the three counts go down; (3) `corroborate java-fidelity` still dropped the warning: it resolves once per run
  and prints the line once; (4) the hook mode of the four sweeps skipped the warning: it goes to the process's
  stderr, outside the context the hook hands the model. Not in this pull request, sent to session 1 to rank:
  `verify registry-hook` already merged the warning into its context before this change.
- L7 Correction batch for L6, 2026-11-06 15:02Z, commits `11b08c14` and `930805ca` (head of T1). Checked by session 10:
  no production file imports `internal/testkit/kitsite` (grep over `internal` and `cmd`, zero non-test importers outside
  the package); against `origin/main` no line of `modularity-debt.txt` rises (`retros.go` 634 to 615, `session.go` 391
  to 379, `fidelity.go` 306 to 294, `audits.go` 275 to 263, `tools.go` 221 to 209, `breakthroughs.go` leaves the list);
  the tests of `testkit/kitsite`, `core/kit`, `corroborate/fidelity`, `retro/stage` and `testkit/archtest` pass.
  - The harness `internal/testkit/kitsite` (compare.go 32, kit.go 49, run.go 48, scenarios.go 92 lines) replaces the
    seven copied `kitroot_site_test.go` harnesses; test and subtest names are unchanged.
  - The kit lookups moved to `sweep/kitdir.go` (33), `budget/kitdir.go` (23) and `corroborate/fidelity/toolbelt.go` (29).
  - `java-fidelity` resolves the kit once per run (`sync.OnceValues`) and prints the invalid-kit warning once.
  - In hook mode the four sweeps print the warning on the process's stderr; stdout stays the same JSON, byte for byte,
    as with a valid variable (writer's differential against the base binary).
  - Writer's runs: thirteen bash suites, 0 failed; `go test` on the eight package sets in both tag sets; vet,
    staticcheck and both cross builds clean. Two notes from them: setting `GOTMPDIR` breaks
    `TestRegistryQuietUnderALongTMPDIR` in `internal/verify` (use `TMPDIR` for scratch), and
    `TestDifferentialPiDegradedWithoutSandbox` in `internal/budget` failed twice under load (the frozen script exits
    141) and passed alone; it was not run on the base, so it is not established as a flake of the base.
  - NOT done, in this order, before the pull request of T1 exists: (1) one sentence in the registry note, required by
    session 1: `verify registry-hook` is the one SessionStart hook that hands the invalid-kit warning to the model
    (declared intended; the hook budget is 7,983 of 8,000 characters), and the four sweep hooks keep it on the process's
    stderr; session 3 pins it inside #2773; (2) mutation at CI scope on the changed packages; (3) pre-push; (4) the
    review assessment after a rebase on the current main; (5) the pull request, `Refs #2770`, with the three states, the
    table of warnings, the `sweep all` observation (the parent prints the warning once, the children print no copy), the
    intended differences and the RED lines.
  - The branch is on the remote as `park/s10-kit-root-2770`. T2 (the self-subcommand helper on `core/proc`, call sites
    carrying group and name as literal arguments, no in-process dispatch) starts after T1 merges. After T2, one issue of
    session 10 with `status:approved`: an archtest rule for fixtures that commit without `gitfixture.Env` (the four
    packages `internal/core/kitgate`, `internal/hygiene`, `internal/maint/sizecheck`, `internal/maint/writercheck` as a
    list that only shrinks), plus the read-only count of the bash suites exposed to the same race.

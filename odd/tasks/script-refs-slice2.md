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
- S6 The bound. "The bound is a required argument. \"No bound\" is a named constant, and a call site that uses it
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

## Tasks

- [ ] T1 (S1, S2, S3, S11) the kit-root function in `internal/core/kit`, `ResolveKitScript` rebuilt on it, the
  twelve anchor sites, their tests and registry rows · route: delegated (the kit contract sends a write of two or
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
  [...] So ONE helper, in core, on core/proc: \"run my own subcommand\". Contract: the binary comes through a seam
  read from the parent Stdio's Env (RSDD_BIN), falling back to os.Executable only in the helper, never in a domain;
  when the fallback resolves to a Go test binary (name ends in `.test`) it is a typed failure, never a run, so a
  test that forgot the seam cannot re-run itself; the child gets the parent's Environ (non-nil, so nothing inherits
  the process environment), an explicit Cwd from Stdio.Cwd [...], stdin from /dev/null, group kill and an output
  cap; the bound is a required argument, and \"no bound\" is a named constant whose call site carries a reason
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

# rsdd maint consumers: enumerate every reference to a kit script, with a baseline that only shrinks

Objective: phase 8 slice 1 (issue #2758). Branches: one per pull request, each cut from main after the previous one
merges (`feat/rsdd-maint-consumers-2758` is the first). Delivery: chained pull requests of about 400 changed lines
(auto-chain, sequential to main). Test runner: `go test ./...` in `research-sdd/rsdd` (both tag sets), pre-push checks.

## Specs

Quoted text is the approved issue #2758 ("Proposed Solution"), verbatim. Text after "Decision" or "Assumption" is
this unit's, with its evidence in the log.

- S1 Command. "`rsdd maint consumers` enumerates every reference to a kit script and declares what it cannot see".
  A read-only command: it writes nothing under the repository.
- S2 Scripts. "Scripts are the live list of non-test files under `research-sdd/toolbelt/`, `research-sdd/templates/`
  and `research-sdd/install/` that the plan counts as scripts. The list is read from the tree on each run, never
  hard-coded."
- S3 Classes. "Consumers are reported by class: Go production code, Go tests, bash scripts, harness wiring
  (`.claude/settings.json`, the pi extension), templates, CI workflows, doctrine and registries, bash tests."
- S4 Go references. "Go references are read from the syntax tree, not from a text search. Each string literal that
  names a script is classified by its enclosing call: `run or resolve` (an argument of `exec.Command*`,
  `ResolveKitScript`, `filepath.Join`, a concatenation that builds a path) or `text` (usage and message strings)."
  Decision (L2, measured): the class is decided by the literal, and the enclosing expression is reported beside it.
  A literal is `run or resolve` when it is one token that is the script's basename or a path ending in it (no white
  space); it is `text` when the name sits inside a sentence. A closed list of calls would miss 22 of the 57 token
  literals of production code on main today (helper calls, constants, tables, one comparison). A generated file
  (`// Code generated ... DO NOT EDIT.`) is its own class, reported and not gated: its source is a registry, and
  the report names the generator's input (the emitters of the reason-code registry), where the cutover edits it.
  Addition (L4, ruling of session 1): a class `assembled` for names built at run time, which no literal names:
  every production literal that is `.sh` or ends in `.sh` and whose last segment is not a live script (format
  strings included), reported with its enclosing expression and gated by the same exact baseline. Literals ending
  in another script extension are counted and reported as `assembled-other`, not gated (L4 says why).
- S5 Limits. "The output states its limits on every run: names that arrive through a flag or an environment
  variable, names built at run time, globs, names without the extension, and everything outside the repository."
- S6 States. "Absent, empty and no-match are distinct: a kit that cannot be found, a tree with no script, and a class
  with no reference each have their own typed state; an unreadable file is an error, never a zero."
- S7 Ratchet. "A Go test fails when the tree has a `run or resolve` reference the baseline does not list. The message
  names the file and the script, and says to convert the call (in-process, or a run of the module's own binary)."
- S8 Only shrinks. "A baseline line whose reference is gone must be deleted, so the list only shrinks. An update mode
  rewrites it without ever adding a line."
  Decision (from the file-size ratchet, #2738 L15): a baseline count is exact. One line per Go file and script with
  the number of `run or resolve` literals; more is the failure of S7, fewer fails with the lowered line, zero with
  the line to delete. With slack a removed reference could come back unseen. A file that moves keeps its lines under
  the new path; the message for a missing file says so. The file is sorted by path, so lanes converting call sites
  delete disjoint lines. A `run or resolve` line has the kind `legacy` and is never added. An `assembled` line has
  the kind `accepted` and a reason, since a literal such as an extension list is legitimate and stays; a new one
  needs its reason and a reviewer.
- S9 Not gated. "`text` references and the non-Go classes are reported and counted, not gated."
- S10 Acceptance. "the baseline is compared with section 1 of the plan, re-measured and dated, and every difference
  is classified by hand as a reference the plan missed, a reference the plan over-counted, or a defect in the
  enumerator."
- S11 Delivery. "Delivered as chained pull requests of about 400 changed lines: the shared syntax-tree walker
  (`internal/core/gosrc`, moved from the #2613 scanner so the module has one walker), then the Go classes with the
  baseline and its test, then the non-Go classes and the registry row."
- S12 Out of scope (issue, "Additional Context"): "the tag of the last pre-cutover ref (slice 1 names it; it can only
  be chosen when the last port lands), and the check that stops a diff from adding lines to an only-shrink list (a
  separate unit)." Until that check exists, "cross-readers check the baseline diff by eye."
- S15 Proof of coverage (L4). Every run prints: Go files parsed, scripts enumerated, production literals inspected,
  and the count per class, zero included, so an empty tree or a renamed directory cannot read as "0 references". A
  Go file that cannot be parsed is an operational failure (exit 1 in this module), never a skipped file.
- S16 Names outside Go source (L4). Covered: files the module embeds (`//go:embed`), in the Go pull request, as
  the class `embedded`, reported and not gated; text lists under the module root and under `research-sdd/toolbelt/`
  (`*.txt`), in the non-Go pull request, as the class `lists`. Excluded by name, and printed as excluded on every
  run: `testdata/` (frozen legacy copies), `tests/fixtures/`, git history, target corpora, harness homes, other
  repositories and branch protection.
- S13 Shape (owner rule, enforced by the file-size check of #2738). Every production file at 200 lines or less, data
  apart from logic. The walker and the literal visitor live in `internal/core/gosrc`; the command in
  `internal/maint/consumers`; no domain package imports another. `internal/maint/goimpact` uses the same walker.
- S14 Documentation. The command has its help text, its row in `research-sdd/toolbelt/tool-registry.d/`, and its
  typed states in the reason-code registry when it emits any.

## Tasks

- [ ] T1 (S4, S11, S13) `internal/core/gosrc`: the walker of module files (the union over build tags and platform
  suffixes, skipping `testdata`, `vendor` and names the go tool ignores) moved from `internal/maint/goimpact` with
  its pin, plus a literal visitor that yields value, position and the enclosing expression chain; goimpact imports
  it · route: inline · BLOCKED on the first pull request of #2613 (session 2) merging
- [ ] T2 (S1, S2, S4-S9, S13) `internal/maint/consumers`: live script list with its typed states, the Go classes,
  the report with its limits, the baseline file, the test that enforces it and the update mode · route: inline ·
  needs T1
- [ ] T3 (S3, S9, S14) the non-Go classes (bash scripts, harness wiring, templates, CI workflows, doctrine and
  registries, bash tests), the registry row and the documentation · route: inline · needs T2
- [ ] T4 (S10) acceptance: the baseline against section 1 of `odd/tasks/phase8-cutover.md`, re-measured and dated,
  every difference classified by hand · route: inline · needs T3

Forecast: about 250 changed lines for T1, 500 for T2 (plus a baseline of about 50 lines of data), 400 for T3: three
pull requests, one per task; T4 is recorded in this document and in the last pull request.

## Log

- L1 Original request, verbatim. `odd/tasks/phase8-cutover.md` section 6, slice 1: "Tag the last pre-cutover ref;
  build the consumer enumerator | — | `rsdd maint consumers` (declares what it cannot see) + committed baseline | — |
  baseline equals section 1 | 6 | yes". Section 6a (session 1, 2026-11-06): "Slice 1 (consumer enumerator and
  committed baseline, built as a ratchet: a new Go reference to a toolbelt script fails) — session 10." The approved
  issue #2758 is the contract the specs quote. Order given by session 1: the file-size ratchet (#2738), then this
  unit, then the only-shrink check.
- L2 Measurement before any code, 2026-11-06, main at b4a1c9fb, with a throwaway program outside the repository
  (go/parser over every Go file of the module, `testdata` and `vendor` skipped; a literal counts when it contains the
  basename of a live script as a whole name). Live scripts: 129 files under the three directories, 129 distinct
  basenames, none in two places. Go files parsed: 1,373, none failed. Production code: 361 literals in 85 files; 188
  are text (usage and messages), 173 are tokens. Of the tokens, 116 are in the generated
  `internal/core/reasons/table_gen.go` (the emitter names of the reason-code registry). The other 57, in 33 files and 50
  pairs of file and script, are the references slice 2 has to remove, in these forms: an argument of `ResolveKitScript` (15); a concatenation
  with a directory (12); an argument of `filepath.Join` (8); a constant (9); a table of names (8,
  `sweep/allscripts.go`); an argument of a helper of the package (`toolbeltFile`, `archiveGate`: 3); one comparison
  and one slice literal. A rule keyed on a closed list of calls (`exec.Command*`, `ResolveKitScript`,
  `filepath.Join`, a concatenation) sees 35 of the 57 and misses the constants, the table, the helper calls and the
  comparison, which are the forms a new reference would most easily take. Hence the decision in S4: the token decides
  the class, the enclosing expression is printed. Tests: 552 literals in 156 files, reported and not gated (S9). These
  figures are a dated reading, not an assertion; the acceptance of T4 re-measures.
- L3 Dependency. The walker arrives in T1 as a move of the parse step of `internal/maint/goimpact` (branch of #2613,
  session 2, not on main yet), agreed with session 2 on 2026-11-06: one walker in the module, no second copy
  meanwhile. T1 starts when that pull request merges.
- L4 Ruling of session 1 on L2, 2026-11-06, verbatim where quoted: "no objection to either decision"; "Add a class
  `assembled`: any production literal that is exactly `.sh` or ends in `.sh` without being a known basename (format
  strings included), reported with its enclosing expression and gated with the same exact baseline"; "Names that
  are not in Go source at all: files the binary reads or embeds [...] Say in the spec which of those the non-Go PR
  covers and which are excluded by name, and print the excluded set in the report"; "Also print per run: files
  parsed, files that failed to parse (a parse failure is exit 2, not a skipped file), scripts enumerated, and the
  count per class"; "keep the file sorted"; "name its generator's input in the report". The exit code is 1 here:
  in this module 2 is the usage error and 1 the operational failure (`internal/cli/cli.go`).
  Measured for it, same day and commit: 23,828 production string literals inspected; 50 end in a script extension
  without naming a live script, none in a generated file: `.py` 18, `.java` 11, `.sh` 10, `.js` 4, `.mjs` 4, `.ts`
  3. The ten `.sh` literals, in seven files, and none builds the path of a kit script: three extension lists
  (`maint/sizecheck/classify.go`, `sweep/toolsfs.go`, `verify/statehooks.go`), four uses of `.test.sh` that pair a
  suite with its script (`maint/sizecheck/split.go`), Ghidra's own `support/launch.sh` twice, and the shim name of
  the test kit (`testkit/kitworld`). All ten are legitimate and stay, hence the kind `accepted` in S8. The other 40
  are not gated: 29 are artifacts of a target (`.java` a decompiler writes, `.py` a parser generator writes), the
  rest are names in a target corpus or a sandbox; gating them would fill an only-shrink list with lines that never
  leave. The cost is stated in the report: of the 129 live scripts, 119 are `.sh`; a run-time assembly of one of
  the other ten (`.java` 4, `.mjs` 3, `.js`, `.py`, `.ts` 1 each) is seen only when a token names it.
  Outside Go source: 6 `//go:embed` directives in production files, 6 files, all `help.txt`, 21 script names
  (text). No text list under the module root names a script. Under the toolbelt two do: `requirements.txt` (8) and
  `tests/writer-check-waivers.txt` (1).


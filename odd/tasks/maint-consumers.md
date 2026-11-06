# rsdd maint consumers: enumerate every reference to a kit script, with a baseline that only shrinks

Objective: phase 8 slice 1 (issue #2758). Branches: one per pull request, each cut from main after the previous one
merges (`feat/rsdd-maint-consumers-2758` is the first). Delivery: chained pull requests of about 400 changed lines
(auto-chain, sequential to main), in the order of L8: the command with the script list and the non-Go classes first.
Test runner: `go test ./...` in `research-sdd/rsdd` (both tag sets), pre-push checks.

## Specs

Quoted text is the approved issue #2758 ("Proposed Solution"), verbatim. Text after "Decision" or "Assumption" is
this unit's, with its evidence in the log.

- S1 Command. "`rsdd maint consumers` enumerates every reference to a kit script and declares what it cannot see".
  A read-only command: it writes nothing under the repository.
- S2 Scripts. "Scripts are the live list of non-test files under `research-sdd/toolbelt/`, `research-sdd/templates/`
  and `research-sdd/install/` that the plan counts as scripts. The list is read from the tree on each run, never
  hard-coded."
  Decision (L6, accepted by session 1): a script is a file with one of the extensions `.sh`, `.py`, `.mjs`, `.cjs`,
  `.js`, `.ts`, `.java`. Only three things are excluded: a name that contains `.test.`, a directory named
  `fixtures`, and `node_modules`. A file under `toolbelt/tests/` that is not a test is a script (`run-all.sh`,
  `suite-impact.sh`, `shard-join.sh`, `tests/lib/*.sh`): Go code can run it. The exclusions are part of the
  coverage claim, so the report prints each one with the number of files it removed.
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
  in another script extension are counted and reported as `assembled-other`, not gated (L4 says why). The report
  itself states that cost on every run: how many live scripts are not `.sh`, and that a run-time assembly of one of
  them is seen only when a token names it (L5).
  Correction (L7, ruling of session 1): a token literal that initializes an unexported package-level constant or
  variable is classified by the uses of that name in the production files of its package, resolved by identifier
  name, without type information. It is `text` only when the name has at least one use and every use is text in
  one of exactly two forms: an operand of a concatenation that has a literal with white space, or an argument of
  an `fmt` or `errors` formatting call whose format literal has white space. Any other use, an exported name, or
  no use at all leaves it `run or resolve`; a name with no use is reported as unused. A local that shadows the
  name adds its uses to the constant's, which can only move it toward `run or resolve`, never toward `text`. The
  report prints, for each such name, its class and the one use that decided it (file and line), so a failure tells
  the writer what to change.
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
- S15 Proof of coverage (L4, L6). Every run prints: Go files parsed, scripts enumerated, the files each exclusion
  of S2 removed, production literals inspected,
  and the count per class, zero included, so an empty tree or a renamed directory cannot read as "0 references". A
  Go file that cannot be parsed is an operational failure (exit 1 in this module), never a skipped file.
- S16 Names outside Go source (L4). Covered: files the module embeds (`//go:embed`), in the Go pull request, as
  the class `embedded`, reported and not gated; text lists under the module root and under `research-sdd/toolbelt/`
  (`*.txt`), in the non-Go pull request, as the class `lists`. Excluded by name, and printed as excluded on every
  run: `testdata/` (frozen legacy copies), `tests/fixtures/`, git history, target corpora, harness homes, other
  repositories and branch protection.
- S17 First pull request (L8): the command without the Go classes. Everything here is this unit's decision; the
  figures of L8 are a dated reading, never an assertion.
  - Usage: `rsdd maint consumers [--repo DIR] [--refs] [--script NAME]`. `--repo` defaults to the work tree that
    holds the working directory.
  - One source of files: `git ls-files -z --cached --others --exclude-standard` in the repository (tracked files,
    plus untracked files that are not ignored, so an uncommitted file counts). Without git, or outside a work tree,
    the run is degraded (exit 3) and prints no count.
  - The kit is `research-sdd/` in that repository. No file under `toolbelt/`, `templates/` or `install/`:
    `absent-input`, exit 1. Files there and no script: `empty-input`, exit 1. A class with no reference prints
    `no-match` on its row and the run exits 0.
  - A reference is an occurrence of a live script's basename as a whole name: not preceded by a letter, a digit,
    `_`, `.` or `-`; not followed by a letter, a digit, `_` or `-`, nor by `.` and a letter or digit. A script that
    names itself is not its own consumer: it is counted apart, as `self`.
  - Classes, first match wins, kept as data in a file of their own: (1) `research-sdd/rsdd/`: the Go module, not
    enumerated by this pull request, which the report says in words and never as a zero; (2) a path segment
    `fixtures`: excluded; (3) `.github/`: CI workflows; (4) `.claude/` and `research-sdd/install/pi/`: harness
    wiring; (5) `research-sdd/templates/`: templates; (6) a name that contains `.test.`: bash tests; (7) a live
    script: scripts; (8) `*.md`: doctrine and registries; (9) `*.txt` under `research-sdd/toolbelt/`: lists; (10)
    anything else: unclassified, and every unclassified file with a reference is printed by path.
  - A file with a NUL byte in its first 8,192 bytes is binary: not read, and counted. A file that cannot be read is
    an error (exit 1) that names it.
  - The default report: the repository and the kit; the script count by extension; each exclusion of S2 with its
    count; one row per class with its files, files with a reference, pairs of file and script, references and
    self-only files; the unclassified paths; the files not read (fixtures, the Go module, binary); the limits of
    S5; the line about the Go classes. `--refs` prints instead one line per pair, `class`, `file`, `script` and
    `count` separated by tabs, sorted by class, file and script. `--script NAME` restricts either output to one
    basename; a name that is not a live script is allowed, because after a deletion the question is who still
    names it, and the header then says the name is not live.
- S13 Shape (owner rule, enforced by the file-size check of #2738). Every production file at 200 lines or less, data
  apart from logic. The walker and the literal visitor live in `internal/core/gosrc`; the command in
  `internal/maint/consumers`; no domain package imports another. `internal/maint/goimpact` uses the same walker.
- S14 Documentation. The command has its help text, its row in `research-sdd/toolbelt/tool-registry.d/`, and its
  typed states in the reason-code registry when it emits any.

## Tasks

- [ ] T1 (S1, S2, S3, S5, S6, S9, S13, S14, S15, S17) `internal/maint/consumers`: the command, the file list, the
  live script list with its exclusions and typed states, the non-Go classes, the report with its limits and its
  proof of coverage, the registry row and the help text · route: delegated (the kit contract sends a write of two
  or more non-trivial files to one writer) · needs nothing
- [ ] T2 (S4, S11, S13) `internal/core/gosrc`: the walker of module files (the union over build tags and platform
  suffixes, skipping `testdata`, `vendor` and names the go tool ignores) moved from `internal/maint/goimpact` with
  its pin, plus a literal visitor that yields value, position and the enclosing expression chain; goimpact imports
  it · route: inline · BLOCKED on pull request #2768 (session 2, first of #2613) merging. The import check of
  `internal/testkit/archtest` (`archtest.Check`) takes its files from the same walker: today it parses every path
  ending in `.go`, so a dangling editor-lock symlink is a read error there (advisory 4 of the cross-read of #2738,
  left as a follow-up in that pull request). Assumption: the test-kit tier may import `internal/core`; if the
  boundary check forbids it, that fix becomes its own change.
- [ ] T3 (S4, S7, S8, S13, S15, S16) the Go classes in `internal/maint/consumers`: production code, tests, the
  generated table, `assembled`, `embedded`, the use rule of L7, the baseline file with its two kinds, the test that
  enforces it and the update mode · route: decided when T2 lands · needs T2. Cases of the use rule, from frozen
  copies of the ten real declarations: the five message prefixes read as `text`; the default program name of
  `install/detect_tools.go` stays gated; the status script of `eval/scoreloop/status.go`, the Ghidra exporter and
  the kaitai driver stay references; plus an exported name, a name passed to a helper, a shadowing local and a
  name with no use. Baseline kinds (L8): `legacy` for a reference that must leave; `accepted` with the reason
  "file loaded by <tool>" for the nine literals that name a file another runtime loads (pi, node, Ghidra), and for
  the `assembled` lines.
- [ ] T4 (S10) acceptance: the baseline against section 1 of `odd/tasks/phase8-cutover.md`, re-measured and dated,
  every difference classified by hand · route: inline · needs T3

Forecast: about 900 changed lines for T1 (some 550 of production code in files of 120 lines or less, the rest
tests and documentation), in two commits and, if the first alone passes 500 lines, two pull requests; 250 for T2;
600 for T3 with the use rule (plus a baseline of about 60 lines of data: the pairs and the `assembled` literals at
the reading of L6); T4 is recorded in this document and in the last pull request.

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
- L5 Session 1, same day, on L4: "accepted as measured, including the three places where you departed from my
  wording"; on the ungated extensions: "Keep that sentence in the tool's output, not only in the spec." S4 says so.
  "No further spec questions from me; go on with the feature document, and send the first PR number when T1
  unblocks."
- L6 Correction of the script list, 2026-11-06, found by the cross-read of pull request #2764: its
  `ResolveKitScript("toolbelt/tests/suite-impact.sh")` was a reference the measurement of L2 could not see, because
  that measurement dropped the whole `tests/` directory. Session 1: "the corrected definition is right (only
  `*.test.*` and tests/fixtures are excluded [...]) [...] the exclusion list is part of the instrument's coverage
  claim, so print it and the count it removed." Re-measured the same day, main at 7d2a51d9: 396 files with a script
  extension under the three directories; 190 removed by `.test.` in the name, 63 by a `fixtures` directory, none by
  `node_modules`; 143 live (toolbelt 120, toolbelt/tests 14, templates 5, install 4; `.sh` 133, `.java` 4, `.mjs`
  3, `.js`, `.py` and `.ts` 1 each). Go files parsed: 1,456, none failed; 24,391 production literals inspected.
  Token literals of production code outside the generated table: 58 in 34 files and 51 pairs (L2: 57, 33, 50). The
  one more is `clean-check.sh` in `internal/hygiene/cleancheck/args.go`, from a port merged meanwhile; the 14
  scripts under `tests/` add none on main (production code names them only in text, four literals, all
  `run-all.sh`), and one in an open pull request (#2764). By directory: budget 6, corpus 6, corroborate 7, eval 2,
  gate 7, hygiene 1, install 1, retro 3, secretscan 1, status 5, sweep 13, verify 6. Generated table: 116. Text:
  193 in 73 files. Tests: 569 in 162 files. Assembled: 54 (`.py` 19, `.java` 12, `.sh` 11, `.js` 5, `.mjs` 4,
  `.ts` 3); the new `.sh` one is an extension list in `internal/core/cleancheck/scratch.go`. The 58 name 36
  scripts; 24 of them are already shims that run the Go binary.
- L7 Correction of the decision of S4, same day, found while sizing L6. Ten of the 58 token literals initialize a
  constant. Every use was read: five are only a message prefix (`eval/scoreloop/config.go:12`,
  `hygiene/cleancheck/args.go:10`, `secretscan/args.go:12`, `status/resume/render.go:18` and `state.go:17`; their
  comment says "the legacy script's name is part of its output contract"), one is a default program name
  (`install/detect_tools.go:30`), and none of the six runs or resolves a file. "The literal decides" called all six
  `run or resolve`, so every port that keeps the legacy name in its messages, the convention of every lane, would
  fail the test with advice to convert a call that does not exist. Ruling of session 1: "the use rule. A marker
  comment is a declaration the tool cannot check, which is the shape we remove everywhere else; the use rule is
  derived from the code and fails on the safe side." Its conditions: "resolve uses by identifier name over the
  package's production files without type information, and say so: a shadowing local with the same name adds its
  uses to the constant's, which can only move it toward `run or resolve`, never toward `text`; pin that with a
  case"; "The closed list of text forms is exactly your two [...] A constant with zero uses is NOT text: report it
  as unused and gate it"; "The report prints, per such name, the class and the one use that decided it
  (file:line)"; "Table cases from frozen copies of the ten real declarations [...] plus an exported name and a
  name passed to a helper." Also from session 1: "The new numbers are accepted (58 literals, 34 files, 51 pairs,
  143 live scripts)".
- L8 Use of each of the 58 literals, and the order of delivery, 2026-11-06. Read site by site (a read-only explorer,
  no site undecided; the ten constants by hand), main at 7d2a51d9: A, anchor only, 14 (`ResolveKitScript` of the
  port's own script, kept only for its directory): sweep 5, retro 3, verify 2, and one each in budget, corpus,
  corroborate and gate. B, a run or an existence check of one of the 24 shims, 18: sweep 7, corpus 4, status 3,
  gate 2, corroborate 1, verify 1; six of the runs stay inside one domain and ten cross a domain. C, a file that
  still holds logic, 11: gate 4, verify 3, and one each in corpus, corroborate, eval and sweep. D, a file another
  runtime loads (`research-sdd-hooks.ts`, `session-budget-pi.mjs`, `CuratedEvidenceExporter.java`), 9: budget 5,
  corroborate 4. E, a program-name constant, 6. Rulings of session 1: "D (9): accepted as you propose: `accepted`
  lines with the reason \"file loaded by <tool>\" (pi, node, Ghidra). They are data the binary ships to another
  runtime, not legacy."; "C (11): not slice 2, each leaves with its port"; "Order of your three PRs (non-Go
  classes and the script list first, walker and Go classes with the baseline after #2768): agreed, nothing waits."
  The conversions of A and B are slice 2, outside this feature: the kit-root helper and the in-process dispatch
  are assigned to this session, the call sites to the lane that owns each caller.
  Reading for the first pull request, same commit, a throwaway script over the 5,556 tracked files (whole-name
  match of the 143 basenames): scripts 137 files, 123 with a reference to another script, 300 pairs, 787
  references, 11 that name only themselves; bash tests 190, 190, 878, 4,903; doctrine and registries 274, 210,
  1,147, 2,876; CI workflows 14, 7, 20, 42; templates 20, 16, 36, 64; harness wiring 2, 2, 14, 22; lists 8, 7, 14,
  61; unclassified 11 files, 5 with a reference (two install goldens, `openspec/config.yaml`, `.gitignore`,
  `research-sdd/.research-tools.txt`). Not read by this pull request: 558 files under a `fixtures` directory and
  the 4,342 files of the Go module.

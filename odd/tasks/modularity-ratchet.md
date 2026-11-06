# Feature: file-size ratchet for the Go module (modular code rule)

Objective: make the owner's "all code is modular" rule mechanical at file level in `research-sdd/rsdd`. Issue #2738.
Branch `feat/rsdd-modularity-ratchet-2738` (rebased on origin/main b55f8e4c). Delivery: single PR, work-unit commits.
Test runner: `go test ./internal/testkit/archtest/` from `research-sdd/rsdd` (focused); CI runs it inside `make test`.

## Specs

- S1 Scope. Every `.go` file under the module root (`research-sdd/rsdd`) is a production file, except: a name ending
  `_test.go`; a path with a `testdata` directory component (relative to the scanned root); a path with a component
  the go tool ignores, a directory or file name starting with `.` or `_` (L12; the root itself is always scanned,
  whatever its name); a generated file. A file is
  generated only when a line matching `^// Code generated .* DO NOT EDIT\.$` appears before its `package` clause.
  Paths are root-relative with forward slashes (`internal/verify/state.go`).
- S2 Line count. The number of `\n` bytes, plus one when the file is non-empty and does not end with `\n`.
- S3 Limits. Soft limit 200, hard limit 400, defined once. Owner: "about 200 lines or less". Orchestrator ruling
  2026-11-06: "200 reviewed target, 400 hard ceiling".
- S4 Debt file `research-sdd/rsdd/modularity-debt.txt`. Blank lines and lines starting with `#` are ignored. Every
  other line is `<path> <lines> <kind> <reason>`: whitespace-separated, `<lines>` a positive integer, `<kind>` one of
  `legacy` (recorded when the ratchet was created) or `accepted` (a later, reasoned exception), `<reason>` the rest of
  the line, at least 10 characters; the placeholder `<reason>` is refused by name. Entries are in strictly increasing
  byte order of `<path>`: a path listed twice is a duplicate and its second line is dropped; any other line out of
  order is reported and still read, so one misplaced line yields one message (L12).
  The header states the rule in three lines, so a writer who meets a failure needs no other document.
- S5 Violations. Each message carries the exact line to add, change or delete:
  a. unlisted, 200 < n <= 400: `<path>: <n> lines, over 200 and not listed. Split it, or add this line to modularity-debt.txt:` then `<path> <n> accepted <reason>`
  b. unlisted, n > 400: `<path>: <n> lines, over 400. A new file over 400 lines cannot be listed: split it. If it is a listed file that moved, change the path on its line instead (same count and kind): that is not a new entry.`
  c. listed, n > recorded, n <= 400: `<path>: grew from <recorded> to <n> lines. Split it, or change its line in modularity-debt.txt to:` then `<path> <n> <kind> <reason>`
  d. listed, n > recorded, n > 400: `<path>: grew from <recorded> to <n> lines and is over 400. A file over 400 lines may not grow: split it first.`
  e. listed, n <= 200: `<path>: <n> lines, no longer over 200. Delete this line from modularity-debt.txt:` then the line
  f. listed, not a production file of the tree (missing, a test, generated): `<path>: listed but not a production Go file in this tree. Delete this line from modularity-debt.txt, or, if the file moved, change the path on it (same count and kind, list kept sorted):` then the line
  g. `accepted` with recorded > 400 and n >= recorded: `modularity-debt.txt:<lineno>: an accepted entry may not be above 400 lines (<path> <recorded>): split the file.`
  h. malformed, unknown kind, short reason, unsorted or duplicate: `modularity-debt.txt:<lineno>: <what is wrong>; expected "<path> <lines> <legacy|accepted> <reason of at least 10 characters>", entries sorted by path`
  i. listed, recorded > 400, 200 < n < recorded: `<path>: <n> lines, below its recorded <recorded>. A count over 400 is exact, so the file cannot grow back unseen: change its line in modularity-debt.txt to:` then `<path> <n> <kind> <reason>`
  One message per entry, in this order: f, e, i, g, then c or d, so a line to delete or to lower is said before
  "split". A file whose line is malformed (h) is not also reported as unlisted (a, b): its line is its message (L15).
- S6 Ceiling semantics (rewritten in L15). A count of 400 or less is a ceiling: a listed file with 200 < n <= recorded
  passes, so a small edit never forces a debt-file edit, and the result counts how many such entries could be
  lowered. A count over 400 is exact: the file passes only at n = recorded, and below it the lowered line is required
  in the same change (message i), so a file that shrank cannot grow back to its old count unseen. The real-tree test
  prints its summary line, with `lowerable`, to the test output and not to the test log.
- S7 Operational errors (an error, never a pass): the debt file is absent or unreadable; the root holds zero production
  Go files; a source file or a directory cannot be read (the error names the path). An existing debt file with no entries is valid when no file is over 200.
- S8 Proof of looking. The result reports files scanned, generated files exempted, files over 200, entries read and
  entries that could be lowered; the real-tree test logs them.
- S9 Update mode. With `RSDD_MODULARITY_UPDATE=1` the real-tree test rewrites the debt file before checking: it lowers
  a recorded count to the current count when the file shrank and is still over 200, and deletes the line of a file
  that is at 200 or less or is not a production file. It never raises a count and never adds an entry. Comments, blank
  lines and order are kept. The write is atomic (temp file in the same directory, same mode, rename) and is skipped
  when nothing changes; a failed write is an error and is not reported as a rewrite. Without the variable the test
  never writes. It deletes the line of a file that is gone, so when a file moved the path is changed by hand
  first (L15).
- S10 Initial list. Every production file over 200 lines on this branch is recorded as `legacy` with the reason
  `recorded when the ratchet was created (#2738)`.
- S11 Self-compliance. Every Go file this change adds is at 200 lines or less; standard library only; package
  `archtest`; limits and message formats separate from the scanning logic.
- S12 Known limit, stated in the debt-file header: a tree-only test cannot stop a change that adds a
  `legacy` entry, or raises one above 400, in the same diff (L10). That is a review rule: `legacy` lines are never
  added after this change; a file that moves keeps its line under the new path, which is not an added line (L15). The
  mechanical closure is a comparison with the merge base, accepted by the orchestrator as its own unit (`rsdd maint
  only-shrink`, after phase 8 slice 1); it has to read a moved path as the same entry.

## Tasks

- [x] T1 (S1-S9, S11) engine + parser + update mode + temp-tree tests · route: delegated (sonnet writer; parent s10 is
  read-only by role and holds no other file), then parent review and three pins inline · commits: 351f114a (engine),
  82659fa9 (comparisons as `if` statements, boundary tests), the commit that adds `filesize_limits.go` · observed:
  package tests under default and `nodiff` tags, vet, staticcheck, both cross builds (L7), mutation run (L9),
  independent verifier (L11)
- [x] T2 (S10, S12) debt list + real-tree test + header · route: same writer · commits: ecfe48c3 (list, real-tree
  test), 185721df (known-limit wording) · observed: real-tree test, update mode byte-identical on a clean tree,
  scratch-copy probe (L8), independent count of the list (L11)
- [x] T3 (S1, S4, S9) correction after the review (L12) · route: inline · commit: 604a16a1 · observed:
  six tests red before the change, package tests under both tag sets, 18 hand mutants killed, dry run 106 runnable
  and 0 not covered, pre-push checks
- [x] T4 (S4) a duplicate after a misplaced line is named (L13, L14) · route: inline · commits: 85e917af and the one after it ·
  observed: one test red before the change, package tests under both tag sets, 21 hand mutants killed, dry run 104
  runnable and 0 not covered, pre-push checks
- [x] T5 (S5, S6, S7, S12) the two blockers of the orchestrator's cross-read and its advisories (L15) · route: inline ·
  commit: the one after e6a59aac · observed: five tests red before the change, package tests under both tag sets,
  33 hand mutants killed, dry run 111 runnable and 0 not covered, real tree unchanged, pre-push checks

## Log

- L1 (user, 2026-11-06, verbatim): "Recuerda que el codgio de progmracion debe ser modular, eso si lo tenias en cuenta,
  verdad? y tambien las demas sesioens lo tienen en cuenta?"
- L2 (user, 2026-11-06, verbatim): "Si esta bien que sea 200 lienas o 500 lineas?" Answer given and ruled by s1: 200
  reviewed target, 400 hard ceiling (10 files are over 500 today; 500 alone would admit new 499-line files unseen).
- L3 Measurement, origin/main 4f257f40, excluding tests, testdata, `*_gen.go` and `*_tables.go`: 611 files, 84,953
  lines; 151 over 200, 67 over 300, 30 over 400, 10 over 500, 7 over 600. On 512db127 by `wc -l` with only tests and
  testdata excluded: 154 over 200, 32 over 400 (that count still includes the generated files S1 exempts).
- L4 s1 rulings 2026-11-06: ceiling semantics; a listed file may grow only with its entry edited in the same diff;
  above 400 no growth; every failure prints the exact line; the header states the rule in three lines; s10 announces
  the merge time to ALL so in-flight branches add their own entries first. Paydown rides the lanes, internal/verify
  first (s3's core/statecheck move).
- L5 Upstream reference (gentle-ai main c28b709, read-only study): no file-size limit there (115 of 788 production
  files over 400 lines); their dead-code ratchet has the same shape we use (frozen baseline, `LC_ALL=C`, update flag).
- L6 Risk: item 5 (a new failing check in the module test gate; a false positive blocks every lane). Verifier: s1
  cross-read, per its ruling.
- L7 Writer result and parent review, 2026-11-06. The writer wrote the implementation before its tests and obtained
  RED afterwards by swapping the four source files for a compiling no-op stub (assertion failures, not compile
  errors); recorded as such, not as test-first. It did not reuse `nameRel`, which returns a directory, and computes
  the file path with `filepath.Rel` + `ToSlash`. Parent changes after reading every source file: (a) S7 pin for an
  unreadable source file (a dangling symlink, unreadable for root too); (b) S9 "never writes without the variable"
  moved from the test body into `UpdateDebtIfRequested(request, root, debtPath)`, RED observed against an
  unconditional stub (`RSDD_MODULARITY_UPDATE="": changed=true ... want the file untouched`); the function takes
  the value because archtest's own rule forbids `os.Getenv` outside `cli/stdio.go`, which caught the first draft;
  (c) `TestDebtHeaderStatesTheLimits` ties the three-line header to the limit constants; (d) a one-line `sort`
  wrapper and two unused test helpers removed (staticcheck U1000). No uncovered spec item remains.
- L8 Evidence on this branch, measurements at base 512db127: real tree `scanned=615 generated=3 over200=152
  entries=152 lowerable=0`; 30 entries are over 400. The shell list had 154 names; the Go check rejected two as
  generated (`internal/core/adapter/nfkc_tables.go`, `internal/formats/zipdata_gen.go`), so the two counts agree
  once S1 is applied. Update mode on the clean tree left the debt file byte-identical. Probe in a scratch copy
  outside the worktree (removed): a new 201-line file, a listed file grown from 201 to 202, and a 732-line file
  grown by one line produced messages a, c and d of S5, each with the exact line.
- L9 Mutation run, 2026-11-06 (CI scope: `rsdd-go.test.sh --teeth-files origin/main | --teeth-plan 1/1`, then `make
  teeth TEETH_PKG=./internal/testkit/archtest`). First run: 89 killed, 3 lived, 20 not covered. All 20 were deciding
  comparisons written as case expressions of a tagless `switch`, which the mutation tool never runs (campaign lesson
  L118). The comparisons became plain `if` statements (`judgeEntry`, `orderProblem`, the update loop) with boundary
  cases on both sides of 200, 400 and the recorded count (`filesize_boundary_test.go`). Second run: 102 killed, 0
  lived, 0 not covered.
- L10 Independent verification, first launch (2026-11-06): the verifier ran 1 min 45 s and then stalled on a tool call
  that never executed; it was stopped after 29 minutes and produced no verdict. Observed before the stall, in a scratch
  copy: the package passes on base and candidate under both tag sets; every test that passed on the base still passes;
  the literal `<reason>` placeholder of message a is rejected (8 characters); an unsorted pasted line is rejected; a
  listed file shrunk below its count reads `lowerable=1`; a `legacy` file grown to 401 with its line edited in the same
  diff passes (S12). Its next probe was a NEW 900-line file listed as `legacy`: reading `judgeEntry`, that passes too,
  because only `accepted` is bounded by the hard limit and a tree cannot tell an added `legacy` line from an original
  one. S12 and the header now name both forms. The mechanical closure is a comparison against the merge base, which
  serves every only-shrink file at once (this list, the teeth debt, the planned consumers baseline): proposed to s1
  for the phase 8 CI join, not built here.
- L11 Independent verification, second launch, on 185721df (rebased on b55f8e4c), in a scratch copy outside the
  worktree (removed): PASS WITH ADVISORIES, no blocker. Every S1-S12 has an observed verdict. S10 was recounted with
  `find`/`awk`/`wc`: 620 non-test files outside testdata, 3 generated, 152 over 200, identical to the list. Update
  mode: only the value `1` writes; it lowered and deleted at the first, middle and last entry, never raised, never
  added, kept comments, blank lines, a malformed line and the file mode, left no temp file, and left the mtime
  unchanged on a second run. Every failing run without the variable left the list's sha256 unchanged. Advisories and
  what was done: (1) S12 said the limit is stated in message d, which it is not: S12 corrected; (2) the limits shared
  a file with the scanner: moved to `filesize_limits.go` (a pure move, no logic changed, so the mutation run of L9
  was not repeated locally; CI repeats it); (3) violations sort as strings, so `modularity-debt.txt:13` prints
  before `:8`: cosmetic, left; (4) a malformed entry also yields message a for its file: redundant but correct, left;
  (5) out of domain, left: `+250` and `0250` parse as counts, a generated marker ending in CRLF is exempt, the
  atomic write would replace a symlinked list with a regular file. Not probed: a CRLF list in update mode.
- L12 Review and correction, 2026-11-06. Native review of b824c098 (lenses readability and reliability): approved and
  acknowledged, ten advisories, none blocking. Eight were applied before the push because every lane meets this
  check: (1) the header said a `legacy` entry "may only go down" while message c tells the writer to raise it: the
  three header lines are rewritten to the rule as ruled in L4; (2) the scan read paths the go tool ignores, so a
  scratch copy under a dot directory read as unlisted files and an editor's dangling lock symlink ending in `.go`
  turned the run into a read error: S1 now exempts them; (3) one misplaced debt line made every later entry read
  as unsorted and then as unlisted (about 300 messages on the real list): an out-of-order line is now reported
  once and still read, and a duplicate is named a duplicate wherever it stands; (4) the mode test used 0600, the
  temp file's own default, so it could not fail: it uses 0640; (5) the `<reason>` placeholder was refused only
  because it is shorter than ten characters: it is refused by name; (6) `UpdateDebt` returned true with a write
  error: it returns false; (7) and (8) two test readability fixes. Left as advisories: the update loop restates
  the delete and lower rules of the judge; a CRLF list comes out of update mode with mixed endings. RED, executed
  before the change: `TestScanSkipsPathsTheGoToolIgnores` (`an ignored path was read: ... .#lock.go: no such file`),
  `TestScanReadsARootWhateverItsOwnName` (root named `testdata`: `scanned=0 ... no production Go files`),
  `TestOneMisplacedLineYieldsOneMessage` (three "not listed" messages, `entries = 1, want all 4 read`),
  `TestDuplicateFarFromItsFirstLine` (`a.go is not after b.go (unsorted)`), `TestThePrintedLineIsRefusedUntilItHasAReason`
  (`reason is shorter than 10 characters`), `TestUpdateReportsNoRewriteWhenTheWriteFails` (`changed=true err=...
  permission denied`). Teeth: 18 hand mutants through `go test -overlay`, all killed (among them the mode not
  copied, the root exemption dropped or inverted, each ignore prefix, order `>=`, a kept duplicate, a dropped
  unsorted line, the placeholder test inverted or removed); `gremlins unleash --dry-run`: 106 runnable, 0 not
  covered. The full mutation run of the package is CI's (three heavy slots were held).
- L13 Second review, 2026-11-06. Native review of 604a16a1 against b824c098 (lenses reliability and readability):
  approved and acknowledged, no blocker. Both lenses reported the same defect in the correction: the duplicate
  check ran only for a line out of order, and a kept misplaced line lowers what the next line is compared with, so
  for entries `z, a, b, z` the second `z` sorted after `b` and was accepted and judged twice; L12's "named a
  duplicate wherever it stands" was not true for that order. The run still failed, on the misplaced line. Fixed:
  duplicates are checked first. Once they are, a path equal to the previous one never reaches the order
  comparison, so that comparison is `cmp.Less` and not `>`: with `>` the `>=` mutant would be equivalent and the
  mutation run could never kill it. RED, executed before the change: `TestDuplicateAfterAMisplacedLine` (only the
  unsorted message, `entries = 4, want 3`). The third finding, a suggestion, is applied too: the write-failure
  test skips where a file can be created in a read-only directory, and the scan test logs instead of failing
  where a symlink cannot be created; on Linux as a non-root user neither path is taken. Teeth after the change: 21
  hand mutants through `go test -overlay`, all killed (among them duplicates checked only for a line out of
  order, the review's own case); dry run 104 runnable, 0 not covered.
- L14 Third review, 2026-11-06. Native review of 85e917af against 604a16a1 (lens reliability): approved and
  acknowledged, two advisories, both applied. (1) L13 had turned the scan test's symlink set-up failure into a log
  line; that hid every set-up failure, not only a platform without symlinks, so it stops the test again (the
  module's tests run on Linux only). (2) `cmp.Less` removed the equivalent `>=` mutant but also the killable ones
  from the recurring mutation run; the comparison is now `strings.Compare(prev, path) == -1`, which has no boundary
  mutant and keeps a negation and a sign mutant the run can kill. Behaviour is unchanged.
- L15 Cross-read by the orchestrator (fresh-context reader), 2026-11-06, at e6a59aac: NOT YET, two blockers, both "the
  stated rule differs from what the test enforces". B1: a pure move of a listed file over 400 printed "delete this
  line" for the old path and "a new file over 400 lines cannot be listed: split it" for the new one; following both
  forced a split inside a move, and the header's "legacy entries are never added" made a reviewer refuse the right
  edit. Fixed as asked: the header and both messages say that a file that moves keeps its line under the new path
  (same count and kind) and that this is not a new entry; a test pins the stale path and the changed path. B2: a
  file over 400 that shrank could grow back unseen up to its stale count (recorded 1010, now 450, later 1000, test
  green), against "above 400 no growth". Ruling, verbatim: "option (a), strict where the owner's rule is strictest:
  for an entry whose recorded count is over 400, n < recorded FAILS and prints the lowered line (or the delete, when
  n <= 200); entries recorded at 400 or less keep the slack of S6, and `lowerable` is printed unconditionally (not
  t.Logf) so it shows in CI." Done: S6 rewritten, message i added, boundary cases for recorded 401 (n = 401, 400,
  201, 200) and for recorded 400 (n = 399 keeps its slack), the regrowth scenario as a test. On "shows in CI": the
  summary is now printed with fmt.Printf, which a -v or -json run keeps; `make test` runs `go test ./...` without
  either, and in that mode go drops every output of a passing package, a print as much as a log line, so the
  number reaches CI only once the job reads the -json stream (the CI-join slices). Advisories applied: (1) a
  malformed line no longer makes its file read as unlisted; (2) the checks are ordered so that a line to delete or
  lower is said before "split" (an `accepted 450` entry whose file is at 150 lines is deleted, at 300 lowered);
  (3) an unreadable directory has a test and its error names the path; (8) the zero-file and unreadable-file tests
  check the error text; (9) S12 and the pull request body make one statement on the base comparison; (7) the
  not-rewritten test uses os.SameFile. Not applied, optional (4): the import-check walker of archtest.go does not
  share the go-tool ignore rule of the new scan; it is an existing check with its own tests and goes to a follow-up.
  RED, executed before the change: `TestMovedFileKeepsItsLineUnderTheNewPath` (both messages without the move
  sentence), `TestCountOverTheHardLimitIsExact` (recorded 401, now 400: `violations = [] lowerable = 1`),
  `TestFileOverTheHardLimitCannotGrowBackUnseen` (`450 lines under a stale 1010: violations = []`),
  `TestMalformedLineDoesNotReadAsAnUnlistedFile` (the "cannot be listed: split it" message beside the bad line),
  `TestUnreadableDirectoryIsAnError` (the error did not name the directory). Two message constants were first
  written as a literal plus a shared constant; the dry run then read 3 NOT COVERED, each the `+` of a constant
  expression, which no test can cover, so the texts are whole literals. Numbers settled: the verifier of L11
  counted 620 non-test files (617 scanned) at 185721df; b824c098 added filesize_limits.go, so the tree reads 621
  non-test files, 3 generated, 618 scanned from then on (recounted independently at this commit). The dry run read
  104 runnable at 85e917af, 107 at e6a59aac (the order comparison has three mutants) and reads 111 at this commit.
  The real tree is unchanged by the new rule: no entry over 400 is above its file (lowerable=0).


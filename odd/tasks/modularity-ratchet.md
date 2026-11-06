# Feature: file-size ratchet for the Go module (modular code rule)

Objective: make the owner's "all code is modular" rule mechanical at file level in `research-sdd/rsdd`. Issue #2738.
Branch `feat/rsdd-modularity-ratchet-2738` (base origin/main 512db127). Delivery: single PR, two work-unit commits.
Test runner: `go test ./internal/testkit/archtest/` from `research-sdd/rsdd` (focused); CI runs it inside `make test`.

## Specs

- S1 Scope. Every `.go` file under the module root (`research-sdd/rsdd`) is a production file, except: a name ending
  `_test.go`; a path with a `testdata` directory component (relative to the scanned root); a generated file. A file is
  generated only when a line matching `^// Code generated .* DO NOT EDIT\.$` appears before its `package` clause.
  Paths are root-relative with forward slashes (`internal/verify/state.go`).
- S2 Line count. The number of `\n` bytes, plus one when the file is non-empty and does not end with `\n`.
- S3 Limits. Soft limit 200, hard limit 400, defined once. Owner: "about 200 lines or less". Orchestrator ruling
  2026-11-06: "200 reviewed target, 400 hard ceiling".
- S4 Debt file `research-sdd/rsdd/modularity-debt.txt`. Blank lines and lines starting with `#` are ignored. Every
  other line is `<path> <lines> <kind> <reason>`: whitespace-separated, `<lines>` a positive integer, `<kind>` one of
  `legacy` (recorded when the ratchet was created) or `accepted` (a later, reasoned exception), `<reason>` the rest of
  the line, at least 10 characters. Entries are in strictly increasing byte order of `<path>` (so a duplicate fails).
  The header states the rule in three lines, so a writer who meets a failure needs no other document.
- S5 Violations. Each message carries the exact line to add, change or delete:
  a. unlisted, 200 < n <= 400: `<path>: <n> lines, over 200 and not listed. Split it, or add this line to modularity-debt.txt:` then `<path> <n> accepted <reason>`
  b. unlisted, n > 400: `<path>: <n> lines, over 400. A new file over 400 lines cannot be listed: split it.`
  c. listed, n > recorded, n <= 400: `<path>: grew from <recorded> to <n> lines. Split it, or change its line in modularity-debt.txt to:` then `<path> <n> <kind> <reason>`
  d. listed, n > recorded, n > 400: `<path>: grew from <recorded> to <n> lines and is over 400. A file over 400 lines may not grow: split it first.`
  e. listed, n <= 200: `<path>: <n> lines, no longer over 200. Delete this line from modularity-debt.txt:` then the line
  f. listed, not a production file of the tree (missing, a test, generated): `<path>: listed but not a production Go file in this tree. Delete this line from modularity-debt.txt:` then the line
  g. `accepted` with recorded > 400: `modularity-debt.txt:<lineno>: an accepted entry may not be above 400 lines (<path> <recorded>): split the file.`
  h. malformed, unknown kind, short reason, unsorted or duplicate: `modularity-debt.txt:<lineno>: <what is wrong>; expected "<path> <lines> <legacy|accepted> <reason of at least 10 characters>", entries sorted by path`
- S6 Ceiling semantics. A listed file with 200 < n <= recorded passes; a small edit never forces a debt-file edit. The
  result counts how many entries could be lowered.
- S7 Operational errors (an error, never a pass): the debt file is absent or unreadable; the root holds zero production
  Go files; a source file cannot be read. An existing debt file with no entries is valid when no file is over 200.
- S8 Proof of looking. The result reports files scanned, generated files exempted, files over 200, entries read and
  entries that could be lowered; the real-tree test logs them.
- S9 Update mode. With `RSDD_MODULARITY_UPDATE=1` the real-tree test rewrites the debt file before checking: it lowers
  a recorded count to the current count when the file shrank and is still over 200, and deletes the line of a file
  that is at 200 or less or is not a production file. It never raises a count and never adds an entry. Comments, blank
  lines and order are kept. The write is atomic (temp file in the same directory, same mode, rename) and is skipped
  when nothing changes. Without the variable the test never writes.
- S10 Initial list. Every production file over 200 lines on this branch is recorded as `legacy` with the reason
  `recorded when the ratchet was created (#2738)`.
- S11 Self-compliance. Every Go file this change adds is at 200 lines or less; standard library only; package
  `archtest`; limits and message formats separate from the scanning logic.
- S12 Known limit, stated in the debt-file header and in message d: a tree-only test cannot stop a change that raises a
  `legacy` entry above 400 in the same diff. That is a review rule. A base comparison in CI is added only if observed.

## Tasks

- [ ] T1 (S1-S9, S11) engine + parser + update mode + temp-tree tests · route: delegated (sonnet writer; parent s10 is
  read-only by role and holds no other file), then parent review and three pins inline · commit: 10c989af · observed:
  package tests under default and `nodiff` tags, vet, staticcheck, both cross builds (L7) · open: mutation run
- [ ] T2 (S10, S12) debt list + real-tree test + header · route: same writer · commit: the one that adds this file ·
  observed: real-tree test, update mode byte-identical on a clean tree, scratch-copy probe (L8) · open: mutation run

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

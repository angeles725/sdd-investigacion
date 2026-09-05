# kit-instrument-honesty Specification

## Purpose

Every toolbelt instrument MUST distinguish absent input, empty input, and no-match as three separate states
and MUST NOT emit a confident zero without proof it looked. `run-all.sh` MUST account for suites that
silently ignore `--prove-teeth`. Parsers MUST enumerate every real-fleet form they recognise and WARN
on unrecognised forms rather than silently skipping them.

## Requirements

### Requirement: Three-State Instrument Honesty

Every production toolbelt instrument MUST report three distinguishable states: `absent-input` (file or
directory not found), `empty-input` (found and genuinely empty), and `no-match` (items exist; none
satisfied the filter). A result of zero that could equally mean any of the three is a defect.
Instruments that are WARN-only MUST still exit non-zero on operational failure (broken instrument),
never on findings. `|| true` appended after a real producer MUST NOT appear in production code.

#### Scenario: Absent input exits non-zero with typed label

- GIVEN a corpus path that does not exist on disk
- WHEN the instrument is invoked against that path
- THEN the instrument exits non-zero AND prints a line containing a typed `absent-input` indication
- AND does NOT print a zero count as though it ran successfully

#### Scenario: No-match distinguished from absent

- GIVEN a valid corpus directory containing files, none of which satisfy the filter
- WHEN the instrument is invoked
- THEN it exits 0 AND prints a typed no-match indication (e.g., `0 matching`)
- AND the output is distinct from the absent-input case

#### Scenario: Mutation — absent-input guard removed goes red

- GIVEN a mutant of the instrument where the absent-input guard is deleted
- WHEN the companion test suite is run with `--prove-teeth`
- THEN the suite exits non-zero

#### Scenario: Unguarded `|| true` after producer eliminated — bite test

- GIVEN each of the 11 sites where `|| true` followed a real producer
- WHEN the typed handling introduced by U12 is removed (the mutant)
- THEN the companion test exits non-zero for that site

### Requirement: Teeth Accounting in run-all.sh

`run-all.sh` MUST count suites that exit 0 under `--prove-teeth` without implementing mutation controls.
It MUST include the following summary line in every `--prove-teeth` run (the plain run's aggregate stays
byte-identical), with suite basenames sorted and the honesty clause verbatim (issue #426):

```
Suites without teeth: N — [suite-a, suite-b, …] (vocabulary check: a "teeth" case with no real mutant is a review item)
```

Counting rule: under `--prove-teeth`, a suite whose PASS/FAIL case lines contain no `teeth` (case-insensitive)
is counted. Node (`.test.mjs`) suites take no flag and run their teeth unconditionally (`adversarial-verdict.test.mjs:37-50`),
so `run-all.sh` MUST NOT count them as suites without teeth: it prints a separate line
`Suites n/a for teeth (node): N`. A third state, `Suites with teeth but no banner: N — [names]`, is derived by
cross-checking teeth-banner lines (`^\s*(--|==)\s*teeth\b`, case-insensitive) against the static set of suites
that handle the flag. (Spec amended after design validation: the earlier "forward the flag to node" MUST was
withdrawn on evidence — there is nothing to forward.)

When invoked with `--require-teeth`, `run-all.sh` MUST exit non-zero when N > 0. The default run
(without `--require-teeth`) MUST remain green regardless of N; only the count is reported.

#### Scenario: Teeth count line emitted on every run

- GIVEN 21 shell suites that silently exit 0 under `--prove-teeth` and 1 node suite whose teeth always run
- WHEN `run-all.sh` is invoked without `--require-teeth`
- THEN stdout includes a line matching `Suites without teeth: 21 — [...]`
- AND the overall exit code is 0

#### Scenario: --require-teeth fails when N > 0

- GIVEN at least one suite that silently ignores `--prove-teeth`
- WHEN `run-all.sh --require-teeth` is invoked
- THEN the exit code is non-zero

#### Scenario: Fleet acceptance — no new unintended failures

- GIVEN `run-all.sh` on `main` and on the patched branch against the real kit on a quiet tree
- WHEN both runs complete
- THEN the patched branch names every suite that exits 0 under `--prove-teeth` silently
- AND the patched branch introduces no new test failures beyond the teeth-accounting line

### Requirement: Saturation Parser Enumerates All Fleet Forms

`research-sdd-status.sh` MUST recognise every iteration-history table header shape and cell form
observed in the real fleet (8 header shapes; cell forms including integer-only, `N new`,
`none net-new …`, `G12`). Any table it cannot classify MUST emit a typed WARN naming the unrecognised
form. After the fix, the count of silently-skipped (BLIND) tables MUST be 0; any residual
unrecognised tables MUST be listed by name in the output, never omitted silently.

#### Scenario: Previously BLIND tables are classified

- GIVEN the 50 iteration-history tables in the real fleet, 35 of which were previously BLIND
- WHEN `research-sdd-status.sh` is run on the real corpus
- THEN the count of silently-skipped tables is 0; any still-unrecognised tables appear in a WARN

#### Scenario: Unrecognised cell form produces typed WARN

- GIVEN an iteration-history table with a cell form not in the enumerated set
- WHEN `research-sdd-status.sh` is run
- THEN a WARN line is emitted naming the unrecognised form
- AND no confident saturation number is reported for that table

#### Scenario: Mutation — cell-form parser bypass goes red

- GIVEN a mutant that returns 0 for any unrecognised cell without emitting a WARN
- WHEN the test suite runs under `--prove-teeth`
- THEN the suite exits non-zero

#### Scenario: Literal saturation output partition (issue #420 wording)

- GIVEN the 50 fleet state files that carry an `## Iteration history` table
- WHEN `research-sdd-status.sh` selects the New-gaps column by header name (`/new gaps|nuevos gaps/i`), reads a leading integer (`^\+?[0-9]+`) or the none-family (`none…`, `ninguno`, `ningún`) as the count, keeps rows in file order when the index is `it.N`, `N (…)` or unreadable, and never drops a row whose New-gaps cell is readable
- THEN a table without such a column prints `saturation : no New-gaps column (header: …)`
- AND a table whose last 3 rows contain an unrecognised cell (identifier lists such as `B754-G1/G2`, `IC1–IC4 seeded`, or `—`) prints `saturation : unreadable window — N of last 3 rows unrecognised (forms: …)` and does NOT compute on the readable subset
- AND fewer than 3 readable rows prints `saturation : insufficient history (n iterations)`
- AND the expected partition is ~36 readable (active/SATURATED), 8 no-column, 6 unreadable-window, 19 no-header files byte-identical; any file outside its bucket needs a named reason in the PR
- AND a mutant that computes on the readable subset of an unreadable window turns that fixture SATURATED → red

### Requirement: sweep-retros Typed Delta-Missing State

`sweep-retros.sh` MUST emit a distinct typed state (e.g., `delta-section-not-found`) for a PENDING
retro that carries no canonical delta-section heading. It MUST NOT emit a confident `~0` for such a
retro. It MUST surface retros that carry no review-status marker. Recognised heading forms MUST be
the closed enumerated set measured in the fleet (see kit-doctrine-grammar); no open-ended regex MAY
extend this set.

#### Scenario: Prose-only delta retro → typed state, not confident zero

- GIVEN a PENDING retro whose kit-facing proposals appear only in prose, with no canonical heading
- WHEN `sweep-retros.sh` is run
- THEN the output shows `delta-section-not-found` (or equivalent) for that retro
- AND does NOT show `~0`

#### Scenario: Missing review-status marker surfaced

- GIVEN a corpus containing 5 retros with no `review-status:` line
- WHEN `sweep-retros.sh` is run
- THEN each unmarked retro is listed with a typed WARN

### Requirement: D1 Doctrine — §20 Freeze and §7 Engram Fallback

METHODOLOGY.md §20 MUST state that the live subject MUST be frozen (md5/hash captured) before any
session begins document-mode work. METHODOLOGY.md §7 MUST state the fallback behavior when
`mem_search` is invoked with a project name that has no registered target in Engram.

#### Scenario: §20 freeze-first sentence present

- GIVEN METHODOLOGY.md §20
- WHEN a structural readback reads the section
- THEN the text contains a sentence stating the live subject MUST be frozen before work begins

#### Scenario: §7 engram unregistered-target fallback present

- GIVEN METHODOLOGY.md §7
- WHEN a structural readback reads the section
- THEN the text states what to do when the target project is not registered in Engram

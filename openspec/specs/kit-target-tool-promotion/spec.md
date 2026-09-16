# kit-target-tool-promotion Specification

## Purpose

Governs how a general capability found in a target corpus is promoted into the research-sdd toolbelt
as a clean, rebuilt evidence wrapper: target-agnostic, honest, tested, registered, and delivered within
the review budget. Promoted wrappers MUST also satisfy all requirements in the `kit-instrument-honesty`
specification; this spec adds the promotion-specific requirements layered on top of it.

## Requirements

### Requirement: Rebuild-Not-Copy

A promoted wrapper MUST be a clean reimplementation derived from the source tool's observable behavior.
It MUST NOT contain target-specific references (corpus block IDs, building names, device names, site
names). All code, comments, and output strings MUST be in English (§9).

#### Scenario: No target-specific tokens present

- GIVEN a promoted wrapper and its companion test file
- WHEN a readback scans both files for target-specific identifiers
- THEN no such identifiers are found

#### Scenario: Non-English content rejected by gate

- GIVEN a wrapper containing a non-English comment or output string
- WHEN the shellcheck + readback gate runs
- THEN the gate exits non-zero

### Requirement: Read-Only Default Gate

Any wrapper that performs a live-network probe, modifies system state, or exercises hardware MUST gate
that action behind an explicit `--allow-live-probe` flag. Without that flag the wrapper MUST emit an
offline plan and exit with a non-zero plan-only status. No network, write, or hardware command MAY be
issued in the default run. Model: `corroborate-bacnet` pilot.

#### Scenario: Default run is plan-only

- GIVEN a live-probe wrapper invoked without `--allow-live-probe`
- WHEN the wrapper runs
- THEN it prints a plan describing what it would probe AND exits non-zero AND issues no network connection

#### Scenario: Live action requires explicit flag

- GIVEN the same wrapper invoked with `--allow-live-probe`
- WHEN the wrapper runs
- THEN it performs the probe and exits with the action's result status

#### Scenario: Guard-removal mutant goes red

- GIVEN a mutant where the plan-only guard's exit code is changed (e.g. `sys.exit(3)` → `sys.exit(0)`)
- WHEN the companion test suite runs with `--prove-teeth`
- THEN the suite exits non-zero — detected entirely offline, without sending any real network I/O

### Requirement: Three-State Honesty

Promoted wrappers MUST satisfy the Three-State Instrument Honesty requirement from `kit-instrument-honesty`:
absent-input, empty-input, and no-match MUST produce distinct typed outputs; a bare 0/PASS that cannot
prove the instrument looked is a defect.

#### Scenario: Three states produce distinct output

- GIVEN a wrapper invoked against (a) a missing path, (b) an empty directory, (c) a populated corpus with no match
- WHEN each invocation completes
- THEN each produces a distinct typed label; no case silently emits zero

### Requirement: TDD with Mutation Teeth

Every promoted wrapper MUST ship a companion `*.test.sh` under `research-sdd/toolbelt/tests/`. The
suite MUST implement at least one mutation control and MUST print a teeth banner matching
`^\s*(--|==)\s*teeth\b` at runtime so `run-all.sh` recognizes it. The suite MUST pass
`run-all.sh --prove-teeth`. Both files MUST pass `shellcheck -S warning` with zero warnings.

#### Scenario: Suite passes all gates on quiet tree

- GIVEN a promoted wrapper and its companion `*.test.sh`
- WHEN `bash research-sdd/toolbelt/tests/run-all.sh` runs on a quiet tree
- THEN the new suite passes with zero failures and does not appear in `Suites without teeth`
  or `Suites with teeth but no banner`

#### Scenario: Mutation controls bite

- GIVEN a mutant of the wrapper with a guard removed
- WHEN `run-all.sh --prove-teeth` runs
- THEN the mutation control case exits non-zero

### Requirement: Registration

Every promoted wrapper MUST have a row in `tool-registry.md`. The exact row shape is deferred to the
design phase. An `INSTALLED-TOOLS.md` row is required only when the wrapper introduces a new external
dependency.

#### Scenario: Registry row present at merge

- GIVEN a promotion PR
- WHEN the PR diff is reviewed
- THEN a `tool-registry.md` row for the wrapper is present; an `INSTALLED-TOOLS.md` row is added only if a new external dependency is introduced

### Requirement: Fleet-Validated Acceptance

A promoted wrapper is accepted only after running against real fleet data. Fixture-green alone does not
constitute acceptance. Every output difference from fixture results MUST be classified before merge.

#### Scenario: Fleet run precedes merge

- GIVEN a promotion candidate run against the real corpus fleet
- WHEN outputs are compared to fixture expectations
- THEN every discrepancy is classified as true behavior or defect before the PR merges

### Requirement: One-Wrapper-Per-PR Delivery

Each wrapper is delivered in its own auto-chained PR. A single PR MUST NOT bundle more than one wrapper.
Each PR MUST stay within the ~400-line review budget (§6).

#### Scenario: Single wrapper per PR

- GIVEN a sequence of promotion PRs
- WHEN each PR is reviewed
- THEN each introduces exactly one wrapper, its companion test, and its registry row, within the 400-line budget

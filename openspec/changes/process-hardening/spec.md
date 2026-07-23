# process-integrity Specification

## Purpose

Verifies that `openspec/invariants.md` is structurally sound and that every
claim of enforcement is backed by a test file that exists on disk. Prevents the
registry from becoming unenforced prose while itself remaining unenforced.

## Requirements

### Requirement: Registry Presence

The check MUST fail — not skip — when the registry file is absent or cannot be
parsed into structured entries. A vacuous pass on a missing registry is treated
as a defect equal in severity to a failed invariant.

#### Scenario: Missing registry

- GIVEN the registry file does not exist at its canonical path
- WHEN the process-integrity check runs
- THEN the check MUST fail with a message indicating the file is missing

#### Scenario: Unparseable registry

- GIVEN the registry file exists but cannot be parsed into structured entries
- WHEN the check runs
- THEN the check MUST fail identifying the parse failure

### Requirement: Registry Well-Formedness

Every registry entry MUST contain all five required fields: `id`, `statement`,
`origin`, `status`, and `asserted by`. The `status` field MUST be drawn
exclusively from the closed set `{enforced, pending}`. Any entry missing a
field or carrying an unlisted status value MUST be rejected.

#### Scenario: Valid entry

- GIVEN all entries carry the five required fields with valid status values
- WHEN the well-formedness check runs
- THEN the check MUST pass

#### Scenario: Missing required field

- GIVEN an entry where any of the five required fields is absent
- WHEN the check runs
- THEN the check MUST fail naming the malformed entry

#### Scenario: Invalid status value

- GIVEN an entry whose status is neither `enforced` nor `pending`
- WHEN the check runs
- THEN the check MUST fail identifying the entry and the offending value

### Requirement: Enforced Invariants Are Real

Every entry with `status: enforced` MUST name at least one test file in its
`asserted by` field, and every named file MUST exist on disk at the time the
check runs.

#### Scenario: Test file exists

- GIVEN an enforced entry whose named test file exists on disk
- WHEN the check runs
- THEN the check MUST pass for that entry

#### Scenario: Named test file absent from disk

- GIVEN an enforced entry that names a test file which does not exist on disk
- WHEN the check runs
- THEN the check MUST fail naming both the invariant id and the missing file path

#### Scenario: No test file named

- GIVEN an enforced entry with an empty `asserted by` field
- WHEN the check runs
- THEN the check MUST fail identifying the invariant id

### Requirement: Pending Invariants Are Tracked

Every entry with `status: pending` MUST have a corresponding row in the
open-invariants map, and every row in that map MUST reference a `pending`
entry. Consistency is bidirectional: omissions in either direction are failures.

#### Scenario: Pending entry present in map

- GIVEN a pending entry that has a row in the open-invariants map
- WHEN the check runs
- THEN the check MUST pass for that entry

#### Scenario: Pending entry absent from map

- GIVEN a pending entry with no corresponding row in the open-invariants map
- WHEN the check runs
- THEN the check MUST fail naming the untracked invariant id

#### Scenario: Map row references a non-pending entry

- GIVEN a map row referencing an invariant whose status is `enforced`, or
  referencing an id that does not exist in the registry
- WHEN the check runs
- THEN the check MUST fail identifying the inconsistent map row

### Requirement: Promotion Discipline

An entry MUST NOT transition from `pending` to `enforced` unless its `asserted
by` field names at least one test file that exists on disk. The Enforced
Invariants Are Real check provides the automated gate for this property.

Automated detection of a closed GitHub issue whose invariant is still `pending`
MUST NOT be attempted by the check: querying the GitHub API requires network
access, which violates the offline guardrail. The offline-safe substitute for
this gate is the PR-level review: a reviewer SHALL verify manually, before
merging any PR that closes an issue, that the corresponding invariant has been
promoted (or explicitly retained as pending with a recorded justification). This
obligation MUST be stated in the registry's own Rules section.

#### Scenario: Promotion with an existing test file

- GIVEN an entry changed from `pending` to `enforced` with a named test file
  that exists on disk
- WHEN the check runs after the change
- THEN the check MUST pass

#### Scenario: Promotion without a test file

- GIVEN an entry changed from `pending` to `enforced` with an empty or
  non-existent `asserted by` field
- WHEN the check runs after the change
- THEN the check MUST fail

### Requirement: Normal Suite Integration

The process-integrity check MUST be implemented as a `*.test.sh` file placed
under `research-sdd/toolbelt/tests/` so that `run-all.sh` discovers and
executes it automatically without any registration change. The check MUST run
entirely offline and MUST NOT perform any network operation.

#### Scenario: Automatic discovery by run-all.sh

- GIVEN the check file is named `*.test.sh` and lives under
  `research-sdd/toolbelt/tests/`
- WHEN `bash research-sdd/toolbelt/tests/run-all.sh` is executed
- THEN the check is included in the suite run without manual registration

#### Scenario: Offline execution

- GIVEN an environment with no network access
- WHEN the check runs against a valid registry
- THEN it MUST complete (pass or fail) without any network operation

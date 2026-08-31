# SessionStart Hook Behavior Contract

## No Capability-Level Spec Delta

This change contains no new or modified product capabilities. The proposal's
Capabilities section is explicitly empty (kit-internal shell tooling; behavioral
fix to hook wrappers only). This spec captures the **observable behavior
contract** of the SessionStart hook wrappers as testable scenarios — the
doctrine backstop required by §7 and §8.

---

## Requirements

### Requirement: Silence on Genuinely Clean Runs

Each hook wrapper MUST emit nothing when its underlying instrument runs
successfully and reports no actionable findings. Silence applies ONLY to the
genuinely-clean path; it MUST NOT apply to operational failures.

#### Scenario: Retro hook — silent on clean

- GIVEN `sweep-retros.sh` exits 0 and its output contains no `PENDING` or `MISSING-RETRO` lines
- WHEN `sweep-retros-hook.sh` runs during SessionStart
- THEN the hook produces no stdout/stderr output
- AND exits 0

#### Scenario: Audits hook — silent on clean

- GIVEN `sweep-audits.sh` exits 0 and its output contains no `PENDING` lines
- WHEN `sweep-audits-hook.sh` runs during SessionStart
- THEN the hook produces no output AND exits 0

#### Scenario: Breakthroughs hook — silent on clean

- GIVEN `sweep-breakthroughs.sh` exits 0 and its Summary reports `unindexed=0` and `drifted=0`
- WHEN `sweep-breakthroughs-hook.sh` runs during SessionStart
- THEN the hook produces no output AND exits 0

#### Scenario: Registry hook — silent on clean

- GIVEN `verify-registry.sh` exits 0 and its output contains `Registry consistent`
- WHEN `verify-registry-hook.sh` runs during SessionStart
- THEN the hook produces no output AND exits 0

---

### Requirement: Emit on Actionable Findings

A hook wrapper MUST emit its header, Summary, and guidance when its underlying
instrument reports at least one actionable finding.

#### Scenario: Findings present — header and Summary emitted

- GIVEN the underlying instrument exits 0 with at least one actionable finding token
- WHEN the hook runs during SessionStart
- THEN the hook emits a header line, a Summary block, and guidance text
- AND exits 0

---

### Requirement: Operational Failures Stay Loud

A hook wrapper MUST NOT suppress output or convert a non-zero exit to zero when
its underlying instrument fails operationally. The §7 anti-silent-zero invariant
applies: absent-input, empty-input, and no-match MUST remain distinguishable at
all times. A silence guard MUST exit before the emit block ONLY on the clean
signal; the failure path MUST be unreachable by the guard.

#### Scenario: Operational failure — banner visible, exit preserved

- GIVEN the underlying instrument fails operationally (TARGETS.md missing, lib helper undefined)
- WHEN the hook runs during SessionStart
- THEN the hook emits a failure banner
- AND exits with a non-zero code
- AND the silence guard does NOT intercept this path

#### Scenario: Silence guard mutation — guard removal causes test to go RED

- GIVEN the hook's silence guard is mutated so the clean-signal check is removed
- WHEN a clean-run test exercises the hook
- THEN the test fails (goes RED), proving mutation teeth are present

---

### Requirement: Ledger-Consistent Positive Sentence

`sweep-breakthroughs.sh` MUST emit a positive sentence indicating ledger
consistency when `unindexed=0` and `drifted=0`, so the clean state is
unambiguous rather than a bare or absent Summary.

#### Scenario: Ledger clean — positive sentence present

- GIVEN `sweep-breakthroughs.sh` runs and both `unindexed` and `drifted` counts are 0
- WHEN the script completes
- THEN its output includes a sentence indicating the ledger is consistent
- AND no ambiguous bare count line appears without an explanatory label

---

### Requirement: Neutral Header Wording

Each hook MUST use the same neutral header term regardless of whether the run
ends clean or with findings. Terms that imply a finding on a clean run MUST be
replaced with neutral equivalents.

#### Scenario: Registry hook — neutral header on any run

- GIVEN `verify-registry-hook.sh` emits output (findings case)
- THEN the header reads `registry check`, NOT `registry drift`

#### Scenario: Retro hook — singular header on any run

- GIVEN `sweep-retros-hook.sh` emits output
- THEN the header reads `retro sweep`, NOT `retros sweep`

---

### Requirement: Absent-Input vs Empty-Input Distinction (PR #2, chained)

The four underlying sweep/verify scripts MUST use distinguishable exit codes and
messages so that:
- TARGETS.md absent or broken → operational-error exit distinct from "zero rows"
- TARGETS.md present but with zero rows → explicit "nothing registered" signal distinct from absent

This preserves the §7 three-state contract: absent-input, empty-input, and
no-match are never conflated into a single silent zero.

#### Scenario: TARGETS.md absent — operational error signal

- GIVEN TARGETS.md does not exist (or is unreadable)
- WHEN any of the four underlying scripts runs
- THEN the script exits with an operational-error code
- AND emits an explicit absent-input banner naming the missing file

#### Scenario: TARGETS.md present, zero rows — empty-input signal

- GIVEN TARGETS.md exists and contains no registry rows
- WHEN any of the four underlying scripts runs
- THEN the script emits a distinct "nothing registered yet" message
- AND exits with a code distinguishable from the absent-input exit code

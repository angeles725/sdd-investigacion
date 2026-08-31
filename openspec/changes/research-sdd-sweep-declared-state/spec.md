# Declared-State Sentinel — Kit-Internal Behavior Contract

## OpenSpec Capability Delta Notice

No formal OpenSpec capability delta. This change is entirely kit-internal:
it modifies observable stdout behavior and hook semantics in shell scripts
that have no published API surface. This file records the behavioral contract
as testable Given/When/Then scenarios serving as the doctrine backstop.

## Purpose

Each of the 4 SessionStart sweep/verify instruments MUST declare its own
aggregate run state via a machine-readable sentinel on stdout. The corresponding
hook reads that verdict to decide whether to emit to the Claude session. A
missing sentinel is structurally treated as not-clean (§7 anti-silent-zero).

## Requirements

### Requirement: Sentinel Emission

Each of the 4 scripts (sweep-retros, sweep-audits, sweep-breakthroughs,
verify-registry) MUST emit `RSDD-STATE: <state>` as the unconditionally last
stdout line on every run that reaches normal completion, where `<state>` is
exactly one of `clean`, `attention`, or `partial`.

#### Scenario: Sentinel is last stdout line

- GIVEN any of the 4 scripts runs to normal completion (rc=0)
- WHEN the script finishes
- THEN the last line written to stdout matches `^RSDD-STATE: (clean|attention|partial)$`
- AND no subsequent stdout lines appear after the sentinel

#### Scenario: No sentinel guarantee on operational failure

- GIVEN the script exits with rc=1 (operational failure)
- WHEN the script aborts
- THEN exit code remains 1 and no sentinel guarantee applies
- AND the hook MUST treat the resulting output as not-clean

### Requirement: State Computation

Each script MUST compute state from its own counters before emitting the
sentinel. Per-corpus absent/empty/no-match INFO prose lines do NOT force
`attention`; the sentinel is a run-level aggregate distinct from per-corpus prose.

| Script | clean condition | partial override | attention |
|---|---|---|---|
| sweep-retros | pending=0 AND no MISSING-RETRO AND skipped=0 | skipped>0 | otherwise |
| sweep-audits | pending=0 AND no MISSING-RETRO AND skipped=0 | skipped>0 | otherwise |
| sweep-breakthroughs | warn_unindexed=0 AND warn_drift=0 AND skipped=0 | skipped>0 | otherwise |
| verify-registry | drift=0 AND retro_drift=0 AND unresolved=0 AND rowlint=0 AND skipped=0 | skipped>0 | otherwise |

#### Scenario: All counters zero and no skipped targets

- GIVEN all attention counters are zero and skipped=0
- WHEN the sentinel is computed
- THEN the sentinel reads `RSDD-STATE: clean`

#### Scenario: One or more targets skipped

- GIVEN one or more targets were skipped or truncated (skipped>0)
- WHEN the sentinel is computed
- THEN the sentinel reads `RSDD-STATE: partial` regardless of other counters

#### Scenario: Attention condition present, none skipped

- GIVEN at least one attention counter is non-zero and skipped=0
- WHEN the sentinel is computed
- THEN the sentinel reads `RSDD-STATE: attention`

### Requirement: Hook Verdict Reading

Each hook MUST extract the sentinel via `grep '^RSDD-STATE:' | tail -1`
against the script output and take action on the result.

#### Scenario: Hook silent on clean

- GIVEN the script emits `RSDD-STATE: clean` as its last line
- WHEN the hook processes the output
- THEN the hook produces no output to the Claude session
- AND the hook exits 0

#### Scenario: Hook emits on attention

- GIVEN the script emits `RSDD-STATE: attention`
- WHEN the hook processes the output
- THEN the hook emits to the Claude session
- AND the hook exits 0

#### Scenario: Hook emits on partial

- GIVEN the script emits `RSDD-STATE: partial`
- WHEN the hook processes the output
- THEN the hook emits to the Claude session
- AND the hook exits 0

#### Scenario: Hook emits when sentinel absent — §7 anti-silent-zero

- GIVEN the script produces output with no `RSDD-STATE:` line (operational
  failure, pipeline truncation, or sentinel stripped by mutation)
- WHEN the hook attempts to extract the verdict
- THEN the hook treats absence as not-clean
- AND the hook emits to the Claude session
- AND the hook exits 0

### Requirement: Hook Exit Code Contract

Each hook MUST exit 0 in every branch without exception, to avoid breaking
the Claude session start sequence.

#### Scenario: Hook always exits 0

- GIVEN any script outcome (clean, attention, partial, missing-sentinel, rc=1)
- WHEN the hook completes any branch
- THEN the hook exit code is 0

### Requirement: Script Exit Code Preservation

The sentinel is stdout-only. Scripts MUST NOT alter their existing exit-code
contract (rc=0 normal, rc=1 operational failure). All 25+ existing rc=0
assertions and sweep-all.sh MUST remain green after this change.

### Requirement: Mutation Teeth

Test suites for these 8 files MUST include mutation controls proving the
sentinel is behaviorally load-bearing, not dead code.

#### Scenario: Stripping sentinel emit makes hook go loud

- GIVEN a mutation that removes or comments out the sentinel echo in a script
- WHEN the hook processes the resulting output
- THEN the hook emits (missing-sentinel branch activates, hook does not stay silent)

#### Scenario: Mutating a state counter flips the sentinel value

- GIVEN a mutation that sets one attention counter to non-zero in an otherwise-clean run
- WHEN the sentinel is computed
- THEN the sentinel reads `RSDD-STATE: attention` instead of `RSDD-STATE: clean`

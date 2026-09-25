# TestCorpus — Research State (campaign STOP condition met via a §8c PARTITION-CHECK-CREATED
# queue: all terminal + last_audit keeps enqueued=0 AND appends a partition="..." field — kit
# issue #1123 round 4, M1: a last_audit that REPLACED enqueued= with the partition line broke
# _campaign_stop_text, which reads enqueued= alone; this fixture guards the doctrine-fixed shape)

<!-- research-state.v1 -->
schema: research-state.v1
covered_blocks: 3
gaps_closed: 3
known_gaps: 3
investigable_open: 0
requires_execution_open: 0
blocked_open: 0
deferred_open: 0
undocumented_findings: 0
blocks_since_retro: 0
last_iteration_ts: 2026-09-25T09:00:00Z
<!-- /research-state.v1 -->

## Coverage

- **Covered blocks**: 3 (B1..B3)
- **Coverage metric**: 3/3 closed
- **Last iteration**: 2026-09-25 — gap-gamma

## Gap-backlog

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | gap-alpha | web | ✅ cubierto — B1 |
| medium | gap-beta | web | ✅ cubierto — B2 |
| low | gap-gamma | web | ✅ cubierto — B3 |

## Iteration history

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | 2026-09-23 | gap-alpha | B1 | no · inline | none |
| 2 | 2026-09-24 | gap-beta | B2 | no · inline | none |
| 3 | 2026-09-25 | gap-gamma | B3 | no · inline | none |

## Blocked gaps (each tagged with what it needs)

- none

## Stop control

- **Open gaps — read-only investigable**: 0
- **Open gaps — requires-execution**: 0
- **Open gaps — blocked**: 0

## Campaign queue

campaign_started: 2026-09-23T10:00:00Z
campaign_iterations: 3
last_audit: 2026-09-25T12:00:00Z enqueued=0 partition="units: 5/10 chartered · 5 unchartered · 0 bare-mention (0 glob-chartered)"

| Name | Parent | Kind | Seed | Convergence | State |
|---|---|---|---|---|---|
| root-focus | root | focus | initial | all done | done |
| tier-a | root-focus | tier | tier A | tier done | done |

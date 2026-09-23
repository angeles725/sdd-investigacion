# TestCorpus — Research State

<!-- research-state.v1 -->
schema: research-state.v1
covered_blocks: 2
gaps_closed: 1
known_gaps: 3
investigable_open: 2
requires_execution_open: 0
blocked_open: 0
deferred_open: 0
undocumented_findings: 0
blocks_since_retro: 0
last_iteration_ts: 2026-09-22T14:00:00Z
<!-- /research-state.v1 -->

## Coverage

- **Covered blocks**: 2 (B1..B2)
- **Coverage metric**: 1/3 closed
- **Last iteration**: 2026-09-22 — gap-alpha

## Gap-backlog

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | gap-alpha | web | ✅ cubierto — B1 |
| medium | gap-beta | web | pending |
| low | gap-gamma | web | pending |

## Iteration history

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | 2026-09-20 | gap-alpha | B1 | no · inline | none |

## Blocked gaps (each tagged with what it needs)

- none

## Stop control

- **Open gaps — read-only investigable**: 2
- **Open gaps — requires-execution**: 0
- **Open gaps — blocked**: 0

## Campaign queue

campaign_started: 2026-09-20T08:00:00Z
campaign_iterations: 3
campaign_bounds: max-depth=2 iterations=3 wall-clock=2h
campaign_stop: campaign-bound-reached: iterations=3
last_audit: 2026-09-20T09:00:00Z enqueued=2

| Name | Parent | Kind | Seed | Convergence | State |
|---|---|---|---|---|---|
| root-focus | root | focus | initial investigation | all gaps done | bound-stopped |
| tier-a | root-focus | tier | tier A investigation | tier A done | pending |

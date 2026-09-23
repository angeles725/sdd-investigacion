# TestCorpus — Research State (list edges: first=active, middle=done, last=pending)

<!-- research-state.v1 -->
schema: research-state.v1
covered_blocks: 2
gaps_closed: 2
known_gaps: 3
investigable_open: 1
requires_execution_open: 0
blocked_open: 0
deferred_open: 0
undocumented_findings: 0
blocks_since_retro: 0
last_iteration_ts: 2026-09-23T09:00:00Z
<!-- /research-state.v1 -->

## Coverage

- **Covered blocks**: 2 (B1..B2)
- **Coverage metric**: 2/3 closed
- **Last iteration**: 2026-09-23 — gap-beta

## Gap-backlog

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | gap-alpha | web | ✅ cubierto — B1 |
| medium | gap-beta | web | ✅ cubierto — B2 |
| low | gap-gamma | web | pending |

## Iteration history

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | 2026-09-20 | gap-alpha | B1 | no · inline | none |
| 2 | 2026-09-21 | gap-beta | B2 | no · inline | none |
| 3 | 2026-09-22 | — | — | no · inline | none |

## Blocked gaps (each tagged with what it needs)

- none

## Stop control

- **Open gaps — read-only investigable**: 1
- **Open gaps — requires-execution**: 0
- **Open gaps — blocked**: 0

## Campaign queue

campaign_started: 2026-09-20T10:00:00Z
campaign_iterations: 3
last_audit: 2026-09-22T10:00:00Z enqueued=2

| Name | Parent | Kind | Seed | Convergence | State |
|---|---|---|---|---|---|
| first-entry | root | focus | first | first done | active |
| middle-entry | first-entry | tier | middle | middle done | done |
| last-entry | middle-entry | sub-topic | last | last done | pending |

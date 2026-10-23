# Table Reader Parity — Outline Fixture
> Document-cycle state: nine Outline rows, each a variant of GFM-escaped pipes (`\|`, `\\|`, `\\\|`) in the
> middle and last cells. GitHub renders every one of them as a SINGLE cell, so all nine rows are `covered`.
<!-- research-state.v1 -->
schema: research-state.v1
method: document-cycle
covered_blocks: 0
gaps_closed: 0
known_gaps: 0
investigable_open: 0
requires_execution_open: 0
blocked_open: 0
<!-- /research-state.v1 -->

## Coverage
- **Covered blocks**: 0
- **Coverage metric**: — (blank)

## Outline (the work-list)

| # | Outline item | Genre | Block | Status |
|---|---|---|---|---|
| 1 | item\|a | g | | covered |
| 2 | item\\|a | g | | covered |
| 3 | item\\\|a | g | | covered |
| 4 | i | g\|x | | covered |
| 5 | i | g\\|x | | covered |
| 6 | i | g\\\|x | | covered |
| 7 | i | g | | covered \| x |
| 8 | i | g | | covered \\| x |
| 9 | i | g | | covered \\\| x |

## Gap-backlog

## Iteration history

| # | Date | Item | Block | Delegated | New gaps uncovered |
|---|---|---|---|---|---|

## Blocked gaps

## Stop control

# <SUBJECT> — Research State

> Operational state consumed by the loop (Research-SDD). Mirrored in engram
> (`research/<target>/gaps`, `research/<target>/progress`). Visible and versionable source.

## Coverage

- **Covered blocks**: <N> (B1..B<N>)
- **Coverage metric**: <gaps-closed> / <known-gaps> closed  (a ratio, not a free %)   ← ONE canonical coverage number, OVERWRITE it each iteration. Do NOT accrete contradictory assertions (e.g. `16/16` then `26/26`): if the gap universe grows, reconcile the denominator here to a single value. Per-iteration cumulative snapshots belong in "Iteration history" below, not as repeated coverage-metric lines. (`verify-state.sh` CHECK 3 WARNs on contradictory denominators outside the history table; it flags distinct DENOMINATORS only, so same-denominator drift like `22/16` vs `24/16` is on you to reconcile.)
- **Last iteration**: <YYYY-MM-DD> — <which gap was closed>   ← a SINGLE value, OVERWRITE it each iteration (not an append log; the full log lives in "Iteration history" below)

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | <research question> | <Java/.NET/native/doc/web> | pending |
| medium | <...> | <...> | pending |
| low | <...> | <...> | pending |

## Iteration history

<!-- "New gaps uncovered" (col 6) feeds the saturation signal: research-sdd-status.sh flags SATURATED (review)
     when the last 3 numeric iterations net 0 new gaps — a soft review-prompt complementing §8 STOP. -->

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | <date> | <gap> | B<k> | <no · inline / yes · haiku|sonnet|opus> | <n> |

## Blocked gaps (each tagged with what it needs)

- <gap> — needs: <x64 Dart-AOT decompiler | live server | hardware/lab | NDA | missing tool: <name>>

## Stop control (primary = read-only-investigable exhaustion, METHODOLOGY §8)

- **Open gaps — read-only investigable**: <N>   ← the STATIC loop STOPS when this hits 0
- **Open gaps — requires-execution** (compile/run a PoC, round-trip diff; NOT read-only → build phase): <M>
- **Open gaps — blocked** (needs live system / hardware / keys → DYNAMIC phase §12 when available): <K>
- Consecutive iterations with empty backlog (secondary): <0/2>
- Budget cap (default safety net): <none | max-blocks N | max-tokens>

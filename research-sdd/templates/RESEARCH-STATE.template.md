# <SUBJECT> — Research State

> Operational state consumed by the loop (Research-SDD). Mirrored in engram
> (`research/<target>/gaps`, `research/<target>/progress`). Visible and versionable source.

## Coverage

- **Covered blocks**: <N> (B1..B<N>)
- **Coverage metric**: <gaps-closed> / <known-gaps> closed  (a ratio, not a free %)
- **Last iteration**: <YYYY-MM-DD> — <which gap was closed>

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | <research question> | <Java/.NET/native/doc/web> | pending |
| medium | <...> | <...> | pending |
| low | <...> | <...> | pending |

## Iteration history

| # | Date | Gap closed | Block | New gaps uncovered |
|---|---|---|---|---|
| 1 | <date> | <gap> | B<k> | <n> |

## Blocked gaps (each tagged with what it needs)

- <gap> — needs: <x64 Dart-AOT decompiler | live server | hardware/lab | NDA | missing tool: <name>>

## Stop control (primary = investigable exhaustion, METHODOLOGY §8)

- **Open gaps — investigable**: <N>   ← loop STOPS when this hits 0
- **Open gaps — blocked-on-tooling/server/hardware**: <M>
- Consecutive iterations with empty backlog (secondary): <0/2>
- Budget cap (optional safety net): <none | max-blocks N | max-tokens>

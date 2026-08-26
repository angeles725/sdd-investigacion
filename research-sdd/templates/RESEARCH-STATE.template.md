# <SUBJECT> — Research State

> Operational state consumed by the loop (Research-SDD). Mirrored in engram
> (`research/<target>/gaps`, `research/<target>/progress`). Visible and versionable source.

<!-- State envelope (research-state.v1) — ported from gentle-ai's verify-result/v1. The prose sections below
     are the human-readable MIRROR. Seed/refresh it MECHANICALLY — never hand-edit the ints — with:
       research-sdd-status.sh <corpus> --sync-state
     GATED vs DECLARED — be honest about which is machine-validated:
       • FAIL-gated against ground truth by verify-state.sh (a stale value BLOCKS the loop): covered_blocks
         (block files on disk) · investigable_open (pending non-blocked backlog rows = the STOP-critical
         count) · blocked_open (## Blocked gaps entries). These cannot drift without a hard FAIL.
       • BACKLOG-ANCHORED WHEN MARKED — requires_execution_open (the §19 build-loop STOP counter): mark each
         OPEN build/PoC gap as a backlog row whose Status column carries `requires-execution` (see the example
         row below); verify-state then derives the open count from those rows and FAILs ONLY the premature
         build-STOP hazard (requires_execution_open: 0 while marked-open rows remain — the exact analog of the
         investigable gate). Other divergence is a WARN. A corpus that tracks its build gaps in prose only is
         still valid, but that count is NOT machine-gated — mark the rows to get the gate.
       • DECLARED-only — read from the prose and carried forward, NOT disk-validated: gaps_closed · known_gaps.
         verify-state only cross-checks the coverage ratio for the all-closed-while-pending desync (CHECK D),
         not these absolute values — keep them truthful by hand.
       • MANUALLY-MAINTAINED — undocumented_findings: the researcher increments this when saving a project/
         decision finding to memory (engram) WITHOUT a corresponding block; decrements it when the block is
         written. Nothing in the kit observes memory saves — this is discipline, not automation. Gate behaviour:
         verify-state.sh WARNs when > 3; FAILs when > 6; research-sdd-archive.sh refuses to close when > 0.
         Memory is a MIRROR, not the record. A finding that exists only in memory is undocumented.
       • OPTIONAL — block_scope: controls how verify-state counts on-disk block files for CHECK A.
         Omit for the common case (§16 per-focus prefix layout — each focus has its own block prefix).
         Set to 'shared-global' when ALL focuses in the corpus share ONE block-file prefix (e.g. niagara-
         mental-model-bloque). With shared-global, CHECK A compares covered_blocks against the corpus-wide
         block count, not the focus-filtered count. Legal values: 'per-focus' | 'shared-global'.
         Present but empty, or any other value, is a hard FAIL — absent (omitted) is always legal.
     Field names use UNDERSCORES on purpose: they must never collide with the prose greps below. -->
<!-- research-state.v1 -->
schema: research-state.v1
covered_blocks: 0
gaps_closed: 0
known_gaps: 0
investigable_open: 3
requires_execution_open: 1
blocked_open: 1
deferred_open: 1
undocumented_findings: 0
<!-- /research-state.v1 -->

## Coverage

- **Covered blocks**: <N> (B1..B<N>)
- **Coverage metric**: <gaps-closed> / <known-gaps> closed  (a ratio, not a free %)   ← ONE canonical coverage number, OVERWRITE it each iteration. Do NOT accrete contradictory assertions (e.g. an all-closed ratio, then a larger denominator declared later): if the gap universe grows, reconcile the denominator here to a single value. Per-iteration cumulative snapshots belong in "Iteration history" below, not as repeated coverage-metric lines. NOTE: the placeholder above carries no digits ON PURPOSE — keep it that way until you record a real ratio, so the machine envelope seeds gaps_closed/known_gaps=0 (nothing closed yet) instead of mis-parsing an example number. (`verify-state.sh` CHECK 3 WARNs on contradictory denominators outside the history table; it flags distinct DENOMINATORS only, so same-denominator numerator drift is on you to reconcile.)
- **Last iteration**: <YYYY-MM-DD> — <which gap was closed>   ← a SINGLE value, OVERWRITE it each iteration (not an append log; the full log lives in "Iteration history" below)

## Gap-backlog

<!-- Cell grammar declared in METHODOLOGY §8b. Priority: high | medium | low | deferred | — | ~~tier~~.
     Status leading token: pending (enters investigable_open) | requires-execution | blocked-on-<reason> |
     ✅ | ~~ (closed). Qualifiers in Priority are non-conforming. Heading grammar is closed: ## Gap-backlog, optionally one parenthetical descriptor. -->

<!-- OPEN requires-execution (§19 build/PoC) gaps: keep them as backlog rows whose STATUS column carries
     `requires-execution` (the example row below, modeled on three.js's G41). That marker is what makes the
     envelope's requires_execution_open BACKLOG-ANCHORED — verify-state derives the open count from marked
     rows and catches a premature build-STOP (envelope 0 while marked rows remain). Close one by striking it
     (~~) or flipping Status to `✅ cubierto — B<k>` like any other row. NOTE: this example row is REAL to the
     parsers (an HTML comment would not hide a table row from them), so the placeholder envelope above says
     requires_execution_open: 1 (and the deferred example row likewise seeds deferred_open: 1 — verify-state
     CHECK F would flag a 0 mismatch) — --sync-state re-derives both once you edit the backlog. -->
| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | <research question> | <Java/.NET/native/doc/web> | pending |
| medium | <...> | <...> | pending |
| low | <...> | <...> | pending |
| deferred | <gap set aside — revisit when unblocking condition is met> | <...> | pending (parked; never NEXT — §8b) |
| high | <build/PoC gap — answerable only by compiling/running something> | prototype build | requires-execution → §19 (not read-only; needs a build + re-measure) |

## Iteration history

<!-- "New gaps uncovered" (col 6) feeds the saturation signal: research-sdd-status.sh flags SATURATED (review)
     when the last 3 numeric iterations net 0 new gaps — a soft review-prompt complementing §8 STOP. -->

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | <date> | <gap> | B<k> | <no · inline / yes · haiku|sonnet|opus> | <n> |

## Blocked gaps (each tagged with what it needs)

<!-- Each blocked/absent gap MUST carry both a `needs:` clause AND a `tried:` clause.
     `needs:` names the missing resource. `tried:` lists the alternatives enumerated and the
     measurement that ruled each out. A gap with `tried:` only listing "nothing" is unfinished.
     verify-state.sh checks for the literal token `tried:` the same way it checks `needs:`.
     A gap may not be declared `blocked` or `absent` without both clauses present. -->
- <gap> — needs: <x64 Dart-AOT decompiler | live server | hardware/lab | NDA | missing tool: <name>> · tried: <alt1 (measured: X) | alt2 (measured: Y) | none enumerated yet→ gap still open>

## Stop control (primary = read-only-investigable exhaustion, METHODOLOGY §8)

- **Open gaps — read-only investigable**: <N>   ← the STATIC loop STOPS when this hits 0
- **Open gaps — requires-execution** (compile/run a PoC, round-trip diff; NOT read-only → build phase): <M>
- **Open gaps — blocked** (needs live system / hardware / keys → DYNAMIC phase §12 when available): <K>
- Consecutive iterations with empty backlog (secondary): <0/2>
- Budget cap (default safety net): <none | max-blocks N | max-tokens>

## Dismissed file types

<!-- Populated during BOOTSTRAP after census-target.sh (METHODOLOGY §6 step a2). Every file type starred
     by the census (>= 5 files OR >= 1 MB aggregate) must be either CLAIMED by a backlog gap or listed here
     with a stated reason. A starred type in neither is an unclosed audit hole.
     Format (one line per dismissed type):
       - .<ext> — <N> files · <M> MB — dismissed: <reason>
     Example:
       - .lnk — 312 files · 0.1 MB — dismissed: Windows shell shortcuts, no application data
       - .mdb — 681 files · 450 MB — dismissed: Access databases, out of scope for this focus
     If no types are dismissed (all starred types are covered by gaps), write: none -->

- none

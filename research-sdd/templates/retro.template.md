<!-- review-status: pending -->
<!-- Marker lifecycle: the maintainer flips 'pending' above to 'applied <date> · kit <sha>' once this retro's proposed deltas are reviewed and applied (or 'dismissed') in the kit; sweep-retros.sh reads this marker to report which retros are still open (METHODOLOGY §18). -->
# Retro — <TARGET> · <FOCUS> · <DATE> · Research-SDD self-retrospective

> Run reviewed: <focus / block range, e.g. nmodsreflow B138-B150>. Trigger: <focus-completion | corpus-STOP | every-N-blocks>.
> Method: a FRESH-CONTEXT agent read the current kit (`PROMPT-LOOP.md` + `METHODOLOGY.md`) FIRST, then the
> run's blocks/commits/§14 corrections, and proposes kit deltas. READ-ONLY on the kit — this report only
> PROPOSES; kit changes are human-reviewed and human-committed (METHODOLOGY §18).

## Proposed kit deltas

> Only genuinely NEW items — anything the kit already encodes is listed under "Already covered", not here.
> Each delta: the concrete change · the target file/section · evidence · priority.

| # | Proposed change | Target (file · §/section) | Evidence (block / commit / § / transcript ref) | Type | Priority |
|---|---|---|---|---|---|
| 1 | <codify improvised technique Y> | `METHODOLOGY.md §<n>` | `<B### / commit / §>` | new | HIGH |
| 2 | <add a rule that prevents anti-pattern X> | `PROMPT-LOOP.md <HARD RULE / step>` | `<evidence>` | new | MEDIUM |
| 3 | <refine existing rule Z — scope/condition> | `METHODOLOGY.md §<n>` | `<evidence>` | refinement | LOW |

For each delta above, one line of rationale (WHY it matters, what it costs, expected impact):

- **#1** — <why · impact>
- **#2** — <why · impact>
- **#3** — <why · impact>

## Already covered (dedupe — proof the retro read the kit first)

> Lessons this run surfaced that the kit ALREADY encodes. Listing them proves the dedupe ran and prevents
> re-proposing baked-in rules.

- <lesson> → already covered by `<PROMPT-LOOP rule / METHODOLOGY §n>`.
- <lesson> → already covered by `<...>`.

## Anti-patterns observed (optional)

- <what went wrong / broke / was done against the kit> → the delta above that would prevent it: #<n>.

## Tools built, adapted, or outgrown

> A run that builds, forks, or abandons a tool carries a signal about the kit's fitness. Record every
> tool here — "we wrote a throwaway script" IS a CREATED entry, not nothing; under-reporting is the
> failure mode. Each column is answerable from the corpus and the run's commits alone.
>
> **ORACLE column** — an oracle is a tool that can **SEE** whether a result is correct rather than
> **recompute** it: it observes from the viewer's or consumer's perspective (renders, displays, runs)
> instead of repeating the same arithmetic path that produced the result. Example: a tool that renders
> a 3D model exactly as the viewer will draw it can detect a mirror-flip that passes all 21
> length/area/angle checks — because reflection preserves magnitudes, no symmetric check can see it.
> Generic analysis tools belong in CREATED/ADAPTED, not ORACLE. Oracles are the highest-value promotion
> candidates (METHODOLOGY §18); flag one even when the run did not label it explicitly.
>
> **Why T-prefix in the first column:** the delta counter in `sweep-retros.sh` matches table rows
> whose first cell is a bare integer. Tools rows start at T1, T2 … so the counter cannot confuse
> them with delta rows (both tables start at 1; `sort -un` would otherwise merge them and over-report).

| # | CREATED (path · purpose) | ADAPTED (kit tool · what the kit version could not express) | OUTGREW (kit tool · why stopped) | ORACLE (tool · what it SEEs, not recomputes) | VERDICT (decision · evidence) |
|---|---|---|---|---|---|
| T1 | `nave-panccadia/tools/cad-view.py` · renders DXF regions exactly as AutoCAD draws them | — | — | `cad-view.py` · renders a DXF region as AutoCAD draws it; caught a region AutoCAD clips while every length check passed | `promote` · generic DXF visual oracle; not target-specific; needs test under `toolbelt/tests/` |
| T2 | `niagara-research/tools/gen-catalog.py` · bespoke fork of the kit catalog generator | `$KIT/tools/gen-catalog.py` · silently dropped blocks not in its hard-coded list | kit's gen-catalog.py retired in this target; `archive.sh` already prefers the local fork | — | `absorb` · fold per-target block-type support into the kit version |
| T3 | — | — | — | — | `keep-local` · example: a target-specific parser tuned to one binary's quirks — useful here, not promotable without generalising the format layer |
| T4 | — | — | — | — | `no` · example: a throwaway one-liner written during probing that has no reuse value and is already superseded by the block's findings |

## Metrics

- **Blocks reviewed**: <N>  ·  **§14 cross-block corrections in this run**: <x>  ·  **Rules skipped in practice**: <x>
- **Deltas proposed (new)**: <x>  ·  **Already-covered lessons**: <x>

## Honest verdict

<Did this run genuinely surface anything new for the kit, or does the kit already cover it? Be specific.
If NOTHING new: say exactly that — "no new deltas; the kit already covers this run." A retro that always
finds something is noise, not signal (METHODOLOGY §18 honesty clause).>

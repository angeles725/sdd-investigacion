# <SUBJECT> — Research State (document mode)

> Operational state consumed by the loop (Research-SDD). Mirrored in engram
> (`research/<target>/gaps`, `research/<target>/progress`). Visible and versionable source.

<!-- DOCUMENT-CYCLE VARIANT (kit issue #1114): scaffolded by `research-sdd-init.sh --document`, chosen
     by the PROMPT-LOOP DOCUMENT CYCLE preflight when a NEW target is registered for `document` mode
     (METHODOLOGY §20). Document mode CAPTURES knowledge already in hand — it is OUTLINE-driven and
     NEVER runs gap-discovery (BOOTSTRAP step e / METHODOLOGY §13). The real work-list lives in the
     "## Outline" section below, seeded up front (PROMPT-LOOP DOCUMENT CYCLE step 1) — NOT in
     "## Gap-backlog", which stays present-but-empty on purpose (see that section for why).

     State envelope (research-state.v1) — SAME schema the NORMAL CYCLE uses, so shared kit tooling
     (verify-state.sh, research-sdd-status.sh, research-sdd-archive.sh) reads this file unchanged.
     Seed/refresh it MECHANICALLY — never hand-edit the ints — with:
       research-sdd-status.sh <corpus> --sync-state
     `method: document-cycle` is a DECLARED-only marker (not machine-gated by verify-state.sh; carried
     forward unchanged by --sync-state, same as `block_scope:`) that tells a reviewer or tool this
     corpus is OUTLINE-driven, distinct from `method: document-cycle-external` (METHODOLOGY §20 — a
     corpus authored by a bespoke workflow OUTSIDE this loop entirely). A document-cycle corpus IS
     driven by this loop (PROMPT-LOOP's DOCUMENT CYCLE), just not gap-driven.

     Every count below starts at 0 because "## Gap-backlog" and "## Blocked gaps" start empty — this
     is CONTRACT-VALID from the first scaffold, same design goal as the NORMAL CYCLE template's seeded
     placeholder rows, just with an empty backlog instead of example gaps (document mode has none to
     seed). Field semantics (gated vs declared vs manually-maintained) are UNCHANGED from the NORMAL
     CYCLE template — see that template's header comment for the full per-field breakdown; not
     repeated here to avoid the two copies drifting. -->
<!-- research-state.v1 -->
schema: research-state.v1
method: document-cycle
covered_blocks: 0
gaps_closed: 0
known_gaps: 0
investigable_open: 0
requires_execution_open: 0
blocked_open: 0
deferred_open: 0
undocumented_findings: 0
blocks_since_retro: 0
last_iteration_ts:
<!-- /research-state.v1 -->
<!-- last_iteration_ts is always present — write the ISO-8601 UTC timestamp on every block commit;
     do not pre-fill with a placeholder, update it when committing a block. -->

## Coverage

- **Covered blocks**: <N> (B1..B<N>)
- **Coverage metric**: <outline-items-covered> / <outline-items-total> covered   ← tracks "## Outline" below, NOT a gap ratio — document mode has no gap backlog. Keep the label "Coverage metric" so shared tooling (research-sdd-status.sh) still finds this line; OVERWRITE it each iteration, do not accrete contradictory denominators. The placeholder carries no digits ON PURPOSE — keep it that way until you record a real ratio.
- **Last iteration**: <YYYY-MM-DD> — <which outline item was covered>   ← a SINGLE value, OVERWRITE it each iteration; the full log lives in "Iteration history" below.

## Outline (the work-list — PROMPT-LOOP DOCUMENT CYCLE step 1, METHODOLOGY §20)

<!-- THIS is document mode's work-list, seeded UP FRONT from three sources: (a) what the user already
     knows, (b) their notes, (c) RECONSTRUCTing the steps of the session just lived. There is NO
     discovery here — unlike "## Gap-backlog" below, nothing is added to this table by uncovering
     gaps; it is filled once at BOOTSTRAP/seed time and then worked off. ONE OUTLINE ITEM = ONE BLOCK
     (step 2). Genre decides the evidence base: documenting how the SUBJECT works → ordinary [CERT]
     file:line; documenting a PROCEDURE/how-to → the session itself is the evidence, preserved under
     sources/probes/ and cited [CERT-hw]/[CERT-live] (METHODOLOGY §20, same markers §12 already uses —
     no new marker is introduced). STOP fires when every row below is `covered` (step 7) — the outline
     is the terminator, never gap-exhaustion (contrast the NORMAL CYCLE's "## Stop control" below). -->

| # | Outline item | Genre (subject `[CERT]` \| procedure `[CERT-hw]`/`[CERT-live]`) | Block | Status |
|---|---|---|---|---|
| 1 | <topic or step to document> | <subject \| procedure> | | pending |

## Gap-backlog

<!-- INTENTIONALLY EMPTY — document mode does not use gap-discovery (see "## Outline" above for the
     real work-list; PROMPT-LOOP DOCUMENT CYCLE preflight explicitly skips BOOTSTRAP step e). This
     heading stays PRESENT so verify-state.sh's GB-PRESENT-CHECK is satisfied (absent ≠ empty, kit
     CLAUDE.md §7 anti-silent-zero) and investigable_open/requires_execution_open/deferred_open stay
     honestly 0 via --sync-state. Do NOT seed backlog rows here for a document-cycle corpus — if a real
     read-only gap surfaces mid-run (something worth investigating that is NOT on the outline), that is
     a signal to reconsider whether this run should stay document mode, not a reason to seed this
     table. -->

## Iteration history

| # | Date | Outline item covered | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | <date> | <outline item> | B<k> | <no · inline / yes · haiku\|sonnet\|opus> | none — document mode seeds the full outline up front (§20) |

## Blocked gaps (each tagged with what it needs)

<!-- Document mode CAN still block: a procedure step may be undocumentable without live hardware/access
     that is not available yet (METHODOLOGY §20's LIVE/UNFOLDING and blocked-artifact guidance still
     apply). Each entry MUST carry both a `needs:` clause and a `tried:` clause (same contract as the
     NORMAL CYCLE — verify-state.sh checks for both literal tokens). Empty is the common case; this
     section is not disabled, only unused until a real outline item blocks. -->

## Stop control (document mode — the OUTLINE terminates the run, not gap-exhaustion; METHODOLOGY §20)

- **Outline items total**: <N>   ← from "## Outline" above; seeded once at BOOTSTRAP/seed time, not self-fed
- **Outline items covered**: 0
- **Open gaps — read-only investigable**: 0   ← always 0 in document mode (no gap-discovery backlog — see "## Gap-backlog" above); kept only so this file satisfies the shared research-state.v1 envelope contract other kit tooling reads
- **Open gaps — requires-execution**: 0
- **Open gaps — blocked**: 0
- Consecutive iterations with empty backlog (secondary): n/a — document mode has no gap-exhaustion secondary criterion (the NORMAL CYCLE's §8 2×-empty rule does not apply)
- Budget cap (default safety net): <none | max-blocks N | max-tokens>
- `last_iteration_ts` (ADVISORY — stall-detection signal; written by the loop on each block commit; lives in the research-state.v1 envelope above — do not pre-fill; update it when committing a block)

## Dismissed file types

<!-- Populated during BOOTSTRAP step a2 (census-target.sh) exactly as the NORMAL CYCLE does — the
     document-cycle preflight still runs step a2. Every file type starred by the census (>= 5 files OR
     >= 1 MB aggregate) must be either covered by an "## Outline" item or dismissed here with a stated
     reason. Format: `- .<ext> — <N> files · <M> MB — dismissed: <reason>`. If no types are dismissed,
     write: none -->

- none

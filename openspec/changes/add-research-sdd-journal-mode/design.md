# Design: Research-SDD Journal Mode (instant capture → §18 consolidate)

## Technical Approach

The proposal's gap is not a missing STORE — it is a missing LINK: §18 re-authors
its `## Proposed kit deltas` from memory at the terminal, instead of consolidating
the in-the-moment captures the loop already makes via Engram `mem_save`. This design
therefore adds ZERO tooling. It prescribes, doctrine-first (CLAUDE.md §6), a
per-entry JOURNAL convention layered over existing Engram capture, and adds journal
consolidation to §18 (METHODOLOGY §18 + PROMPT-LOOP TERMINAL TRIGGER) as a
SUPPLEMENTAL SOURCE alongside the existing run review. §18 is RETAINED unchanged as
the promotion gate and honesty clause. No target corpus is mutated (propose-never-apply,
METHODOLOGY §13/§18).

**Engram upsert contract (FABLE B1 correction):** `mem_save` with a fixed `topic_key`
REPLACES the previous observation under that key. The journal therefore uses a UNIQUE
`topic_key` per entry (`research/<target>/journal/<YYYY-MM-DD>-<HHMMSS>`, UTC timestamp —
unique across sessions and parallel focus lanes), not a shared key.
Retrieval at §18 uses `mem_search(query: "research/<target>/journal", project: "<target>",
limit: 20)` — an FTS5 phrase match over all indexed columns, NOT a topic_key prefix scan.
`project: "<target>"` is required (omitting it resolves from cwd, yielding zero hits in
the kit directory). `limit: 20` is required (default is 10). Session scoping is by date
phrase (`"research/<target>/journal/<YYYY-MM-DD>"`). topic_key is not exposed in
mem_search output; filter by title convention `<YYYY-MM-DD> <category>:` to drop
overmatches. Truncation handling is required — returning 10 (default cap) or 20 of 25
entries is a false-negative (CLAUDE.md §7).

## Architecture Decisions

### Decision: Capture substrate — per-entry Engram observations, NOT a parallel store

| Option | Tradeoff | Decision |
|---|---|---|
| New dedicated capture command / journal file | Duplicates a substrate that already captures insights at the moment they surface; new instrument to test, gate, keep three-state honest (CLAUDE.md §7) | **Reject (until measured)** |
| Separate append-only `journal.md` per loop | Parallel store drifts from Engram; two truths (§18 tools-table lesson) | Reject |
| **Per-entry Engram observations under a unique `topic_key` convention** | Zero new code; rides the proactive-save rule the loop already runs; §18 reads the set back with `mem_search` FTS phrase query | **Choose** |

**Convention**: each mid-loop insight is saved as a separate `mem_save` call under a
unique key `research/<target>/journal/<YYYY-MM-DD>-<HHMMSS>` (UTC timestamp; for a
multi-focus target use `research/<target>/<focus>/journal/<YYYY-MM-DD>-<HHMMSS>` per the
§16 Engram project convention). Category ∈
`{improvement, defect, tool-idea, algorithm-idea, formula-idea}`. Type ∈
`bugfix | discovery | pattern` — `decision` is excluded (METHODOLOGY §7:
`type: decision` increments `undocumented_findings`, which `research-sdd-archive.sh`
enforces; kit insights have no corpus block by design). One insight = one observation.

**Measure-before-build (CLAUDE.md §6)**: build a command ONLY if a run measures a
concrete gap the convention cannot cover — e.g. the limit-20 cap causes silent
truncation in real runs, or `mem_save` is provably skipped in practice. Until an
incidence is measured, the zero-tooling convention is preferred (CLAUDE.md §7: a valid
rule with zero measured incidence buys no backlog item). Record in the run's retro.

### Decision: §18 consolidation mechanism — journal supplements run review

| Concern | Mechanism |
|---|---|
| Journal as supplement | The existing run review (blocks, §14, rules skipped, improvised techniques) STILL RUNS; journal provides additional candidates |
| Retrieval scope | `mem_search(query: "research/<target>/journal/<YYYY-MM-DD>", project: "<target>", limit: 20)` — FTS phrase match for that run date; pass project and limit explicitly; filter by title convention `<YYYY-MM-DD> <category>:` to drop FTS overmatches |
| Limit-20 truncation | If result count = 20, retro agent flags possible truncation; paging via narrower prefix if needed |
| Dedup across §18 firings | §18 fires multiple times per session; entries already promoted in a prior firing are skipped |
| Dedup near-duplicates | Retro agent collapses entries describing the same insight into one candidate |
| Nothing auto-promotes | §18 stays a human/gate filter: the retro agent PROPOSES rows; maintainer reviews/applies (`review-status: pending` → `applied|dismissed`). propose-never-apply (METHODOLOGY §13/§18) is unchanged |
| Honesty preserved | A run with no retrievable journal entries still fires §18 and records the state explicitly (three-state: search-returned-nothing / nothing-captured / possibly-truncated) |

§18's `sweep-retros.sh` countability contract (canonical `## Proposed kit deltas` table,
`review-status` marker) is UNTOUCHED — this change adds journal as a supplemental
source, it does not alter the retro's output shape.

### Decision: Doctrine-first, zero-tooling ordering (CLAUDE.md §6)

Prescribe (1) the journal entry format + unique-key discipline and (2) the §18
consolidate/dedup discipline in prose FIRST. A convention with no checker is preferable
while it buys the outcome; a parser over free-form insight prose would inherit that
prose's ambiguity (substrate-has-no-schema lesson). Any future checker is built against
the declared convention, not reverse-engineered from entries.

## Data Flow

    mid-loop insight ──→ mem_save(topic_key: research/<target>/journal/<YYYY-MM-DD>-<HHMMSS>)
                              │  (unique key per entry, at the moment it surfaces)
                              ▼
    TERMINAL TRIGGER ──→ §18 retro agent:
                              │  step 1: read kit FIRST (dedup against existing rules)
                              │  step 2: review the run (blocks / §14 / skipped rules / improvised)
                              │  step 3: mem_search("research/<target>/journal/<YYYY-MM-DD>",
                              │          project: "<target>", limit: 20)
                              │          → check for truncation → dedup across firings
                              │          → dedup near-duplicates → curate
                              │  step 4: merge + promote to ## Proposed kit deltas
                              ▼
                     `## Proposed kit deltas` table (retro.md) → human review (METHODOLOGY §13/§18)

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `research-sdd/METHODOLOGY.md` (§18) | Modify | Add journal mode sub-section: per-entry unique-key convention, limit-20 handling, type carve-out, supplement-not-replace consolidation, three-state absent-journal handling, open questions |
| `research-sdd/PROMPT-LOOP.md` | Modify | Add INSTANT CAPTURE HARD RULE (unique key, no `decision` type); update SELF-RETROSPECTIVE to describe journal as supplemental source alongside run review |
| `research-sdd/templates/retro.template.md` | Modify | HTML comment cross-reference to journal mode; visible source note moved out of template prose |

## Interfaces / Contracts

Journal entry (Engram `mem_save`), no new API:

    topic_key:  research/<target>/journal/<YYYY-MM-DD>-<HHMMSS>  (UTC timestamp; unique per entry across sessions/lanes; multi-focus: research/<target>/<focus>/journal/...)
    project:    <target>                                     (required; omit session_id — Engram resolves automatically)
    type:       bugfix | discovery | pattern                 (NOT "decision" — see type carve-out)
    title:      <YYYY-MM-DD> <category>: <insight>           (category ∈ improvement/defect/tool-idea/algorithm-idea/formula-idea)
    content:    <one-line description> — evidence: <block/§/ref>

Note on session_id: omit it from mem_save journal calls. Engram's resolveFallbackSessionID
attaches the target project's active session automatically. Passing the harness session_id
causes session_project_mismatch because the harness session belongs to the orchestrator
project, not <target>.

Retrieval: `mem_search(query: "research/<target>/journal", project: "<target>", limit: 20)`
or date-scoped `query: "research/<target>/journal/<YYYY-MM-DD>", project: "<target>",
limit: 20`. FTS phrase match, not a topic_key prefix scan; filter by title convention
`<YYYY-MM-DD> <category>:` to drop FTS overmatches (topic_key not exposed in output).
Default limit is 10 — always pass `limit: 20` explicitly. Flag if count equals 20
(possible truncation); page with narrower queries or multiple calls.

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Doctrine | §18/PROMPT-LOOP wording matches (doc↔doc readback) | Manual cross-read; no code |
| Instrument | none this change (zero tooling) | If a command is later built, it gets a `*.test.sh` with mutation controls (CLAUDE.md §4/§5) |

## Threat Matrix

N/A — this change introduces no routing, shell, subprocess, VCS/PR automation,
executable-file classification, or process-integration boundary. It is doctrine plus an
Engram save convention. If the conditional capture command is later built (only after
measurement), it re-enters this matrix as a subprocess/argv boundary at that time.

## Migration / Rollout

No migration. Doctrine edits are text-only and additive; revert the merge commit to roll
back. §18 reverts to prior blind-recall wording independently. No corpus data mutated.

## Relationship to adjacent changes (cross-reference, kept distinct)

- **Retro-flow redesign (markers → GitHub issues)**: a separate future change. This change
  feeds that future redesign better source material (the journal); it does not change
  routing or the retro output shape.
- **Capability-proposal template slot** (new tool/algorithm/formula + measurement criterion):
  a future enhancement; out of scope here. The journal's per-entry `category` tag is the
  data that will later populate it. This design does not reference it as belonging to any
  specific openspec change — the ownership is unresolved at this time.

## Open Questions

- [ ] Date-prefix scoping: a run spanning midnight requires a broader query or two prefix
  calls (`journal/<YYYY-MM-DD-1>` and `journal/<YYYY-MM-DD-2>`). Until a run measures this
  as a concrete gap, the per-date prefix is preferred.
- [ ] Limit-20 paging: a run capturing more than 20 insights per day requires iterative
  paging. The convention currently specifies to flag truncation; paging mechanics are
  deferred until a run measures this gap.
- [ ] Retro agent context inflation: can the retro agent query the journal prefix within
  its fresh context without inflating it beyond useful range? Measure before adding tooling.

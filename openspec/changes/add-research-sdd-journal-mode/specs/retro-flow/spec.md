# Delta for retro-flow

## ADDED Requirements

### Requirement: Consolidate-Curate Mode (journal as supplement)

§18 MUST consolidate session journal entries as a SUPPLEMENTAL SOURCE alongside the existing run
review. The existing run review (blocks written, §14 corrections, rules skipped, improvised
techniques) MUST still run. Blind end-of-loop recall MUST NOT be the sole mechanism when a session
journal is present.

(Related: the `journal-capture` spec governs what a valid journal entry is and the unique-key
substrate contract. Out of scope here: the retro-template capability-proposal slot, which is a
future enhancement.)

#### Scenario: Journal present at terminal trigger

- GIVEN a session journal with one or more entries
- WHEN the TERMINAL TRIGGER fires §18
- THEN §18 reads the journal via `mem_search` prefix query, runs the existing run review, and merges both sources into `## Proposed kit deltas` candidates

#### Scenario: No journal at terminal trigger

- GIVEN a session with no journal entries
- WHEN the TERMINAL TRIGGER fires §18
- THEN §18 explicitly records the absence (one of: search-returned-nothing / nothing-captured) and continues with the full run review; it does not silently pass; if result count equals the limit (20) it records possibly-truncated — this is a DISTINCT state from absence (entries were returned, they may be incomplete)

### Requirement: Deduplication

§18 MUST dedup journal entries before promoting any to deltas. A single insight recorded more than
once across the session MUST produce at most one promoted delta. Entries already promoted in a prior
§18 firing within the same session MUST be skipped (cross-firing dedup).

#### Scenario: Duplicate entries collapsed

- GIVEN two journal entries describing the same insight captured at different moments
- WHEN §18 runs dedup
- THEN at most one delta is promoted from that insight

#### Scenario: Cross-firing dedup

- GIVEN an entry already promoted in an earlier §18 firing within the same session
- WHEN a later §18 firing reads the journal
- THEN the already-promoted entry is skipped; it is not re-promoted

#### Scenario: Single unique entry passes through

- GIVEN one journal entry with no duplicate and not yet promoted
- WHEN §18 runs dedup
- THEN the entry is eligible for promotion without modification

### Requirement: Promotion Gate

§18 MUST remain the gate that decides which journal entries become deltas. Nothing auto-promotes.
An entry is promoted only by explicit curation at the §18 step.

#### Scenario: No entry auto-promotes

- GIVEN a session journal with entries
- WHEN the loop ends without an explicit §18 curation pass
- THEN no delta is created from any journal entry

#### Scenario: Explicit curation promotes an entry

- GIVEN a journal entry deemed worthwhile during §18 curation
- WHEN the researcher explicitly promotes it
- THEN it becomes a delta in the retro output

### Requirement: Terminal Retro Retained

§18 MUST be retained as the mandatory terminal step. The journal supplements recall; it does not
replace the §18 gate. §18 MUST fire at every TERMINAL TRIGGER even when the journal is empty.

#### Scenario: §18 fires on every loop end

- GIVEN a completed research loop, with or without journal entries
- WHEN the TERMINAL TRIGGER fires
- THEN §18 runs as a mandatory terminal step

#### Scenario: Journal-absent run still produces a §18 record

- GIVEN a session with no journal entries
- WHEN §18 completes
- THEN a retro record is produced that notes the absence state (search-returned-nothing or nothing-captured), not an empty or silent pass; possibly-truncated is a DISTINCT partial-retrieval state (mem_search returned entries but count equals limit), not an absence state

### Requirement: Limit-20 Acknowledgement

The retro agent MUST pass `limit: 20` explicitly on all `mem_search` retrieval calls — the default
limit is 10, not 20; calling without a limit silently caps results at 10. If the result count
equals `limit` (20), the retro agent MUST flag possible truncation in the retro and MUST NOT
treat the 20 results as the complete set.

#### Scenario: Result count equals 20

- GIVEN `mem_search(query: ..., project: "<target>", limit: 20)` returns exactly 20 journal entries
- WHEN §18 processes the results
- THEN the retro explicitly notes "possible truncation — result count hit the explicit limit-20 cap"; the agent MUST NOT treat 20 results as the complete set and MUST consider narrower queries or additional calls

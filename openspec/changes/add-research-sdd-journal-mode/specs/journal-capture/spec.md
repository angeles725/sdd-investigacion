# journal-capture Specification

## Purpose

Governs the per-entry, mid-loop instant-capture journal for research-sdd loop insights. Defines entry
format, capture discipline, substrate requirements (including the Engram upsert contract), and the
measure-before-build constraint on tooling.

## Requirements

### Requirement: Entry Format

A journal entry MUST be a single line of substance. It MUST carry a category tag and a short
description. Entries MUST be written in English (CLAUDE.md §9). Multi-line prose is not a valid
journal entry.

The date is embedded in the `topic_key` (`research/<target>/journal/<YYYY-MM-DD>-<HHMMSS>`, UTC timestamp) and SHOULD
also appear in the title for human readability.

#### Scenario: Valid entry recorded

- GIVEN a researcher captures an insight mid-loop
- WHEN the entry is written
- THEN the `mem_save` call uses a unique `topic_key` of the form `research/<target>/journal/<YYYY-MM-DD>-<HHMMSS>` (UTC timestamp), carries a category tag (one of: improvement / defect / tool-idea / algorithm-idea / formula-idea), a description, and is in English

#### Scenario: Non-conforming entry flagged at consolidation

- GIVEN a journal containing an entry with no category tag or with multi-line content
- WHEN §18 consolidation reads the journal
- THEN the non-conforming entry is flagged explicitly and not silently promoted

### Requirement: Instant Capture Discipline

Insights MUST be captured the moment they surface, not deferred to the terminal retro. A mid-loop
insight recalled only at the terminal is out of spec.

#### Scenario: Capture happens at insight moment

- GIVEN a defect or capability idea surfaces during a loop step
- WHEN the researcher applies the journal discipline
- THEN a `mem_save` entry is written before the loop continues

#### Scenario: Terminal-only recall is not compliant

- GIVEN a researcher did not journal mid-loop
- WHEN §18 operates as blind end-of-loop recall instead of consolidating a journal
- THEN the retro does not satisfy the consolidate/curate requirement

### Requirement: Substrate Justification (Engram unique-key per entry)

The capture mechanism MUST use Engram `mem_save` with a UNIQUE `topic_key` per entry. Engram
`mem_save` with a fixed `topic_key` is an UPSERT that replaces the previous observation under
that key — a shared key would overwrite all prior entries. The `topic_key` MUST follow the
pattern `research/<target>/journal/<YYYY-MM-DD>-<HHMMSS>` (UTC timestamp — unique across
sessions and parallel focus lanes; for a multi-focus target,
`research/<target>/<focus>/journal/<YYYY-MM-DD>-<HHMMSS>` per the §16 Engram project
convention). Omit
`session_id` from capture calls — Engram's resolveFallbackSessionID attaches the target
project's active session automatically; passing the harness session_id causes
session_project_mismatch. Retrieval at §18 MUST use `mem_search` with FTS phrase match (NOT a
topic_key prefix scan): `mem_search(query: "research/<target>/journal", project: "<target>",
limit: 20)`. `project: "<target>"` MUST be passed explicitly (omitting it resolves from cwd,
yielding zero hits in the kit directory). `limit: 20` MUST be passed explicitly (default is
10). Because topic_key is not exposed in mem_search output, results MUST be filtered by title
convention `<YYYY-MM-DD> <category>:` to drop FTS overmatches. If the result count equals 20,
the retro agent MUST flag possible truncation. A dedicated capture command is built ONLY when
measurement shows the convention cannot cover the need.

#### Scenario: Engram reuse with unique-key evaluated first

- GIVEN a proposal to build a dedicated capture command
- WHEN the decision is made
- THEN recorded evidence shows the Engram unique-key convention was measured and found insufficient before the command is built

#### Scenario: Zero-tooling path accepted when sufficient

- GIVEN measurement shows the Engram `mem_save` convention covers the capture need
- WHEN the design is finalized
- THEN no dedicated capture command is built

#### Scenario: Shared topic_key rejected

- GIVEN a `mem_save` call that uses `topic_key: "research/<target>/journal"` (fixed, shared)
- WHEN this pattern is used for more than one entry
- THEN all but the last entry are overwritten — this violates the append-one-insight requirement

### Requirement: Category Taxonomy

Every entry MUST carry exactly one category from the set:
`improvement`, `defect`, `tool-idea`, `algorithm-idea`, `formula-idea`.
Entries with an unrecognized or absent category MUST be flagged at §18 consolidation and MUST NOT
be silently promoted.

#### Scenario: Unknown category flagged

- GIVEN an entry whose category tag is absent or not in the defined set
- WHEN §18 reads the journal
- THEN the entry is flagged as non-conforming; it is not promoted unless the researcher fixes the tag

#### Scenario: Valid category passes through

- GIVEN an entry with a recognized category tag
- WHEN §18 reads the journal
- THEN the entry is eligible for curation and possible promotion

### Requirement: English Artifacts

All journal entries and journal-related output MUST be in English (CLAUDE.md §9 language contract).
Non-English content MUST be flagged at consolidation.

#### Scenario: Non-English entry flagged

- GIVEN a journal entry written in a language other than English
- WHEN §18 consolidation runs
- THEN the entry is flagged; it is not auto-translated or silently promoted

### Requirement: Type Carve-Out

Journal entries MUST use `type: bugfix | discovery | pattern`. They MUST NOT use `type: decision`
or `type: project`. The `type: decision` and `type: project` values both trigger
`undocumented_findings` tracking (METHODOLOGY §7 / PROMPT-LOOP MEMORY IS A MIRROR rule), which
`research-sdd-archive.sh` enforces. Kit insights in the journal have no corpus block by design;
using `bugfix | discovery | pattern` avoids triggering the counter for either type.

#### Scenario: type: decision rejected for journal entries

- GIVEN a researcher attempts to save a journal entry with `type: decision`
- WHEN §18 or the instant-capture doctrine is applied
- THEN the entry uses `type: bugfix`, `type: discovery`, or `type: pattern` instead; `decision` is not used for journal entries

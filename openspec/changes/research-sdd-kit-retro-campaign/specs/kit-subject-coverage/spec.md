# kit-subject-coverage Specification

## Purpose

The kit MUST provide a metric for coverage over the research subject — which subject modules or units
have never been cited in any block — distinct from "gaps closed / known gaps". METHODOLOGY.md §8 MUST
document this metric as a valid AUDIT-FIRST gap-seeding source.

## Requirements

### Requirement: coverage-map.sh Instrument

A new instrument `coverage-map.sh` MUST compute which subject modules have never been cited in any
block in the corpus and MUST report the uncited count and list. It MUST be registered in
`tool-registry.md`. It MUST distinguish absent input, empty corpus (no blocks), and zero uncited
modules as three separate states. It MUST run on at least two real targets (niagara-research and
panccadia-3d-viewer) with acceptance against the real fleet, never fixtures alone.

#### Scenario: Uncited module count reproduced on real corpus

- GIVEN the niagara-research corpus (763 blocks, 318 top-level modules)
- WHEN `coverage-map.sh` is run against niagara-research
- THEN the output reports 148 uncited modules (or names any deviation with measured evidence)

#### Scenario: Three-state honesty — absent corpus path

- GIVEN a corpus path that does not exist
- WHEN `coverage-map.sh` is invoked
- THEN it exits non-zero and prints a typed absent-input indication
- AND does NOT print `0 uncited modules` as though it ran successfully

#### Scenario: Fleet acceptance — two real targets

- GIVEN coverage-map.sh run against niagara-research and panccadia-3d-viewer on the real fleet
- WHEN both runs complete on a quiet tree
- THEN every module listed as uncited is verifiably not cited in any block file in that corpus
- AND the tool-registry.md row for coverage-map.sh is present

#### Scenario: Mutation — bypass produces wrong count

- GIVEN a mutant that hardcodes uncited-module count to 0
- WHEN the companion test suite runs under `--prove-teeth`
- THEN the suite exits non-zero

### Requirement: verify-state.sh shared-global covered_blocks Semantics

Under `block_scope: shared-global`, `verify-state.sh` MUST compute `covered_blocks` as the count
of blocks attributed to the focus, not the corpus total. The corpus total MUST be reported on a
separate INFO line. After the fix, the 6/6 sampled niagara-research focuses that currently FAIL
(`covered_blocks=19 != 758`) MUST no longer FAIL. Non-shared-global targets MUST be unaffected.

Attribution source, in order (issue #423, doctrine PR #427): a `## Covered blocks` list in the focus state
when present; otherwise the distinct `B<n>` ids in the focus's own `## Iteration history` Block column. When
neither yields an id, CHECK A MUST print the INFO line
`covered_blocks unverifiable under shared-global (no attributed block ids listed)` and MUST NOT FAIL.
The corpus-total INFO line MUST read `corpus total N (shared-global, informational)`. `--sync-state` MUST
write the attributed count, never the corpus total. A focus whose envelope disagrees with its own listed
ids remains a FAIL (true finding).

#### Scenario: Shared-global focus stops FAILing

- GIVEN a focus with `block_scope: shared-global` and 19 blocks attributed to it in a corpus of 758
- WHEN `verify-state.sh` runs after the fix
- THEN covered_blocks is reported as 19 (blocks attributed to this focus), not 758
- AND no FAIL is emitted for covered_blocks mismatch

#### Scenario: INFO line present with corpus total

- GIVEN the same shared-global focus
- WHEN `verify-state.sh` runs
- THEN an INFO line appears reporting the corpus total (758) and the shared-global note

#### Scenario: Non-shared target unchanged

- GIVEN a focus with no `block_scope: shared-global` declaration
- WHEN `verify-state.sh` runs
- THEN its covered_blocks computation and output are byte-identical to the pre-fix behavior

### Requirement: D6 — §8 Coverage Metric in Doctrine

METHODOLOGY.md §8 MUST include a paragraph naming "coverage over the subject" — the proportion of
subject modules never cited in any block — as a distinct metric from "gaps closed / known gaps".
The paragraph MUST name this metric as a valid AUDIT-FIRST gap-seeding source. §18 MUST state
that a machine-countable delta declaration is mandatory (shared with kit-doctrine-grammar).
§4 MUST include the `Type:` grammar line (shared with kit-doctrine-grammar).

#### Scenario: §8 coverage-over-the-subject paragraph present

- GIVEN METHODOLOGY.md §8
- WHEN a structural readback reads the section
- THEN it finds a paragraph naming "coverage over the subject" as a distinct metric
- AND the paragraph identifies it as a valid AUDIT-FIRST gap-seeding source

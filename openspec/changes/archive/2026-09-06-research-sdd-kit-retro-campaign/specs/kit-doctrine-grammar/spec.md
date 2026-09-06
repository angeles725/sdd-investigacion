# kit-doctrine-grammar Specification

## Purpose

Every token or state that an instrument must read MUST be declared as a closed vocabulary in doctrine
BEFORE any checker reads it. This capability covers four grammars: block `Type`, FOCUSES status,
machine-countable delta declaration, and New-gaps cell. It also covers the marker-taxonomy decision
(D5) and the PROMPT-LOOP SYNTHESIS-GUIDE and SECRETS patterns (D3).

## Requirements

### Requirement: FOCUSES Status Closed Grammar (§16 METHODOLOGY.md)

METHODOLOGY.md §16 MUST state a closed four-word vocabulary for FOCUSES.md status cells:
`active`, `paused`, `stopped`, `planned`. Any value outside this set is non-conforming and
MUST be classifiable by a downstream checker without prose heuristics.

#### Scenario: Four-word vocabulary stated in §16

- GIVEN METHODOLOGY.md §16
- WHEN a structural readback reads the section
- THEN it finds exactly the four tokens `active`, `paused`, `stopped`, `planned` declared as the
  closed status vocabulary

#### Scenario: verify-doc-consistency clean after update

- GIVEN the updated METHODOLOGY.md containing the §16 grammar
- WHEN `verify-doc-consistency.sh` runs on a quiet tree
- THEN the exit code is 0

### Requirement: Block Type Closed Grammar (§4 METHODOLOGY.md and block.template.md)

METHODOLOGY.md §4 MUST define a closed vocabulary for the block `Type:` field. `block.template.md`
MUST include a `Type:` line with the domain listed. `verify-block.sh` MUST parse the declared
`Type:` token and MUST emit a WARN for values outside the closed domain. Blocks declaring a Type
from the synthesis/capture/absence-centred subset MUST have their ZERO-citations diagnostic
downgraded from WARN to INFO.

#### Scenario: §4 and template declare the same domain

- GIVEN METHODOLOGY.md §4 and block.template.md
- WHEN a structural readback reads both files
- THEN both name the same closed set of valid `Type:` values

#### Scenario: Out-of-domain Type value produces WARN

- GIVEN a block file declaring `Type: unknown-value`
- WHEN `verify-block.sh` runs against it
- THEN a WARN is emitted naming the unrecognised token

#### Scenario: Synthesis-type block ZERO-citation diagnostic is INFO not WARN

- GIVEN a block declaring `Type: synthesis` with zero citations
- WHEN `verify-block.sh` runs against it
- THEN the zero-citation diagnostic is emitted at INFO level, not WARN

#### Scenario: Mutation — Type parser bypass goes red

- GIVEN a mutant `verify-block.sh` that skips Type parsing entirely
- WHEN a block with an out-of-domain `Type:` value is verified under `--prove-teeth`
- THEN the test suite exits non-zero

### Requirement: Machine-Countable Delta Declaration (§18 METHODOLOGY.md and retro.template.md)

METHODOLOGY.md §18 MUST state that a machine-countable delta declaration is MANDATORY in every retro,
and MUST extend the retro trigger to applied sessions and post-close addenda. `retro.template.md`
MUST include the canonical delta-section heading. The set of headings `sweep-retros.sh` recognises
MUST be the exact enumerated set from the fleet measurement — no open-ended regex permitted.

#### Scenario: §18 states mandatory machine-countable declaration

- GIVEN METHODOLOGY.md §18
- WHEN a structural readback reads the section
- THEN the text states that a machine-countable delta declaration is mandatory
- AND the text extends the retro trigger to applied sessions and post-close addenda

#### Scenario: retro.template.md contains canonical heading

- GIVEN retro.template.md after the update
- WHEN the file is read
- THEN it contains the canonical delta-section heading that sweep-retros.sh recognises

### Requirement: New-Gaps Cell Grammar in RESEARCH-STATE Template

`RESEARCH-STATE.template.md` MUST include a grammar sentence for the New-gaps cell that specifies
the required format for unambiguous machine counting by `research-sdd-status.sh`.

#### Scenario: Grammar sentence present in template

- GIVEN RESEARCH-STATE.template.md after the update
- WHEN the file is read
- THEN the New-gaps cell row contains a grammar sentence specifying the required format

### Requirement: D3 — PROMPT-LOOP SYNTHESIS-GUIDE and SECRETS Patterns

PROMPT-LOOP.md MUST name the SYNTHESIS-GUIDE FOCUS pattern and its PAIR form as a named,
reusable pattern. PROMPT-LOOP.md MUST include a SECRETS cluster stating that a raw disk image
is itself secret-bearing, that secrets-sensitive artifacts MUST be handled inline rather than
delegated, and that redacted-file mask verification is required.

#### Scenario: SYNTHESIS-GUIDE FOCUS pattern named in PROMPT-LOOP

- GIVEN PROMPT-LOOP.md
- WHEN a structural readback reads the file
- THEN it finds a named SYNTHESIS-GUIDE FOCUS pattern and a PAIR form described

#### Scenario: SECRETS cluster present with inline-over-delegate rule

- GIVEN PROMPT-LOOP.md
- WHEN a structural readback reads the SECRETS section
- THEN it contains the rule that secrets-sensitive artifacts MUST be handled inline, not delegated

### Requirement: D5 — §3 Evidence-Marker Taxonomy Decision

METHODOLOGY.md §3 MUST state the closed decision on marker taxonomy: `[CERT-a]` means secondary
source (not agent-gathered citation); an agent-gathered citation carries no marker until
source-verified and then becomes `[CERT]`; coordination notes are not evidence and route to
sources/notes; `[CERT-live]` means a running remote service; `[CERT-hw]` means a physical device
or offline media image the researcher holds.

#### Scenario: Five marker-taxonomy rules stated in §3

- GIVEN METHODOLOGY.md §3
- WHEN a structural readback reads the section
- THEN it finds explicit definitions for `[CERT-a]`, unverified agent-gathered citations,
  coordination notes, `[CERT-live]`, and `[CERT-hw]`

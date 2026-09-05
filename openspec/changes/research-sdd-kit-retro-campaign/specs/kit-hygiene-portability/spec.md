# kit-hygiene-portability Specification

## Purpose

Block-file discrimination MUST be centralised in a single `lib/block-files.sh` helper. Installed-skill
drift MUST be detectable by an instrument without becoming a new SessionStart hook. Exec bits,
`.gitignore` entries, and path resolution in copied artifacts MUST be correct. Retro-marker parsing
MUST route through the declared single source of truth (`lib/retro-status.sh`).

## Requirements

### Requirement: lib/block-files.sh Centralised Discriminator

A new `lib/block-files.sh` MUST export a single `block_files()` function. All 15 call sites across
8 scripts MUST route through it. `research-sdd-archive.sh:284` MUST route retro-marker parsing
through `lib/retro-status.sh`, not its own hand-rolled `head | grep` pattern. Before and after the
extraction, instrument output on real corpora MUST be byte-identical.

#### Scenario: Byte-identical output before and after extraction

- GIVEN any of the 8 scripts before and after the lib/block-files.sh extraction
- WHEN both versions are run against the niagara-research real corpus
- THEN the outputs are byte-identical (diff is empty)

#### Scenario: Single definition — no hand-rolled duplicates remain

- GIVEN the updated toolbelt after U11
- WHEN all scripts are checked for inline block-file discrimination patterns
- THEN exactly one definition exists (in lib/block-files.sh)
- AND all call sites import the helper rather than hand-rolling the pattern

#### Scenario: archive retro-marker parser routes through lib/retro-status.sh

- GIVEN research-sdd-archive.sh after U11
- WHEN the file is read
- THEN it does NOT contain a hand-rolled `head -10 | grep '^review-status:'` pattern
- AND it calls lib/retro-status.sh for retro-marker parsing

### Requirement: Installed-Skill Drift Detection (U10)

An instrument (suite or standalone check) MUST compare the kit `SKILL.md` against the installed copy
at `~/.claude/skills/research-sdd/SKILL.md` and report drift by hunk count. An absent installed
copy MUST be reported as a distinct absent-input state, NOT as zero drift. This instrument MUST NOT
be wired as a new SessionStart hook.

#### Scenario: Stale installed copy reported by hunk count

- GIVEN the installed SKILL.md differs from the kit copy in 5 hunks / 15 lines
- WHEN the drift instrument runs
- THEN it reports 5 hunks of drift
- AND does NOT exit 0 silently

#### Scenario: Absent installed copy reported as absent-input, not zero

- GIVEN the path `~/.claude/skills/research-sdd/SKILL.md` does not exist
- WHEN the drift instrument runs
- THEN it prints a typed absent-input indication
- AND does NOT report `0 hunks` of drift

#### Scenario: Instrument is not a SessionStart hook

- GIVEN `.claude/settings.json`
- WHEN the file is read
- THEN the drift instrument is not listed as a SessionStart hook

### Requirement: Hygiene Bundle Correctness (U9)

`.gitignore` MUST include `.claude/worktrees/`. The three counters in `verify-kit-clean.sh:30-32`
MUST be covered by companion tests that assert the counter values. `verify-doc-consistency.sh`
MUST be committed with executable permission (100755). `templates/hook-sessionstart.sh` MUST
resolve its toolbelt path from `$RESEARCH_SDD_KIT` or from the script's own location, NOT from
a hardcoded absolute path.

#### Scenario: .gitignore covers the worktrees directory

- GIVEN `.gitignore` after U9
- WHEN `.claude/worktrees/` exists in the working tree
- THEN `git status` does NOT list it as an untracked file

#### Scenario: Hardcoded absolute path absent from hook template

- GIVEN templates/hook-sessionstart.sh after U9
- WHEN the file is read
- THEN no hardcoded absolute path containing a user home directory is present

#### Scenario: verify-doc-consistency.sh is executable

- GIVEN the repository after U9
- WHEN `git ls-files --stage verify-doc-consistency.sh` is run
- THEN the mode is 100755

#### Scenario: verify-kit-clean.sh counters have companion tests that bite

- GIVEN verify-kit-clean.sh counter logic at lines 30-32 with a mutant that resets one counter to 0
- WHEN the companion test suite runs under `--prove-teeth`
- THEN the suite exits non-zero

### Requirement: D4 — §16 Multi-Focus Doctrine Completeness

METHODOLOGY.md §16 MUST state: (1) GLOBAL block-number allocation is required for concurrent lanes
in a shared-global corpus; (2) a peer-owned dirty tree is a hard read-only boundary; (3) a
shared-checkout guard applies to families F1 and F3 concurrent scenarios. These requirements are
prerequisites for U2 (verify-state.sh shared-global fix).

#### Scenario: §16 states global block-number allocation rule

- GIVEN METHODOLOGY.md §16 after D4
- WHEN a structural readback reads the section
- THEN it finds a rule stating that block numbers MUST be allocated globally in shared-global corpora
  with concurrent lanes

#### Scenario: §16 states peer-owned dirty tree is read-only

- GIVEN METHODOLOGY.md §16 after D4
- WHEN a structural readback reads the section
- THEN it finds a statement that a peer-owned dirty tree is a hard read-only boundary

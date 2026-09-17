# Spec: init-onboarding-sequence

**Change**: improve-research-sdd-onboarding-sequence
**Frozen files**: research-sdd/toolbelt/research-sdd-init.sh · research-sdd/toolbelt/tests/research-sdd-init.test.sh
**MUST NOT touch**: research-sdd/PROMPT-LOOP.md (diff against base 0d54949 MUST be empty)

---

## Requirements

### Requirement: CONFIRM/THEN Split in JUDGMENT Follow-up Block

The JUDGMENT follow-up block in `research-sdd-init.sh` stdout MUST split its items into two
visually distinct groups, each introduced by a separate sub-header or annotation line:

- **CONFIRM group** (items 1–2): MUST carry a header that names these items as belonging at
  PROMPT-LOOP §b/§b2, BEFORE the scaffold. The header MUST contain "CONFIRM" and a reference
  to §b or §b2.
- **THEN group** (items 3–5): MUST carry a separate header identifying these as post-scaffold
  steps. The header MUST contain a token such as "THEN" or equivalent and a post-scaffold
  qualifier ("post-scaffold" or analogous).

The flat single header `-- JUDGMENT follow-ups ... do these next --` covering all five items
MUST NOT remain as the only header.

#### Scenario: CONFIRM header present before items 1 and 2

- GIVEN a writable, empty target directory
- WHEN `research-sdd-init.sh <target> --corpus flat` is run (no `--prefix`)
- THEN stdout contains a line that includes "CONFIRM" and a §b reference (e.g., "§b") before
  the REGISTER item (item 1)

#### Scenario: THEN header present before items 3–5

- GIVEN a writable, empty target directory
- WHEN `research-sdd-init.sh <target> --corpus flat` is run
- THEN stdout contains a separate line that includes "THEN" (or equivalent) and a post-scaffold
  qualifier after the CLASSIFY item (item 2) and before the SEED item (item 3)

#### Scenario: Item order preserved under split

- GIVEN a writable, empty target directory
- WHEN `research-sdd-init.sh <target> --corpus flat` is run
- THEN in stdout, item 1 (REGISTER, containing `PROMPT-LOOP §b)`) precedes item 2 (CLASSIFY,
  containing `PROMPT-LOOP §b/§b2`), which precedes item 3 (SEED, containing `§e)`)

---

### Requirement: §18 Sweep Consequence on Item 1

Item 1 (REGISTER) MUST carry the §b consequence inline: that an unregistered target's `retros/`
is invisible to the §18 sweep. The phrasing MUST be concise and MUST NOT reproduce the three.js
lesson verbatim.

#### Scenario: Consequence clause present on item 1

- GIVEN a writable, empty target directory
- WHEN `research-sdd-init.sh <target> --corpus flat` is run
- THEN stdout contains, on or immediately after the item-1 line, at least one of these signals:
  ("invisible" AND "sweep"), or "§18"

#### Scenario: Consequence absent after consequence line is stripped (teeth)

- GIVEN a mutant of research-sdd-init.sh with the consequence clause text removed from the
  item-1 echo
- WHEN the mutant runs against a clean target
- THEN the consequence-clause assertion is red (consequence tokens absent from stdout)

---

### Requirement: Unit-1 Signals Non-Regression

All stdout signals established by the prior unit-1 change MUST remain intact. None may be
regressed.

| Token required in stdout | Condition |
|---|---|
| `PROMPT-LOOP §b)` | always (step-1) |
| `PROMPT-LOOP §b/§b2` | always (step-2) |
| `§e)` | always (step-3) |
| `§c follow-up)` | always (step-4) |
| `no --prefix given` | when `--prefix` is absent |
| `5. Block files use the prefix: <slug>-blockN.md` | when `--prefix <slug>` is passed |
| `research-sdd-status.sh` | always (NEXT line) |
| `BOOTSTRAP` | always (NEXT section) |

#### Scenario: No-prefix run preserves all unit-1 tokens

- GIVEN a writable, empty target directory
- WHEN `research-sdd-init.sh <target> --corpus flat` runs with no `--prefix` flag
- THEN stdout contains each of: `PROMPT-LOOP §b)`, `§e)`, `§c follow-up)`,
  `no --prefix given`, `research-sdd-status.sh`, `BOOTSTRAP`
- AND stdout does NOT contain `5. Block files use the prefix:`

---

### Requirement: PROMPT-LOOP.md Untouched

`research-sdd/PROMPT-LOOP.md` MUST NOT be modified by this change.

#### Scenario: PROMPT-LOOP.md has empty diff

- GIVEN the worktree after applying the change
- WHEN `git diff 0d54949 -- research-sdd/PROMPT-LOOP.md` is run
- THEN the output is empty

---

## Mutation Controls (--prove-teeth)

Each new assertion MUST fail when its corresponding mutant runs:

| Assertion | Mutant | Red signal |
|---|---|---|
| CONFIRM header present | Strip the CONFIRM group header echo | CONFIRM marker absent from stdout |
| THEN header present | Strip the THEN group header echo | THEN marker absent from stdout |
| Item-1 consequence present | Strip consequence clause from item-1 echo | "invisible"/"sweep"/"§18" absent from stdout |

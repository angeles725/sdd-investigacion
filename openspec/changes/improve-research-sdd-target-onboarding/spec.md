# init-onboarding-report Specification

## Purpose

Defines the observable wording contract for `research-sdd-init.sh`'s scaffold report:
JUDGMENT follow-up cross-references, conditional-step transparency, already-git message
accuracy, and end-of-report next-step guidance.

Capability: `init-onboarding-report` (new).
Frozen file scope: `research-sdd/toolbelt/research-sdd-init.sh` and
`research-sdd/toolbelt/tests/research-sdd-init.test.sh` only.

---

## Requirements

### Requirement: PROMPT-LOOP Cross-References on Follow-Up Steps

The JUDGMENT follow-up block MUST carry PROMPT-LOOP section cross-references on steps 1,
3, and 4, matching step 2's existing `(PROMPT-LOOP §b/§b2)` style. Specifically:

- Step 1 (REGISTER TARGETS.md) MUST include `(PROMPT-LOOP §b)`.
- Step 3 (SEED RESEARCH-STATE.md) MUST include `(PROMPT-LOOP §e)`.
- Step 4 (REGISTER + ADAPT the hook) MUST include `(PROMPT-LOOP §c follow-up)`.
- Step 2's existing `(PROMPT-LOOP §b/§b2)` reference MUST NOT be removed.
- Cross-references are one-directional: `PROMPT-LOOP.md` MUST NOT be edited.

#### Scenario: Step-1 cross-ref present in stdout

- GIVEN an empty target directory
- WHEN `research-sdd-init.sh <target>` runs (any corpus mode)
- THEN stdout contains the string `PROMPT-LOOP §b` on the REGISTER TARGETS.md line

#### Scenario: Step-3 cross-ref present in stdout

- GIVEN an empty target directory
- WHEN `research-sdd-init.sh <target>` runs
- THEN stdout contains the string `PROMPT-LOOP §e` on the SEED RESEARCH-STATE.md line

#### Scenario: Step-4 cross-ref present in stdout

- GIVEN an empty target directory
- WHEN `research-sdd-init.sh <target>` runs
- THEN stdout contains the string `PROMPT-LOOP §c follow-up` on the hook adaptation line

---

### Requirement: Conditional Step-5 Transparency

A no-prefix run MUST NOT be indistinguishable from a silently-skipped step 5. When run
without `--prefix`, the report MUST include a note indicating step 5 appears only when
`--prefix` is supplied. When run with `--prefix`, step 5 MUST appear with its prefix value.

#### Scenario: No-prefix run shows step-5 conditional note

- GIVEN an empty target directory
- WHEN `research-sdd-init.sh <target>` runs without `--prefix`
- THEN stdout contains a note indicating step 5 is `--prefix`-conditional
- AND stdout does NOT contain `Block files use the prefix:`

#### Scenario: Prefix run shows step 5

- GIVEN an empty target directory
- WHEN `research-sdd-init.sh <target> --prefix myslug` runs
- THEN stdout contains `Block files use the prefix: myslug-blockN.md`
- AND stdout does NOT contain the step-5-conditional note

---

### Requirement: Accurate Already-Git Message

When the target is already under git, the report MUST distinguish untracked corpus files
from the gitignored `.claude/` hook. The current message ("files land as untracked — git
add as needed") is inaccurate: init appends `.claude/` to `.gitignore`, so the hook is
gitignored, not merely untracked, and plain `git add` is a silent no-op on it (§7
anti-silent-zero: an ignored state currently reads as untracked).

The corrected message MUST convey:
- Corpus files land as untracked — plain `git add` works.
- The `.claude/` hook is gitignored (init added it to `.gitignore`) — requires
  `git add --force` or may intentionally be left ignored.

No runtime git introspection (`git check-ignore` or similar) is added. This is a
text-only factual statement. A new already-git-target fixture MUST be added to the test
suite; the existing fixtures MUST remain unchanged.

#### Scenario: Already-git message names gitignored hook (new fixture)

- GIVEN a target directory that is already a git repository
- WHEN `research-sdd-init.sh <target>` runs
- THEN stdout contains `--force` or `gitignored` in the already-git status line
- AND stdout contains `.claude/` in that line's context

#### Scenario: New fixture exercises the already-git path

- GIVEN a target directory initialized with `git init` before the SUT runs
- WHEN `research-sdd-init.sh <target>` runs
- THEN the SUT exits 0 and the already-git branch is taken (no new git init)

---

### Requirement: End-of-Report Next-Step

After the JUDGMENT follow-up list, the report MUST include an explicit next-step line
referencing `research-sdd-status.sh <target>` and a one-line mental model stating the
target shows BOOTSTRAP status until follow-ups are completed. This MUST appear on every
run (no-prefix and `--prefix`), before or at `== done ==`.

#### Scenario: Next-step pointer present in stdout

- GIVEN any valid target directory
- WHEN `research-sdd-init.sh <target>` runs
- THEN stdout contains `research-sdd-status.sh`

#### Scenario: Mental model present in stdout

- GIVEN any valid target directory
- WHEN `research-sdd-init.sh <target>` runs
- THEN stdout contains `BOOTSTRAP` in the next-step section (after the follow-up list)

---

## Test Constraints

- Every new assertion MUST go red when the corresponding echo in `research-sdd-init.sh`
  is mutated (teeth requirement via `--prove-teeth`).
- Assertions against stdout MUST capture SUT output into a variable or file and use
  `grep -qF` against it; they MUST NOT rely on file contents for stdout claims.
- The new already-git-target fixture creates a `git init` directory before invoking the
  SUT; it is a separate fixture from the existing GOOD-1 through GOOD-5 fixtures.
- `PROMPT-LOOP.md`, `sweep-*.sh`, `verify-*.sh`, `*-hook.sh`, `research-sdd-status.sh`,
  and `templates/` MUST NOT be modified by this change.
- Propose-never-apply and read-only-corpora are preserved; no corpus file is modified.

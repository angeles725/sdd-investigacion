# kit-session-cost Specification

## Purpose

Total SessionStart hook output MUST remain under 8,000 characters. `sweep-retros-hook.sh` MUST
produce a compact summary under 3,000 characters. `verify-tool-catalog-hook.sh` MUST emit a
non-empty sentinel when clean, making a clean run distinguishable from a crash.

## Requirements

### Requirement: sweep-retros-hook.sh Summary Mode

`sweep-retros-hook.sh` MUST operate in summary mode by default: emit a headline count of pending
retros, the N oldest, and a pointer to the full list. Absent-input targets MUST be collapsed to a
single counted summary line rather than one line per absent target. Full output MUST remain
accessible behind a verbose flag. Default output MUST be under 3,000 characters.

#### Scenario: Default output under 3,000 characters

- GIVEN a session startup on the real kit with real targets including absent-input ones
- WHEN `sweep-retros-hook.sh` runs in default mode
- THEN the total character count of its stdout is less than 3,000
- AND the exit code is 0

#### Scenario: Absent-input targets collapsed to one counted line

- GIVEN multiple corpus targets not reachable on the current machine (absent-input)
- WHEN `sweep-retros-hook.sh` runs
- THEN all absent targets are reported in a single summary line (e.g., `N targets absent`)
- AND there is NOT one line per absent target

#### Scenario: Full output available behind verbose flag

- GIVEN the hook invoked with the verbose flag
- WHEN that flag is present
- THEN the full retro listing is emitted, not just the summary counts

### Requirement: verify-tool-catalog-hook.sh Clean Sentinel

`verify-tool-catalog-hook.sh` MUST emit at least one non-empty line when the tool catalog is clean,
following the precedent established in issue #380. An empty stdout output MUST NOT be the clean
signal; it MUST be reserved for a crash or operational failure.

#### Scenario: Clean run emits a non-empty sentinel line

- GIVEN a clean tool catalog (no missing or undeclared entries)
- WHEN `verify-tool-catalog-hook.sh` runs
- THEN it emits at least one non-empty line (the clean sentinel)
- AND exits 0

#### Scenario: Absent catalog reported distinctly

- GIVEN the tool catalog file does not exist
- WHEN `verify-tool-catalog-hook.sh` runs
- THEN it exits non-zero and prints a typed absent-input indication
- AND does NOT emit empty stdout (which could be mistaken for a clean run)

#### Scenario: Mutation — sentinel removal goes red

- GIVEN a mutant that removes the clean sentinel line
- WHEN the companion test suite runs under `--prove-teeth`
- THEN the suite exits non-zero

### Requirement: D2 — DYNAMIC-SETUP and DEPLOY-WINDOWS-MINIPC.md

DYNAMIC-SETUP.md §1 MUST include a subsection covering how to raw-image a physical or removable
disk when `wsl --mount` fails. A new file `toolbelt/DEPLOY-WINDOWS-MINIPC.md` MUST be created
with Windows miniPC deployment content. `tool-registry.md` MUST include rows for the 15 currently
unregistered operator tools.

#### Scenario: §1 raw-image subsection present

- GIVEN DYNAMIC-SETUP.md §1 after the update
- WHEN a structural readback reads the section
- THEN it finds a subsection describing raw-image of a physical disk when wsl --mount fails

#### Scenario: DEPLOY-WINDOWS-MINIPC.md exists and is registered

- GIVEN toolbelt/DEPLOY-WINDOWS-MINIPC.md after the update
- WHEN tool-registry.md is read
- THEN it contains a row for DEPLOY-WINDOWS-MINIPC.md

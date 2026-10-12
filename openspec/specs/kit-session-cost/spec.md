<!-- Published from change research-sdd-kit-retro-campaign (archived 2026-09-06, main b67e4f7) -->
# kit-session-cost Specification

## Purpose

Total SessionStart hook output MUST remain under 8,000 characters. `sweep-retros-hook.sh` MUST
produce a compact summary under 3,000 characters. `verify-tool-catalog-hook.sh` MUST emit a
non-empty sentinel when clean, making a clean run distinguishable from a crash.

> Verify note (2026-09-06): measured total after #437 is 8.7–9.4k chars across the 7 hooks; the two largest (sweep-breakthroughs-hook 2.8k, sweep-audits-hook 2.4k) print 17 absent-input INFO lines each. Follow-up instrument unit: kit issue #501 (expected total < 5k). The 8k target stands as the acceptance for that unit.


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

### Requirement: Session budget is measured per harness, and the report names the harness

`verify-session-budget.sh` MUST state which harness each aggregate measures. The default (`--harness claude`) measures the
Claude Code SessionStart hooks of `<target>/.claude/settings.json` and its output MUST NOT change. `--harness pi` MUST measure the
pi / gentle-shell path: the system-prompt sections that the kit extension `research-sdd-hooks.ts` and every extension in
`<target>/.pi/extensions` add on `before_agent_start`, summed as decoded characters (Unicode code points), inside the same
sandbox as the Claude path (read-only filesystem, no network, throwaway copy of `<target>/.claude`). It MUST print
`aggregate[pi]: <n> chars (budget < 8000) OK|OVER BUDGET`, with `(partial: K degraded)` when a section reports itself DEGRADED or an
extension failed to load. `--harness both` prints the Claude report and then the pi report. When the pi path cannot run (node
absent, node without TypeScript type stripping, no usable bwrap, kit extension missing, harness timeout or silent) it MUST print
`pi: DEGRADED — <reason>` and a `state: degraded` line, and MUST NOT print an `aggregate[pi]` line: a degraded run is never a
zero. A pi measurement is made with the kit under test (its real extension and, unless `RSDD_BUDGET_KIT` points elsewhere, its
real sweeps) and one startup `session_start` followed by one `before_agent_start`; other session sources are not measured.

The pi report MUST state its emulation limits (`limits:` line): the fake `pi` has a no-op API and no `ctx.mode`/model/tools,
`session_start` handlers run in parallel and `before_agent_start` handlers one after another. Counted: sections added to
`systemPromptOptions.sections` and the content of a returned `message`. An extension that injects through a route whose size
cannot be attributed (a returned `systemPrompt`, an edit of `event.systemPrompt`, any other returned key) MUST be reported as
`status=unmeasured(...)` and mark the aggregate partial: never a 0-char OK. The helper MUST end with a closing marker and give
every extension exactly one final record; a missing marker or a short record set (an extension called `process.exit`) is a
partial, degraded report. Each handler has its own wait, so one hanging extension yields its own degraded line and the others are
still measured. Extension names are paths below `.pi/extensions`. A target with no `.claude` is shadowed by a throwaway one so the
kit extension's session-sha write lands in the sandbox, as it does when a copy is bound.

#### Scenario: Pi aggregate is reported and equals the sum of its sections

- GIVEN a target with a `.pi/extensions` extension that adds one section of known length
- WHEN `verify-session-budget.sh --harness pi <target>` runs
- THEN it prints `harness: pi`, one `section[...]` line for the kit extension and one for the target extension
- AND `aggregate[pi]` equals the sum of the section lines and carries the OK or OVER BUDGET verdict against 8,000

#### Scenario: Pi path that cannot run is typed, not zero

- GIVEN node is absent, or lacks TypeScript type stripping, or bwrap cannot start
- WHEN `--harness pi` runs
- THEN it prints `pi: DEGRADED — <reason>` and `state: degraded`
- AND it does NOT print an `aggregate[pi]` line

#### Scenario: Unattributable injection and early exits are partial, not zero

- GIVEN an extension that returns a `systemPrompt`, edits `event.systemPrompt`, or calls `process.exit` in its handler
- WHEN `--harness pi` runs
- THEN the report marks the extension `unmeasured(...)` or prints `harness: degraded(incomplete record set ...)`
- AND the aggregate carries `(partial: K degraded)` and `state: degraded`

#### Scenario: Claude output is unchanged by the pi harness

- GIVEN the default invocation (no `--harness`)
- WHEN it runs on any target
- THEN its output is byte-identical to the output of the script before `--harness` existed, asserted against frozen fixtures (`measured on 2026-10-11 at 5316fe5c`), not recomputed from git

#### Scenario: Mutation — dropping a pi section or the verdict goes red

- GIVEN a mutant that ignores section lengths, never reports OVER BUDGET, or discovers no target extensions
- WHEN the companion suite runs under `--prove-teeth`
- THEN the suite exits non-zero

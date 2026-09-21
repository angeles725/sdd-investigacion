# EN4 — External Driven Verification of /research-sdd (design)

**Status:** design (2026-09-20). Implementation deferred; this doc is the spec.

## Purpose

Prove that `/research-sdd` auto-fires every required instrument WITHOUT a human or agent
manually running anything. This is the acceptance gate for the "sí o sí" requirement: EN1
(RETRO-DUE detection), EN2a (init auto-wires the hooks), and EN3 (Stop gate auto-seeds
issues) each remove a manual step; only an end-to-end driven run proves the pipeline fires
on its own.

## Why external + driven (not a unit test)

- A unit test proves an instrument works WHEN CALLED. It cannot prove the loop CALLS it.
  The kit's own maxim: `go test ./bench` never proves driven execution.
- A FRESH session reproduces the real operator experience — including the failure that
  started this campaign (a stale checkout where the tool was not even present, and a manual
  step nobody ran). The verifying session must not be the one that built the fix.
- It must be REPEATABLE (a journey / regression gate), not a one-off, so a future change
  that re-breaks auto-firing is caught.

## Setup

- A SACRIFICIAL target: a throwaway corpus dir registered in a test TARGETS.md (or a
  dedicated `targets.test` fixture), never a real research corpus. Seeded with enough blocks
  to cross the §18 `blocks_since_retro` threshold so RETRO-DUE can trigger.
- A fresh session / clean checkout at `origin/main` (post-merge of EN1/EN2a/EN3), so no
  in-session contamination. Prefer a harness worktree under $HOME.
- `gh` authenticated against a scratch repo (or a dry-run mode) so issue-seeding is
  observable without polluting the real kit backlog. If seeding into the real kit repo,
  clean up the created test issues afterward.

## Requirements to verify (from the manual-steps audit) — each auto-fires, zero manual calls

| # | Requirement | Auto-fire check (assertion) |
|---|---|---|
| R1 | SessionStart sweeps run | The 7 sweep/verify hooks appear in session-start output for the target. |
| R2 | `research-sdd-init` auto-wires hooks (EN2a) | After init, the target's `.claude/settings.json` contains BOTH the Stop (retro-gate) and SessionStart (research-protocol) hook entries — with NO manual paste. `--no-wire` omitted. |
| R3 | RETRO-DUE auto-detected (EN1/#627) | With `blocks_since_retro` over threshold, `research-sdd-status.sh <t> --next` emits `RETRO-DUE` on its own — no manual threshold check. |
| R4 | retro-gate blocks close without retro | Attempting to close (Stop) with the retro unwritten is BLOCKED by the wired hook. |
| R5 | Issue-seeding auto-fires on Stop (EN3) | After the retro is written, closing the session runs `stage-retro-issues --apply` automatically → backlog-first issues exist for the retro's open deltas, with NO manual seeding call. |
| R6 | reconcile confirms tracked | `reconcile-issues.sh <retro>` reports the seeded deltas as `tracked`, not `untracked`. |
| R7 | Degraded is honest | With `gh` unauthenticated, R5 emits a `degraded` WARN and the session still closes (does not hang/block); nothing is falsely reported as created. |

PASS only if EVERY row auto-fired with zero manual instrument invocation. A single manual
call to make a row pass is a FAIL (that is the exact defect this gate exists to catch).

## Implementation vehicle

Prefer a `gentle-ai-bench` journey (driven mode) over a bash script, so it is a durable
regression gate. The journey scripts the fresh-session lifecycle and asserts R1–R7. Load the
`gentle-ai-bench` skill to author it. A one-off bash harness is acceptable as a first proof,
but it is not the deliverable — the repeatable journey is.

The bash harness `research-sdd/toolbelt/tests/enforcement-e2e.test.sh` covers R2/R3/R5/R6/R7
hermetically (scratch fixtures, PATH shims, no real GitHub, no real targets). R1 and R4 are
session-lifecycle behaviors that require a live Claude Code session; see the runbook below.

## Open questions for the user

- Scratch repo vs real kit repo for the seeded test issues (cleanup burden vs isolation).
- Whether to add this journey to CI as a blocking regression gate, or run it on demand.

---

## R1 and R4 Manual Runbook

R1 (SessionStart sweeps firing) and R4 (retro-gate blocking close before retro) are
harness-integration behaviors that only a live driven `/research-sdd` session exercises.
A bash script cannot fake the Claude Code lifecycle. Verify them by hand as follows.

### Prerequisites

- A clean worktree on `origin/main` (post-merge of EN1/EN2a/EN3) — the branch whose hooks
  you want to verify. Never use a branch mid-PR; the hooks under test must be at the merged
  state.
- A throwaway target directory (e.g. `~/tmp/en4-test-target`) initialized with
  `research-sdd-init.sh`. Do NOT use any real research corpus.

### R1 — SessionStart sweeps fire automatically

1. Open a fresh Claude Code session with the throwaway target as the working directory (or
   pass it via hook config). Do NOT manually run any sweep.
2. Observe the session-start output in the terminal/hook log.
3. **Expected**: lines from the 7 registered sweep/verify hooks appear automatically
   (e.g. `sweep-retros-hook`, `verify-kit-clean-hook`, etc.) without any `/slash` command.
4. **PASS** if all 7 hooks produce output. **FAIL** if any hook is silent or the hooks are
   not wired in `.claude/settings.json` of the target.

### R4 — retro-gate blocks close before retro is written

1. Using the same fresh session and throwaway target:
   a. Write at least one block file (e.g. `echo "# block" > block1.md`) and commit it.
   b. Do NOT write a retro.
2. Attempt to end the session (Stop hook fires on `/exit` or session close).
3. **Expected**: the Stop hook emits `{"decision":"block","reason":"§18 retro pending..."}`.
   Claude Code's stop-hook contract prevents the session from closing. The terminal shows the
   block reason and prompts for a retro before closing.
4. Write the retro (use `research-sdd/templates/retro.template.md`) and attempt to close again.
5. **PASS** if the first close is blocked and the second (post-retro) close succeeds with
   issue-seeding output visible in the hook log (R5 also confirmed). **FAIL** if the first
   close is NOT blocked or if the block reason is absent/unclear.

### Notes

- Both R1 and R4 can be observed in the same session run; run them together.
- Capture the hook output log for the audit trail (use `/export` or copy the terminal).
- These steps are one-time acceptance tests for a merged EN1/EN2a/EN3 branch, plus a
  regression check after any change to hook wiring or the retro-gate logic.

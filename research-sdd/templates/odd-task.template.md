# <Feature name> — ODD task document

<!--
Template for `odd/tasks/<feature-name>.md` (kit issue #1710). Copy it, replace every <placeholder>.
Each task block carries a `Route:` line (inline or delegated, plus the trigger evidence) and an
`Evidence:` line (what was observed before the box was checked). No checker enforces these lines yet;
the only structural check today is research-sdd/toolbelt/tests/templates.test.sh, which verifies
this template itself, not the task documents copied from it.
-->

## Objective
<one or two sentences: the outcome and why it matters>
Objective line: <when the operator stated an explicit objective, copy it verbatim; each task's Route/Evidence maps back to it, and side-defects become typed sub-tasks (OBJECTIVE-LOCK)>

## Authorized scope
<what the maintainer authorized: commit / push / PR / merge; what stays hand-edited>

## TDD
Mode: <on|off> · runner: `<command>` · exception (if any): <why no RED>

## Tasks
<!-- One block per task. Check the box only after the outcome was observed. -->
- [ ] T1 — <task title and issue number>.
  Route: <inline | delegated writer | delegated explorer> — <trigger evidence, e.g. "2+ non-trivial files">.
  Evidence: <pending — fill with the observed command result, commit sha, or PR number before checking>.
- [ ] T2 — <task title and issue number>.
  Route: <inline | delegated writer | delegated explorer> — <trigger evidence>.
  Evidence: <pending>.

## Verification
<command: observed result, one per line>

## Next step
<what remains, or "none">

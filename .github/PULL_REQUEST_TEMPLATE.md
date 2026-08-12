<!--
  READ BEFORE SUBMITTING

  Every PR must:
  1. Link an approved issue (with status:approved label)
  2. Have exactly one type:* label
  3. Pass all automated checks (shellcheck, test suite, mutation controls)

  See CONTRIBUTING.md for the full workflow.
-->

## Linked Issue

<!-- REQUIRED: Replace N with the issue number. The issue must carry status:approved. -->
<!-- Automated check: "Check Issue Reference" verifies this exists. -->
<!-- Automated check: "Check Issue Has status:approved" verifies the issue is approved. -->

Closes #

---

## PR Type

<!-- REQUIRED: Check exactly ONE type below, then add the matching label to the PR. -->
<!-- Automated check: "Check PR Has type:* Label" verifies the label exists. -->

- [ ] `type:bug` — Bug fix
- [ ] `type:feature` — New feature
- [ ] `type:docs` — Documentation only
- [ ] `type:refactor` — Code refactoring (no behavior change)
- [ ] `type:chore` — Maintenance/tooling
- [ ] `type:breaking-change` — Breaking change

---

## Summary

<!-- What does this PR do? Be concise — 1-3 bullet points. -->

-

## Changes

<!-- Key files changed and what was modified in each. -->

| File | Change |
|------|--------|
| `path/to/file` | What changed |

## Test Plan

<!-- Kit quality gates — all must pass before merge (CLAUDE.md §5). -->

- [ ] Shellcheck passes: `shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh`
- [ ] Test suite passes: `bash research-sdd/toolbelt/tests/run-all.sh`
- [ ] Mutation controls go red: `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth`
- [ ] New toolbelt scripts ship with a companion `*.test.sh` (TDD, §4)

---

## Work-Unit Budget

<!-- Kit rule: ~400 authored physical touched lines per PR (CLAUDE.md §6). -->

Changed lines: __ / 400

- [ ] If over 400, a chained-PR split is declared below with what is deferred and why (§6)

<!-- If splitting: describe what is deferred and why. -->

---

## Contributor Checklist

- [ ] Commit title follows [conventional commits](https://www.conventionalcommits.org/) format (e.g. `fix(scope): ...`)
- [ ] No `Co-Authored-By` or AI-attribution trailers in any commit (§10)
- [ ] All artifacts — code, comments, docs, tests — are in English (§9)
- [ ] No target corpus directory was modified (propose-never-apply, §8)
- [ ] I linked an approved issue above (`Closes #N`)
- [ ] I added exactly **one** `type:*` label to this PR

---

## Notes for Reviewers

<!-- Optional: context, tradeoffs, open questions. -->

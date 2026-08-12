# Contributing to sdd-investigacion

This is a **research-sdd kit** repository. Kit tools surface findings for humans to act on —
they never modify target corpora (propose-never-apply). Read `CLAUDE.md` for the full
kit-maintenance contract before making changes.

---

## Issue-First Workflow

Every change must start with an issue. PRs without an approved issue are blocked automatically.

1. **Open an issue** using one of the templates (Bug Report or Feature Request).
   The issue receives `status:needs-review` automatically.
2. **Wait for approval.** A maintainer reviews the issue and adds `status:approved` if accepted.
   Do not open a PR before this step — the `check-issue-approved` CI job will block it.
3. **Branch off `main`** using the naming convention below.
4. **Implement** with conventional commits and strict TDD (see Gates below).
5. **Open a PR** with `Closes #N` in the body and exactly one `type:*` label.
6. **All gates must pass** before merge (see Gates below).

---

## Branch Naming

Branches must match:

```
^(feat|fix|chore|docs|style|refactor|perf|test|build|ci|revert)\/[a-z0-9._-]+$
```

Examples: `fix/sigpipe-race`, `feat/sweep-audits-v2`, `docs/methodology-gap-grammar`.

---

## Commit Messages

Use [conventional commits](https://www.conventionalcommits.org/):

```
type(scope): short imperative description
```

- No `Co-Authored-By` trailers.
- No AI-attribution trailers.
- All content in English (CLAUDE.md §9).

---

## Quality Gates

All three gates must pass before a PR can be merged (CLAUDE.md §5):

| Gate | Command |
|------|---------|
| Shellcheck | `shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh` |
| Test suite | `bash research-sdd/toolbelt/tests/run-all.sh` |
| Mutation controls | `bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth` |

New toolbelt scripts must ship with a companion `*.test.sh` under
`research-sdd/toolbelt/tests/` (TDD, CLAUDE.md §4): write the failing test first,
confirm it fails for the right reason, implement until it passes, then verify
a meaningful mutation turns it red.

---

## Work-Unit Budget

Aim for **~400 authored physical touched lines per PR** so a reviewer can hold the
whole change in their head (CLAUDE.md §6). If scope exceeds that, split into chained PRs
and state explicitly what is deferred and why — silent scope compression is a defect.

---

## Propose-Never-Apply

Kit tools are **read-only with respect to target corpora**. A script that surfaces a
finding must never auto-apply it. Build test fixtures under
`research-sdd/toolbelt/tests/fixtures/` — never inside a live target directory (CLAUDE.md §8).

---

## PR Checklist Summary

- Linked issue has `status:approved`
- PR body contains `Closes #N` / `Fixes #N` / `Resolves #N`
- Exactly one `type:*` label on the PR
- All three quality gates pass
- Conventional-commit title, no AI trailers, English artifacts

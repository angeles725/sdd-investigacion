---
name: kit-issue-creation
description: "Create research-sdd kit issues with issue-first checks. Trigger: create a kit issue, bug report, or feature request for research-sdd kit maintenance."
user-invocable: true
license: MIT
metadata:
  author: cristian
  version: "1.0"
---

# kit-issue-creation

**Scope:** Kit-maintenance issues for `angeles725/sdd-investigacion` (private). This skill governs
work **on the kit** — toolbelt scripts, skills, tests, CI, docs. It does NOT govern research-loop
targets or corpora.

Language contract: all issue content in English (CLAUDE.md §9).

---

## Critical Rules

1. **Blank issues are disabled** — MUST use a template (`bug_report.yml` or `feature_request.yml`).
2. **Every issue gets `status:needs-review` automatically** on creation.
3. **A maintainer must add `status:approved`** before any PR is opened.
4. **Questions and discussion** go to GitHub Discussions, not issues.
5. **Solo-repo reality:** contributor and maintainer are often the same person. The approval step
   still serves a purpose — it forces intent-before-code and creates a typed, searchable record. Do
   not skip it just because you wear both hats.

---

## Workflow

```
1. Search existing issues for duplicates
2. Choose the correct template (Bug Report or Feature Request)
3. Fill in ALL required fields
4. Check the pre-flight checkboxes
5. Submit → issue receives status:needs-review automatically
6. Maintainer reviews and adds status:approved (may be you, after deliberate review)
7. Only then open a PR — link it with Closes #N
```

---

## Issue Templates

Templates live under `.github/ISSUE_TEMPLATE/`.

### Bug Report — `.github/ISSUE_TEMPLATE/bug_report.yml`

Auto-labels: `type:bug`, `status:needs-review`

| Field | Description |
|-------|-------------|
| **Pre-flight Checks** | No duplicate; understands approval workflow |
| **Bug Description** | Clear description of the defect |
| **Steps to Reproduce** | Numbered steps |
| **Expected Behavior** | What should happen |
| **Actual Behavior** | What happens instead (include errors/logs) |
| **Shell** | bash, zsh, or other |
| **Relevant Logs** | Optional; auto-formatted as code block |
| **Additional Context** | Optional screenshots, workarounds |

Example:

```bash
gh issue create --template "bug_report.yml" \
  --title "fix(toolbelt): verify-registry exits 0 on missing TARGETS.md" \
  --body "
### Pre-flight Checks
- [x] I have searched existing issues and this is not a duplicate
- [x] I understand this issue needs status:approved before a PR can be opened

### Bug Description
verify-registry.sh returns 0 and prints no error when TARGETS.md is absent.

### Steps to Reproduce
1. Remove or rename TARGETS.md
2. Run: bash research-sdd/toolbelt/verify-registry.sh
3. Observe exit 0 with no output

### Expected Behavior
Exit 1 with an operational-failure message (absent-input state, CLAUDE.md §7).

### Actual Behavior
Silent exit 0.

### Shell
zsh

### Relevant Logs
\`\`\`
(no output)
\`\`\`
"
```

---

### Feature Request — `.github/ISSUE_TEMPLATE/feature_request.yml`

Auto-labels: `type:feature`, `status:needs-review`

| Field | Description |
|-------|-------------|
| **Pre-flight Checks** | No duplicate; understands approval workflow |
| **Problem Description** | Pain point this feature solves |
| **Proposed Solution** | How it should work |
| **Affected Area** | Toolbelt, Skills, Tests, CI, Docs, Other |
| **Alternatives Considered** | Optional |
| **Additional Context** | Optional |

Example:

```bash
gh issue create --template "feature_request.yml" \
  --title "feat(tests): add --prove-teeth gate to run-all.sh summary" \
  --body "
### Pre-flight Checks
- [x] I have searched existing issues and this is not a duplicate
- [x] I understand this issue needs status:approved before a PR can be opened

### Problem Description
run-all.sh --prove-teeth passes or fails but does not print the mutation summary
alongside the regular suite summary, making it harder to audit teeth coverage.

### Proposed Solution
After mutation controls run, print a compact line: 'Mutation controls: N/N red'.

### Affected Area
Tests (run-all.sh)
"
```

---

## Label System

### Applied automatically on creation

| Template | Labels added |
|----------|-------------|
| Bug Report | `type:bug`, `status:needs-review` |
| Feature Request | `type:feature`, `status:needs-review` |

### Applied by maintainer

| Label | When to apply |
|-------|--------------|
| `status:approved` | Issue accepted — PRs may now be opened |
| `priority:high` | Critical defect or blocker |
| `priority:medium` | Important but not blocking |
| `priority:low` | Nice to have |
| `effort:small` | Estimated ≤ half a day |
| `effort:medium` | Estimated ≤ 2 days |
| `effort:large` | Estimated > 2 days or warrants chained PRs |

Full label taxonomy is defined in `.github/labels.yml`:
`type:bug|feature|docs|refactor|chore|breaking-change` ·
`status:needs-review|approved|in-progress|blocked|stale|wontfix` ·
`priority:high|medium|low` · `effort:small|medium|large`

---

## Maintainer Approval Workflow

```
1. New issue arrives with status:needs-review
2. Review: is it valid, clear, in scope, and not covered by existing doctrine?
3. YES → add status:approved
4. NO  → comment with reason; close if needed
5. Contributor opens a PR with Closes #N
```

---

## Commands

```bash
# Search before creating
gh issue list --search "keyword"
gh issue list --label "type:bug"

# Create bug report
gh issue create --template "bug_report.yml" --title "fix(scope): description"

# Create feature request
gh issue create --template "feature_request.yml" --title "feat(scope): description"

# Approve an issue (maintainer step)
# NOTE: gh issue edit --add-label exits 1 on this repo due to a GraphQL deprecation.
# Use the REST API instead:
gh api repos/angeles725/sdd-investigacion/issues/<number>/labels \
  -f 'labels[]=status:approved'

# View issue to confirm labels
gh issue view <number>
```

---
name: kit-branch-pr
description: "Open a PR for the research-sdd kit. Trigger: creating, opening, or preparing a pull request for kit maintenance work."
user-invocable: true
license: MIT
metadata:
  author: cristian
  version: "1.0"
---

# kit-branch-pr

**Scope:** Pull requests against `angeles725/sdd-investigacion` (private) for kit-maintenance
work — toolbelt scripts, skills, tests, CI, docs. Not for research-loop target corpora.

Language contract: all PR content in English (CLAUDE.md §9).
No `Co-Authored-By` trailers (CLAUDE.md §10). Conventional commits only (CLAUDE.md §10).

---

## Critical Rules

1. **Every PR MUST link an approved issue** — `Closes #N` / `Fixes #N` / `Resolves #N`.
2. **Every PR MUST have exactly one `type:*` label**.
3. **All three kit gates must pass** before requesting review (see Test Plan below).
4. **`.github/workflows/pr-check.yml`** enforces: issue reference, `status:approved` on the linked
   issue, and exactly one `type:*` label. PRs that fail are blocked from merge.
5. **Work-unit budget: ~400 authored changed lines per PR** (CLAUDE.md §6). If the PR would exceed
   that, use the `kit-chained-pr` skill to split it.

---

## Workflow

```
1. Confirm the linked issue has status:approved
2. Create branch: type/description (regex below)
3. Implement with conventional commits
4. Run all three kit gates (see Test Plan)
5. Open PR filling .github/PULL_REQUEST_TEMPLATE.md
6. Add exactly one type:* label via gh api (see GOTCHA)
7. Verify automated checks pass in GitHub Actions
```

---

## Branch Naming

Branch names MUST match:

```
^(feat|fix|chore|docs|style|refactor|perf|test|build|ci|revert)\/[a-z0-9._-]+$
```

Format: `type/short-description` — lowercase, no spaces, `a-z0-9._-` only.

| Type | Pattern | Example |
|------|---------|---------|
| Feature | `feat/<desc>` | `feat/run-all-mutation-summary` |
| Bug fix | `fix/<desc>` | `fix/verify-registry-silent-zero` |
| Refactor | `refactor/<desc>` | `refactor/extract-target-paths` |
| Tests | `test/<desc>` | `test/sweep-retros-edge-cases` |
| Docs | `docs/<desc>` | `docs/claude-md-anti-silent-zero` |
| Chore/CI | `chore/<desc>` | `chore/update-shellcheck-version` |

---

## PR Body

Fill `.github/PULL_REQUEST_TEMPLATE.md`. Required sections:

### 1. Linked Issue (REQUIRED)

```markdown
Closes #<issue-number>
```

The linked issue MUST carry `status:approved`.

### 2. PR Type (REQUIRED — check exactly ONE)

| Checkbox | Label to add |
|----------|-------------|
| Bug fix | `type:bug` |
| New feature | `type:feature` |
| Documentation only | `type:docs` |
| Code refactoring | `type:refactor` |
| Maintenance/tooling | `type:chore` |
| Breaking change | `type:breaking-change` |

### 3. Summary

1–3 bullet points of what the PR does.

### 4. Changes Table

```markdown
| File | Change |
|------|--------|
| `research-sdd/toolbelt/verify-registry.sh` | Exit 1 on absent TARGETS.md |
| `research-sdd/toolbelt/tests/verify-registry.test.sh` | Tests for absent-input path |
```

### 5. Test Plan (kit gates — CLAUDE.md §5)

All three gates must pass on a quiet tree before requesting review:

```bash
# Gate 1 — shellcheck (zero warnings; globstar required for full coverage)
shopt -s globstar && shellcheck -S warning research-sdd/toolbelt/**/*.sh

# Gate 2 — full test suite (skipped ≠ passed; zero-coverage run exits 1)
bash research-sdd/toolbelt/tests/run-all.sh

# Gate 3 — mutation controls (every mutation control must go red)
bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth
```

Check each in the PR:
```markdown
- [x] shellcheck: zero warnings
- [x] run-all.sh: all suites pass
- [x] run-all.sh --prove-teeth: all mutation controls go red
- [x] PR is within ~400 authored lines (or kit-chained-pr used)
```

### 6. Contributor Checklist

```markdown
- [ ] Linked an approved issue (Closes #N)
- [ ] Exactly one type:* label added
- [ ] All three kit gates pass
- [ ] New script has a companion *.test.sh (CLAUDE.md §5)
- [ ] Docs updated if behavior changed
- [ ] Conventional commit format
- [ ] No Co-Authored-By trailers (CLAUDE.md §10)
- [ ] English-only artifacts (CLAUDE.md §9)
```

---

## Commit-Type → PR Label Map

| Commit type | PR label |
|-------------|----------|
| `feat` | `type:feature` |
| `fix` | `type:bug` |
| `docs` | `type:docs` |
| `refactor` | `type:refactor` |
| `chore` | `type:chore` |
| `style` | `type:chore` |
| `test` | `type:chore` |
| `build` | `type:chore` |
| `ci` | `type:chore` |
| `perf` | `type:feature` |
| `revert` | `type:bug` |
| `feat!` / `fix!` | `type:breaking-change` |

Pick the label that matches the **dominant** commit type. When commits mix types, the PR's primary
intent decides.

---

## GOTCHA — gh pr edit --add-label is broken on this repo

`gh pr edit <n> --add-label <name>` **exits 1** on `angeles725/sdd-investigacion` with:

```
GraphQL: The `projectCards` field is deprecated ...
```

The label is NOT applied. Use the REST API instead (works for both issues and PRs):

```bash
gh api repos/angeles725/sdd-investigacion/issues/<pr-number>/labels \
  -f 'labels[]=type:feature'
```

The same issue endpoint accepts multiple calls or multiple `labels[]` entries:

```bash
gh api repos/angeles725/sdd-investigacion/issues/<pr-number>/labels \
  -f 'labels[]=type:feature' \
  -f 'labels[]=priority:medium'
```

---

## Commands

```bash
# Create branch
git checkout -b feat/my-feature main

# Conventional commit (no Co-Authored-By)
git commit -m "feat(toolbelt): add mutation summary to run-all.sh"

# Push and open PR
git push -u origin feat/my-feature
gh pr create \
  --title "feat(toolbelt): add mutation summary to run-all.sh" \
  --body "Closes #42
..."

# Add type label (use REST API — see GOTCHA above)
gh api repos/angeles725/sdd-investigacion/issues/<pr-number>/labels \
  -f 'labels[]=type:feature'

# Check automated CI status
gh pr checks <pr-number>
```

---
name: kit-chained-pr
description: "Split a kit change into chained PRs. Trigger: PR over ~400 authored lines, stacked PRs, or review slices for research-sdd kit maintenance."
user-invocable: true
license: MIT
metadata:
  author: cristian
  version: "1.0"
---

# kit-chained-pr

**Scope:** Splitting oversized kit-maintenance PRs for `angeles725/sdd-investigacion`. Load this
skill when a planned PR exceeds ~400 authored changed lines, or when the user asks for stacked PRs,
review slices, or chained delivery.

Budget rationale is in CLAUDE.md §6. This skill operationalizes it — do not re-derive "why 400" here.

---

## Hard Rules

- Split PRs over **~400 authored changed lines** unless a maintainer explicitly accepts `size:exception`.
- Keep each PR reviewable in about **≤60 minutes**.
- One deliverable work unit per PR. Keep tests and docs with the unit they verify.
- State start, end, dependencies, follow-up work, and out-of-scope items in every chained PR.
- Mark the current PR with `📍` in the dependency diagram.
- Do not mix chain strategies after one is chosen.

---

## Group by Destination File, Not by Source

From CLAUDE.md §3 (the durable lesson from a 74-delta backlog):

> Group a delta backlog by **DESTINATION FILE**, not by source retro.

When many retros or work items target the same kit files, grouping by source serializes everything
through the same handful of files and cannot parallelize. Grouping by destination makes file sets
disjoint — and it surfaces contradictions that are invisible one source at a time (a delta asking
BOOTSTRAP to seed `tools/` while an init-script comment said `tools/` was deliberately not
scaffolded; a registry row documenting an interface that did not exist).

**Before choosing a chain strategy:** list every destination file across the full scope, group the
work by file, and verify the slices are disjoint. A slice that still shares a file with another
needs further splitting or sequencing.

---

## Decision Gates

| Condition | Action |
|---|---|
| PR ≤400 authored lines, focused | Keep single PR — use `kit-branch-pr` |
| PR >400, each slice can land independently | Use **Stacked PRs to main** |
| PR >400, slices must integrate before main | Use **Feature Branch Chain** with tracker |
| Generated/auto diff cannot split cleanly | Ask maintainer for `size:exception` |

---

## Two Strategies

### Stacked PRs to Main

Each slice lands on `main` in order. After a parent PR merges, rebase/retarget the next PR so
GitHub shows only the current slice's diff.

```
main ← PR 1: foundation
         └── PR 2: feature slice (built on PR 1)
               └── PR 3: tests/docs (built on PR 2)
```

Use when: each slice delivers standalone value and can ship without the rest.

### Feature Branch Chain

A tracker/integration branch accumulates the full feature; child PRs are reviewed as focused slices.
The tracker PR stays **draft/no-merge** until all children are merged.

```
main
 └── feat/my-feature              ← tracker branch (draft PR)
      └── feat/my-feature-01-core     ← PR 1 targets tracker
           └── feat/my-feature-02-...  ← PR 2 targets PR 1's branch
```

Use when: slices only make sense together and must integrate before main.

---

## Execution Steps

1. Estimate changed lines; identify independent destination-file groups.
2. Choose a strategy (ask only if genuinely ambiguous and the wrong choice is expensive).
3. Create branches and PRs using the chosen strategy only.
4. Append the Chain Context block to each PR — do not replace the repo template.
5. Run all three kit gates on each PR branch (CLAUDE.md §5) before requesting review.
6. Keep the tracker PR draft/no-merge until all child PRs are reviewed and integrated.

---

## Chain Context Block

Append this section to `.github/PULL_REQUEST_TEMPLATE.md`; do not replace required issue/checklist
sections.

```markdown
## Chain Context

| Field | Value |
|-------|-------|
| Chain | <feature or stack name> |
| Tracker PR | <#NNN or "Not needed"> |
| Position | <N of total, marked 📍 below> |
| Base | `<target branch>` |
| Depends on | <PR/issue/link or "None"> |
| Follow-up | <next PR or "None"> |
| Review budget | <additions + deletions> / 400 |
| Starts at | <branch, PR, or state this builds on> |
| Ends with | <standalone result delivered by this PR> |

### Chain Overview

\`\`\`
main
 └── #NNN Previous PR
      └── 📍 #NNN This PR
           └── #NNN Next PR (follow-up)
\`\`\`

### Scope
- Includes: <focused destination-file group>
- Excludes: <deferred file groups — name them explicitly>

### Autonomy
- [ ] All three kit gates pass on this PR branch (CLAUDE.md §5)
- [ ] This PR has one deliverable scope
- [ ] This PR can be rolled back without touching unrelated files
- [ ] Tests and docs are included for this unit
```

---

## Output Contract

When splitting a planned PR, return:

- Chosen strategy and rationale
- PR order with destination-file groups per slice
- Current PR boundary and its `📍` position
- Review budget (`additions + deletions / 400`) per slice
- Explicit deferral declaration for what is NOT in this PR (CLAUDE.md §6: silent scope compression
  is a defect, not a tidy scope trim)
- Any `size:exception` rationale if splitting is not feasible

---

## Commands

```bash
# Check PR size before deciding
gh pr view <pr-number> --json additions,deletions,changedFiles,title,url

# Create a tracker PR (Feature Branch Chain)
gh pr create --base main --draft \
  --title "feat(scope): tracker — full feature integration" \
  --body "Tracker PR — do not merge until all child PRs are integrated."

# Create a child PR targeting the tracker branch
gh pr create --base feat/my-feature \
  --title "feat(scope): slice 1 — foundation" \
  --body-file pr-body.md

# Add type label (use REST API — gh pr edit --add-label is broken on this repo)
gh api repos/angeles725/sdd-investigacion/issues/<pr-number>/labels \
  -f 'labels[]=type:feature'
```

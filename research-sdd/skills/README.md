# Research-SDD skills (source of record)

These skills are **versioned here for backup and portability**. The live copy Claude Code loads must sit
under `~/.claude/skills/`. This directory is the git-tracked master; installing = copying it there.

## `research-sdd` — the loop launcher

A thin, user-invocable launcher: `/research-sdd <target> [focus] [new|continue]`. It reads this kit
(`METHODOLOGY.md`, `TARGETS.md`, `toolbelt/tool-registry.md`, `PROMPT-LOOP.md`) as the single source of
truth, resolves the target, resumes from real state, and runs the loop. It does NOT duplicate the loop
rules — kit improvements are inherited automatically.

## Install (or update after editing here)

```sh
mkdir -p ~/.claude/skills/research-sdd
cp research-sdd/skills/research-sdd/SKILL.md ~/.claude/skills/research-sdd/SKILL.md
```

Then it appears as `/research-sdd` in autocomplete (new sessions pick it up automatically).

> Note: the installer (`research-sdd/install/research-sdd-install.sh`) injects a `Kit path:` line into
> the harness prompt so the skill resolves the kit O(1) from the launcher block on any machine.
> No per-user path is hardcoded in `SKILL.md`.

---

## Kit-maintenance skills

These three skills govern work **on the kit itself** — opening issues, preparing PRs, and splitting
oversized PRs. They are not research-loop skills.

### `kit-issue-creation` — issue-first workflow

Trigger: "create a kit issue / bug report / feature request for research-sdd maintenance."

Covers: duplicate search, template selection (`.github/ISSUE_TEMPLATE/bug_report.yml` /
`feature_request.yml`), required fields, the `status:needs-review → status:approved` gate,
solo-repo reality note, and the `gh api` workaround for label application.

```sh
mkdir -p ~/.claude/skills/kit-issue-creation
cp research-sdd/skills/kit-issue-creation/SKILL.md ~/.claude/skills/kit-issue-creation/SKILL.md
```

### `kit-branch-pr` — branch and PR preparation

Trigger: "open / prepare a PR for kit maintenance work."

Covers: branch naming regex, conventional commits, the three kit gates (CLAUDE.md §5), PR template
fields, commit-type → `type:*` label map, the `gh pr edit --add-label` GraphQL GOTCHA and its
`gh api` workaround, and the ~400-line budget check (→ `kit-chained-pr` if exceeded).

```sh
mkdir -p ~/.claude/skills/kit-branch-pr
cp research-sdd/skills/kit-branch-pr/SKILL.md ~/.claude/skills/kit-branch-pr/SKILL.md
```

### `kit-chained-pr` — oversized-PR splitting

Trigger: "PR over ~400 authored lines / stacked PRs / review slices for kit maintenance."

Covers: destination-file grouping rule (CLAUDE.md §3), decision gates (stacked-to-main vs
feature-branch-chain with tracker), the Chain Context block with `📍` position marker, explicit
deferral declaration requirement, and the `gh api` label workaround.

```sh
mkdir -p ~/.claude/skills/kit-chained-pr
cp research-sdd/skills/kit-chained-pr/SKILL.md ~/.claude/skills/kit-chained-pr/SKILL.md
```

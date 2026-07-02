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

> Note: `SKILL.md` hardcodes the kit path `/home/cristian/investigacion/sdd-investigacion/research-sdd`.
> If the kit moves, update that path in both the installed copy and this master.

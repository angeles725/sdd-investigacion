# OpenCode adapter — session-start surfacing

Claude Code surfaces two Research-SDD banners when the **supervisor project** (this kit repo,
`sdd-investigacion`) opens, wired from `.claude/settings.json` `SessionStart` hooks:

1. **Retro sweep** (`sweep-retros.sh`) — pending §18 self-retrospective proposals across all targets.
2. **Kit-clean** (`verify-kit-clean.sh`) — a warning only when the kit is dirty / unpushed (silent when clean).

OpenCode does **not** fire `.claude` hooks. It loads **plugins** at startup instead (see the sibling
`~/.config/opencode/plugins/{engram,skill-registry,model-variants}.ts`, all of which re-implement a
Claude/Codex startup hook as an OpenCode plugin). `research-sdd-sweep.ts` is that same bridge for the
two banners above: on the first `experimental.chat.system.transform` of a session it runs the SAME two
kit scripts and appends their output to the model's system context — OpenCode's analog of a Claude
hook's `additionalContext`.

## Behavior

- Surfaces **only** when the session's working directory is inside the kit repo (the supervisor),
  mirroring the Claude hook which is wired per-project to `sdd-investigacion`. A target-corpus session
  stays quiet.
- Fires **once per session** (a `Set` guard).
- **Read-only** and fail-safe: the scripts never mutate anything; any failure degrades to silence and
  never blocks OpenCode startup or a turn.

## Install (symlink — one authority, no copies)

The canonical source is here in the kit. OpenCode only loads plugins physically present under
`~/.config/opencode/plugins/`, so link it (do not copy — editing stays in the kit):

```sh
ln -sf "$PWD/research-sdd-sweep.ts" ~/.config/opencode/plugins/research-sdd-sweep.ts
```

(Run from this directory, or use the kit-absolute path.) If the kit lives elsewhere, set
`RESEARCH_SDD_KIT` to the `research-sdd` dir before starting OpenCode; the plugin honors it, matching
SKILL.md's "Resolving the kit path".

## Parity note

This is the OpenCode leg of the same surfacing the `.claude/settings.json` `SessionStart` hooks give
Claude Code. Keep the three in mind when the banner logic changes: `sweep-retros-hook.sh` and
`verify-kit-clean-hook.sh` (Claude JSON envelope) and this plugin (OpenCode `system[]` push) all wrap
the SAME two underlying scripts — change the scripts, not the wrappers, so both surfaces stay in sync.

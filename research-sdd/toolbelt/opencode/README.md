# OpenCode adapter — session-start surfacing

Claude Code surfaces four Research-SDD banners when the **supervisor project** (this kit repo,
`sdd-investigacion`) opens, wired from `.claude/settings.json` `SessionStart` hooks:

1. **Retro sweep** (`sweep-retros.sh`) — pending §18 self-retrospective proposals across all targets.
2. **Audit sweep** (`sweep-audits.sh`) — pending §13 audit reports per target.
3. **Registry check** (`verify-registry.sh`) — `TARGETS.md` master-table drift vs the real corpus block count.
4. **Kit-clean** (`verify-kit-clean.sh`) — a warning only when the kit is dirty / unpushed (silent when clean).

OpenCode does **not** fire `.claude` hooks. It loads **plugins** at startup instead (see the sibling
`~/.config/opencode/plugins/{engram,skill-registry,model-variants}.ts`, all of which re-implement a
Claude/Codex startup hook as an OpenCode plugin). `research-sdd-sweep.ts` is that same bridge: on the first `experimental.chat.system.transform` of a
session it runs the same **four** kit scripts and appends their output to the model's system context —
OpenCode's analog of a Claude hook's `additionalContext`. All four scripts (`sweep-retros.sh`,
`sweep-audits.sh`, `verify-registry.sh`, `verify-kit-clean.sh`) correspond to the four `SessionStart`
hooks in `.claude/settings.json`; the Codex `AGENTS.md` section lists the same four for manual run.

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
Claude Code. Keep all three surfaces in mind when the banner logic changes:

- **Claude** wires four `-hook.sh` wrappers (`sweep-retros-hook.sh`, `sweep-audits-hook.sh`,
  `verify-registry-hook.sh`, `verify-kit-clean-hook.sh`) that emit a JSON `additionalContext` envelope.
- **OpenCode** (this plugin) runs the same four base scripts via `system[]` push.
- **Codex** lists all four as manual-run commands in the `AGENTS.md` section (no runtime hook).

All three surfaces reference the same four underlying scripts — edit the scripts, not the wrappers, so
all surfaces stay in sync. Parity is mechanically verified by
`toolbelt/tests/harness-sweep-parity.test.sh`.

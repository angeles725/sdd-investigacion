#!/usr/bin/env bash
# adapters.sh — sourceable ADAPTER TABLE for the multi-harness research-sdd installer.
#
# Mirrors gentle-ai's decoupling: one neutral asset (skills/research-sdd/SKILL.md) is surfaced into
# every AI harness by consulting a per-harness adapter that answers three ORTHOGONAL questions:
#
#   WHERE — path methods : config_root · skills_dir · skill_path · prompt_file · plugin_dir
#   HOW   — strategy enum : prompt_strategy  (markdown-sections — splice a marked block, preserving
#                            surrounding user content; dispatch stays open for future strategies)
#   WHAT  — capability bools : supports_slash_commands · needs_manual_sweep_doc
#
# Every path is derived from a passed-in $home, so NOTHING hardcodes ~/.claude vs ~/.codex — the same
# table renders a plan for any home (that is what lets --dry-run --home <tmp> drive golden tests).
#
# Adding a 4th harness later = ONE new key in each associative array below + one word in
# RESEARCH_SDD_HARNESSES. No installer edit, no new branch.
#
# Sourced, not executed:  . adapters.sh   (then call rsdd_field / rsdd_render_section).

# Registration order = install order for --harness all. Consumed by the installer after it sources
# this file; shellcheck can't see that cross-file use, so silence the false "unused" here.
# shellcheck disable=SC2034
RESEARCH_SDD_HARNESSES="claude opencode codex reasonix"

# --- THE TABLE (only home-independent facts live here; paths are derived from these + $home) --------
# config root, relative to $home
declare -A _RSDD_CONFIG_ROOT_REL=(
  [claude]=".claude"
  [opencode]=".config/opencode"
  [codex]=".codex"
  [reasonix]=".reasonix"
)
# system-prompt file name inside the config root
declare -A _RSDD_PROMPT_FILE_NAME=(
  [claude]="CLAUDE.md"
  [opencode]="AGENTS.md"
  [codex]="AGENTS.md"
  [reasonix]="AGENTS.md"
)
# HOW the launcher is surfaced into that prompt file
declare -A _RSDD_PROMPT_STRATEGY=(
  [claude]="markdown-sections"
  [opencode]="markdown-sections"
  [codex]="markdown-sections"
  [reasonix]="markdown-sections"
)
# WHAT the harness can do: does a SKILL surface as a slash command?
# reasonix: skills are invoked via a run_skill tool; slash commands are a separate namespace
# fed by commands/ — so the SKILL.md launcher is NOT a slash command.
declare -A _RSDD_SUPPORTS_SLASH=(
  [claude]="false"
  [opencode]="true"
  [codex]="false"
  [reasonix]="false"
)
# plugin directory name inside the config root (empty = harness has none).
# reasonix: [[plugins]] entries are MCP servers declared in config.toml, not a skill-plugin dir.
declare -A _RSDD_PLUGIN_DIR_NAME=(
  [claude]=""
  [opencode]="plugins"
  [codex]=""
  [reasonix]=""
)
# WHAT: does the harness lack an automated session-start sweep (no hook AND no plugin), so the
# manual-run fallback must be documented in its prompt section?
# (claude=hook, opencode=plugin, codex=none, reasonix=hook via ~/.reasonix/settings.json)
declare -A _RSDD_NEEDS_SWEEP=(
  [claude]="false"
  [opencode]="false"
  [codex]="true"
  [reasonix]="false"
)
# WHAT: does the harness surface a short note (in its prompt file) that the installer registers the
# skill's MCP servers automatically into its TOML config?
# (codex + reasonix; claude/opencode manage MCP elsewhere)
declare -A _RSDD_NEEDS_MCP_CONFIG_DOC=(
  [claude]="false"
  [opencode]="false"
  [codex]="true"
  [reasonix]="true"
)
# WHERE: the user-owned TOML config into which the installer idempotently SPLICES the skill's MCP
# server entries (a marked `# research-sdd:start/end` block that preserves all surrounding user
# config). Empty = the harness manages MCP elsewhere and needs no config-file registration.
declare -A _RSDD_MCP_CONFIG_NAME=(
  [claude]=""
  [opencode]=""
  [codex]="config.toml"
  [reasonix]="config.toml"
)
# WHAT: the TOML shape used by this harness's MCP config file. Drives rsdd_render_mcp_toml and the
# conflict-detection ERE — both dispatch on shape, never on harness name.
#   mcp-servers-table — [mcp_servers.X] named tables (codex)
#   plugins-array     — [[plugins]] array-of-tables keyed by `name` (reasonix)
#   ""                — harness has no MCP config file; rsdd_render_mcp_toml is never called
# shellcheck disable=SC2034
declare -A _RSDD_MCP_TOML_SHAPE=(
  [claude]=""
  [opencode]=""
  [codex]="mcp-servers-table"
  [reasonix]="plugins-array"
)
# WHERE: the skill source file, as a path RELATIVE TO the kit root. Harnesses that require a
# runtime-adapter section (opencode) have their own source under toolbelt/opencode/ so the adapter
# content stays versioned alongside the other OpenCode-specific runtime artifacts. Generic harnesses
# (claude, codex, reasonix) use the neutral shared source under skills/research-sdd/.
declare -A _RSDD_SKILL_SRC_RELKIT=(
  [claude]="skills/research-sdd/SKILL.md"
  [opencode]="toolbelt/opencode/SKILL.md"
  [codex]="skills/research-sdd/SKILL.md"
  [reasonix]="skills/research-sdd/SKILL.md"
)

# rsdd_field <harness> <field> [home] — the UNIFORM accessor. The case is on FIELD NAME (generic),
# never on harness: all per-harness divergence is looked up from the arrays above.
rsdd_field() {
  local harness="$1" field="$2" home="${3:-$HOME}"
  local rel="${_RSDD_CONFIG_ROOT_REL[$harness]:-}"
  if [ -z "$rel" ]; then echo "rsdd_field: unknown harness '$harness'" >&2; return 2; fi
  local root="$home/$rel" plug
  case "$field" in
    config_root)             printf '%s\n' "$root" ;;
    skills_dir)              printf '%s\n' "$root/skills" ;;
    skill_path)              printf '%s\n' "$root/skills/research-sdd/SKILL.md" ;;
    prompt_file)             printf '%s\n' "$root/${_RSDD_PROMPT_FILE_NAME[$harness]}" ;;
    prompt_strategy)         printf '%s\n' "${_RSDD_PROMPT_STRATEGY[$harness]}" ;;
    supports_slash_commands) printf '%s\n' "${_RSDD_SUPPORTS_SLASH[$harness]}" ;;
    needs_manual_sweep_doc)  printf '%s\n' "${_RSDD_NEEDS_SWEEP[$harness]}" ;;
    needs_mcp_config_doc)    printf '%s\n' "${_RSDD_NEEDS_MCP_CONFIG_DOC[$harness]}" ;;
    plugin_dir)
      plug="${_RSDD_PLUGIN_DIR_NAME[$harness]}"
      if [ -n "$plug" ]; then printf '%s\n' "$root/$plug"; else printf '\n'; fi ;;
    mcp_config_file)
      plug="${_RSDD_MCP_CONFIG_NAME[$harness]}"
      if [ -n "$plug" ]; then printf '%s\n' "$root/$plug"; else printf '\n'; fi ;;
    mcp_toml_shape) printf '%s\n' "${_RSDD_MCP_TOML_SHAPE[$harness]:-}" ;;
    skill_src_relkit) printf '%s\n' "${_RSDD_SKILL_SRC_RELKIT[$harness]:-}" ;;
    *) echo "rsdd_field: unknown field '$field'" >&2; return 2 ;;
  esac
}

# rsdd_render_section <harness> [home] — the single launcher body, wrapped in the idempotency markers.
# Identical across harnesses EXCEPT the manual-sweep fallback, which is appended only where the table
# says the harness has no automated sweep. The launcher TEXT itself is not forked per harness.
rsdd_render_section() {
  local harness="$1" home="${2:-$HOME}" skill_path needs_sweep needs_mcp_doc
  skill_path="$(rsdd_field "$harness" skill_path "$home")"
  needs_sweep="$(rsdd_field "$harness" needs_manual_sweep_doc "$home")"
  needs_mcp_doc="$(rsdd_field "$harness" needs_mcp_config_doc "$home")"
  printf '%s\n' '<!-- research-sdd:start -->'
  printf '%s\n' '## Research-SDD'
  printf '%s\n' ''
  printf '%s\n' 'Run the `research-sdd` skill to drive the investigation loop. It is a THIN launcher; the'
  printf '%s\n' 'single source of truth is the kit (`$RESEARCH_SDD_KIT`, else the default checkout).'
  printf '%s\n' "Skill file: $skill_path"
  if [ "$needs_sweep" = "true" ]; then
    printf '%s\n' ''
    printf '%s\n' 'Session-start sweep (this harness fires NO pre-turn hook — run MANUALLY at session'
    printf '%s\n' 'start; all read-only, degrade to silence on failure):'
    printf '%s\n' '  Single command (recommended): `toolbelt/sweep-all.sh`'
    printf '%s\n' '  Individual scripts (canonical; sweep-all.sh runs these in sequence):'
    printf '%s\n' '  - `toolbelt/sweep-retros.sh`     — pending section 18 self-retrospective proposals'
    printf '%s\n' '  - `toolbelt/sweep-audits.sh`     — pending section 13 audit reports'
    printf '%s\n' '  - `toolbelt/verify-registry.sh`  — TARGETS.md master-table drift'
    printf '%s\n' '  - `toolbelt/verify-kit-clean.sh` — kit dirty / unpushed warning'
    printf '%s\n' '  - `toolbelt/sweep-tools.sh`      — unrecorded tools across all targets'
  fi
  if [ "$needs_mcp_doc" = "true" ]; then
    # Derive the config file path as a home-relative ~/... string (machine-independent).
    # The leading ~ is a LITERAL display character, not a shell expansion.
    local mcp_shape mcp_cfg_file mcp_cfg_rel
    mcp_shape="$(rsdd_field "$harness" mcp_toml_shape)"
    mcp_cfg_file="$(rsdd_field "$harness" mcp_config_file "$home")"
    # shellcheck disable=SC2088
    mcp_cfg_rel='~/'"${mcp_cfg_file#"$home/"}"
    printf '%s\n' ''
    printf '%s\n' 'MCP servers this skill relies on (engram `mem_*`, codegraph) are registered automatically'
    printf 'into `%s` by the installer — an idempotent marked block\n' "$mcp_cfg_rel"
    printf '%s\n' '(`# research-sdd:start` … `# research-sdd:end`) that preserves all surrounding user config.'
    # Risk sentence is shape-specific: duplicate-table semantics differ between harnesses.
    if [ "$mcp_shape" = "mcp-servers-table" ]; then
      printf '%s\n' 'If you already define your own `[mcp_servers.engram]`, the installer warns and skips rather'
      printf '%s\n' 'than duplicate it (TOML forbids duplicate tables); remove your table to let it manage them.'
    elif [ "$mcp_shape" = "plugins-array" ]; then
      # CRITICAL DIVERGENCE from codex: duplicate [[plugins]] entries are VALID TOML — reasonix
      # silently de-duplicates by `name` with LAST WINS and no warning. The installer therefore
      # refuses to append rather than silently shadow a user's own entry.
      printf '%s\n' 'If you already define your own `name = "engram"` plugin entry, the installer warns and'
      printf '%s\n' 'skips rather than shadow it silently (reasonix de-duplicates [[plugins]] by name with last'
      printf '%s\n' 'entry winning, no warning); remove your entry to let it manage them.'
    fi
  fi
  printf '%s\n' '<!-- research-sdd:end -->'
}

# rsdd_render_mcp_toml <shape> — emit the MCP-server block the installer SPLICES into a harness's
# config.toml, wrapped in TOML `#`-comment idempotency markers. Dispatches to a shape-specific
# renderer mirroring the prompt_strategy dispatch pattern (_surface__${strategy}). Unknown shape
# fails loudly (non-zero, message on stderr) — never emits an empty block silently (§7).
_rsdd_mcp_toml__mcp_servers_table() {
  printf '%s\n' '# research-sdd:start'
  printf '%s\n' '# research-sdd-managed MCP servers — this block is spliced idempotently by the installer.'
  printf '%s\n' '# Edit via the installer, not by hand; surrounding user config is preserved.'
  printf '%s\n' '[mcp_servers.engram]'
  printf '%s\n' 'command = "engram"'
  printf '%s\n' 'args = ["mcp", "--tools=agent"]'
  printf '%s\n' ''
  printf '%s\n' '[mcp_servers.codegraph]'
  printf '%s\n' 'command = "codegraph"'
  printf '%s\n' 'args = ["serve", "--mcp"]'
  printf '%s\n' '# research-sdd:end'
}

_rsdd_mcp_toml__plugins_array() {
  printf '%s\n' '# research-sdd:start'
  printf '%s\n' '# research-sdd-managed MCP servers — this block is spliced idempotently by the installer.'
  printf '%s\n' '# Edit via the installer, not by hand; surrounding user config is preserved.'
  printf '%s\n' '[[plugins]]'
  printf '%s\n' 'name    = "engram"'
  printf '%s\n' 'command = "engram"'
  printf '%s\n' 'args    = ["mcp", "--tools=agent"]'
  printf '%s\n' ''
  printf '%s\n' '[[plugins]]'
  printf '%s\n' 'name    = "codegraph"'
  printf '%s\n' 'command = "codegraph"'
  printf '%s\n' 'args    = ["serve", "--mcp"]'
  printf '%s\n' '# research-sdd:end'
}

rsdd_render_mcp_toml() {
  local shape="$1" dispatch
  dispatch="_rsdd_mcp_toml__${shape//-/_}"
  if ! declare -F "$dispatch" >/dev/null; then
    printf 'rsdd_render_mcp_toml: unknown shape "%s"\n' "$shape" >&2
    return 2
  fi
  "$dispatch"
}

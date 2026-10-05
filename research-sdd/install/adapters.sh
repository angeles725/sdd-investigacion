#!/usr/bin/env bash
# adapters.sh — sourceable ADAPTER TABLE for the multi-harness research-sdd installer.
#
# Mirrors gentle-ai's decoupling: one neutral asset (skills/research-sdd/SKILL.md) is surfaced into
# every AI harness by consulting a per-harness adapter that answers three ORTHOGONAL questions:
#
#   WHERE — path methods : config_root · skills_dir · skill_path · prompt_file
#   HOW   — strategy enum : prompt_strategy  (markdown-sections — splice a marked block, preserving
#                            surrounding user content; dispatch stays open for future strategies)
#   WHAT  — capability bools : supports_slash_commands · needs_manual_sweep_doc
#
# Every path is derived from a passed-in $home, so NOTHING hardcodes ~/.claude vs ~/.pi — the same
# table renders a plan for any home (that is what lets --dry-run --home <tmp> drive golden tests).
#
# Adding another harness later = ONE new key in each associative array below + one word in
# RESEARCH_SDD_HARNESSES. No installer edit, no new branch.
#
# Sourced, not executed:  . adapters.sh   (then call rsdd_field / rsdd_render_section).

# Registration order = install order for --harness all. Consumed by the installer after it sources
# this file; shellcheck can't see that cross-file use, so silence the false "unused" here.
# shellcheck disable=SC2034
RESEARCH_SDD_HARNESSES="claude pi gentle-shell"

# --- THE TABLE (only home-independent facts live here; paths are derived from these + $home) --------
# config root, relative to $home
declare -A _RSDD_CONFIG_ROOT_REL=(
  [claude]=".claude"
  [pi]=".pi/agent"
  [gentle-shell]=".gentle-shell/agent"
)
# system-prompt file name inside the config root
declare -A _RSDD_PROMPT_FILE_NAME=(
  [claude]="CLAUDE.md"
  [pi]="AGENTS.md"
  [gentle-shell]="AGENTS.md"
)
# HOW the launcher is surfaced into that prompt file
declare -A _RSDD_PROMPT_STRATEGY=(
  [claude]="markdown-sections"
  [pi]="markdown-sections"
  [gentle-shell]="markdown-sections"
)
# WHAT the harness can do: does a LITERAL `/research-sdd` slash command exist for this harness?
# `true` is only valid when one of two sources backs it:
#   (a) skill-native — the harness itself exposes the installed skill as /research-sdd (no harness
#       registered today; a future one must be added to the documented list in the install suite's
#       slash-invariant case), or
#   (b) prompt template — _RSDD_PROMPT_TEMPLATE_REL is non-empty, so the installer deploys the file the
#       harness turns into the command (pi + gentle-shell: prompts/research-sdd.md becomes
#       /research-sdd; their skill alone is only /skill:research-sdd).
# The install suite enforces this: supports_slash=true with neither source fails.
declare -A _RSDD_SUPPORTS_SLASH=(
  [claude]="false"
  [pi]="true"
  [gentle-shell]="true"
)
# WHAT: does the harness lack an automated session-start sweep (no hook), so the
# manual-run fallback must be documented in its prompt section?
# (claude=hook, pi/gentle-shell=none — Pi has no SessionStart hook for the kit to wire; OpenCode
# dropped #954; codex and reasonix dropped #1471)
declare -A _RSDD_NEEDS_SWEEP=(
  [claude]="false"
  [pi]="true"
  [gentle-shell]="true"
)
# WHERE: an OPTIONAL slash-command prompt template, as a path RELATIVE TO the harness config root.
# Empty/absent = the harness gets no template and the installer deploys nothing extra (claude). Set for Pi and its isolated-home
# wrapper gentle-shell: Pi turns <agent-dir>/prompts/<name>.md into the slash command /<name>, so deploying prompts/research-sdd.md is what gives them a real
# `/research-sdd` (their skills are only reachable as /skill:research-sdd).
declare -A _RSDD_PROMPT_TEMPLATE_REL=(
  [pi]="prompts/research-sdd.md"
  [gentle-shell]="prompts/research-sdd.md"
)
# WHERE: the skill source file, as a path RELATIVE TO the kit root. Every harness
# (claude, pi, gentle-shell) uses the neutral shared source under skills/research-sdd/.
# Note: OpenCode support was dropped on 2026-09-23 (#954); codex and reasonix on 2026-10-03 (#1471).
declare -A _RSDD_SKILL_SRC_RELKIT=(
  [claude]="skills/research-sdd/SKILL.md"
  [pi]="skills/research-sdd/SKILL.md"
  [gentle-shell]="skills/research-sdd/SKILL.md"
)
# WHERE: the read-only reviewer agent definitions (kit issue #1714), as a directory RELATIVE TO the kit
# root holding one <name>.md Claude Code subagent definition per kit review role; deployed to
# <config_root>/agents/. Empty/absent = the harness gets none (only claude has a subagent format the
# kit ships definitions for). Every definition must grant no Edit/Write/NotebookEdit (the install suite
# enforces it).
declare -A _RSDD_AGENTS_SRC_RELKIT=(
  [claude]="agents/claude"
)
# WHAT: the per-harness DEFAULT prompt profile (kit issue #993 WU2) — used only when the
# installer receives neither an explicit --profile flag nor a non-empty $RESEARCH_SDD_PROFILE
# env var (see rsdd_resolve_profile below). "claude" is the byte-identical-to-today profile;
# any other value names a research-sdd/profiles/<name>.slots.md render-profile.sh renders at
# install time. pi and gentle-shell default to "general" because their target models are not
# Claude-family.
declare -A _RSDD_DEFAULT_PROFILE=(
  [claude]="claude"
  [pi]="general"
  [gentle-shell]="general"
)

# rsdd_field <harness> <field> [home] — the UNIFORM accessor. The case is on FIELD NAME (generic),
# never on harness: all per-harness divergence is looked up from the arrays above.
rsdd_field() {
  # ${HOME:-} (not bare $HOME) so a caller that omits <home> for a field that never reads it
  # (prompt_profile, skill_src_relkit, ...) never dies under `set -u` with $HOME itself unset —
  # surfaced by rsdd_resolve_profile calling this without a home for the home-independent
  # prompt_profile field (kit issue #993 WU2, AX8 regression test).
  local harness="$1" field="$2" home="${3:-${HOME:-}}"
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
    prompt_template_path)
      plug="${_RSDD_PROMPT_TEMPLATE_REL[$harness]:-}"
      if [ -n "$plug" ]; then printf '%s\n' "$root/$plug"; else printf '\n'; fi ;;
    agents_dir)       printf '%s\n' "$root/agents" ;;
    agents_src_relkit) printf '%s\n' "${_RSDD_AGENTS_SRC_RELKIT[$harness]:-}" ;;
    skill_src_relkit) printf '%s\n' "${_RSDD_SKILL_SRC_RELKIT[$harness]:-}" ;;
    prompt_profile) printf '%s\n' "${_RSDD_DEFAULT_PROFILE[$harness]:-}" ;;
    *) echo "rsdd_field: unknown field '$field'" >&2; return 2 ;;
  esac
}

# rsdd_render_prompt_template <harness> [home] — the slash-command prompt template body deployed at
# prompt_template_path (Pi: <agent-dir>/prompts/research-sdd.md becomes /research-sdd). A THIN launcher
# like the AGENTS.md section: it points the agent at the installed skill's ABSOLUTE path and passes the
# user's slash-command arguments through as the request (Pi substitutes $ARGUMENTS).
rsdd_render_prompt_template() {
  local harness="$1" home="${2:-$HOME}" skill_path
  skill_path="$(rsdd_field "$harness" skill_path "$home")" || return 2
  printf '%s\n' '---'
  printf '%s\n' 'description: Run the research-sdd investigation loop'
  printf '%s\n' 'argument-hint: "<target or question>"'
  printf '%s\n' '---'
  printf '%s\n' "Read the research-sdd skill at $skill_path and follow it exactly to run the"
  printf '%s\n' 'investigation loop. Treat the text below as the target or question to investigate'
  printf '%s\n' '(if it is empty, ask which target to investigate):'
  printf '%s\n' ''
  printf '%s\n' '$ARGUMENTS'
}

# rsdd_valid_profile <profile> <kit> — true (0) iff <profile> is a KNOWN profile name: the
# literal "claude" (always valid, needs no profile file), or any name for which
# <kit>/profiles/<profile>.slots.md exists. Used by both the installer (validate --profile /
# $RESEARCH_SDD_PROFILE / a per-harness default before touching the filesystem) and
# verify-skill-drift.sh (validate before re-rendering a profile to diff against).
rsdd_valid_profile() {
  local profile="$1" kit="$2"
  [ "$profile" = "claude" ] && return 0
  # Enforce the safe-name charset BEFORE any path is built or the filesystem is touched — a
  # profile name is a KEY, never a path fragment. Without this, "../profiles/general" resolved
  # (via kit/profiles/ + ../ cancelling out) to the real general.slots.md and passed as "valid",
  # then flowed into a render/clean directory path where the SAME ".." escaped the intended
  # <config_root>/research-sdd/profile/ tree (kit issue #1024 review F2 — reproduced against
  # 6a0ff24: this exact string deleted a sibling directory via _rsdd_clean_profile_dir's rm -rf).
  # This mirrors render-profile.sh's own PROFILE argument check (kept independent — this function
  # is the installer/verify-skill-drift choke point; render-profile.sh's is a second, later one).
  [[ "$profile" =~ ^[a-z0-9_-]+$ ]] || return 1
  [ -f "$kit/profiles/${profile}.slots.md" ]
}

# rsdd_list_profiles <kit> — space-separated list of every known profile name: "claude" first,
# then every research-sdd/profiles/*.slots.md basename found under <kit>, for error messages.
rsdd_list_profiles() {
  local kit="$1" f base out="claude"
  if [ -d "$kit/profiles" ]; then
    for f in "$kit"/profiles/*.slots.md; do
      [ -e "$f" ] || continue
      base="$(basename "$f" .slots.md)"
      out="$out $base"
    done
  fi
  printf '%s\n' "$out"
}

# rsdd_resolve_profile <harness> [profile_flag] — resolves the EFFECTIVE prompt profile for
# <harness> and prints "<profile>:<source>" (source is one of flag|env|default). Precedence:
#   1. profile_flag, when non-empty (an explicit --profile CLI argument)
#   2. $RESEARCH_SDD_PROFILE, when set and non-empty
#   3. this harness's per-harness default (_RSDD_DEFAULT_PROFILE via the prompt_profile field)
# Does NOT validate the result — callers run rsdd_valid_profile before acting on it, so an
# unknown profile is reported once with full context (harness + source) rather than here.
rsdd_resolve_profile() {
  local harness="$1" flag="${2:-}"
  if [ -n "$flag" ]; then
    printf '%s:flag\n' "$flag"
  elif [ -n "${RESEARCH_SDD_PROFILE:-}" ]; then
    printf '%s:env\n' "$RESEARCH_SDD_PROFILE"
  else
    printf '%s:default\n' "$(rsdd_field "$harness" prompt_profile)"
  fi
}

# rsdd_render_section <harness> [home] [kit] — the single launcher body, wrapped in idempotency markers.
# Identical across harnesses EXCEPT the manual-sweep fallback, which is appended only where the table
# says the harness has no automated sweep. The launcher TEXT itself is not forked per harness.
#
# <kit> is the absolute kit root — emitted as 'Kit path: ~/...' when under $home (tilde-relative,
# machine-independent display), else as an absolute path. MUST NOT be empty: an empty kit path is an
# operational failure (§7 anti-silent-zero) — the function fails loudly so the installer propagates
# the error rather than silently injecting an unusable 'Kit path: ' line.
rsdd_render_section() {
  local harness="$1" home="${2:-$HOME}" kit="${3:-}" skill_path needs_sweep
  if [ -z "$kit" ]; then
    printf 'rsdd_render_section: kit path must not be empty\n' >&2
    return 2
  fi
  skill_path="$(rsdd_field "$harness" skill_path "$home")"
  needs_sweep="$(rsdd_field "$harness" needs_manual_sweep_doc "$home")"
  # Emit the kit path as ~/... when it lives under $home; else as the absolute path.
  # The leading ~ is a LITERAL display character for the human reading the prompt — not a shell expansion.
  local kit_rel
  if [ "${kit#"$home/"}" != "$kit" ]; then
    # shellcheck disable=SC2088
    kit_rel='~/'"${kit#"$home/"}"
  else
    kit_rel="$kit"
  fi
  printf '%s\n' '<!-- research-sdd:start -->'
  printf '%s\n' '## Research-SDD'
  printf '%s\n' ''
  printf '%s\n' 'Run the `research-sdd` skill to drive the investigation loop. It is a THIN launcher; the'
  printf '%s\n' 'single source of truth is the kit (`$RESEARCH_SDD_KIT`, else the default checkout).'
  printf '%s\n' "Skill file: $skill_path"
  printf '%s\n' "Kit path: $kit_rel"
  if [ "$needs_sweep" = "true" ]; then
    printf '%s\n' ''
    printf '%s\n' 'MANDATORY session steps — this harness has no hooks: sweeps, the retro gate and delta'
    printf '%s\n' 'auto-seeding are enforced by Claude Code only (kit issue #1110), so YOU run them by hand.'
    printf '%s\n' ''
    printf '%s\n' 'Session-start sweep (MANDATORY — this harness fires NO pre-turn hook; run MANUALLY at'
    printf '%s\n' 'session start; all read-only, degrade to silence on failure):'
    printf '%s\n' '  Single command (recommended): `toolbelt/sweep-all.sh`'
    printf '%s\n' '  Individual scripts (canonical; sweep-all.sh runs these in sequence):'
    printf '%s\n' '  - `toolbelt/sweep-retros.sh`        — pending section 18 self-retrospective proposals'
    printf '%s\n' '  - `toolbelt/sweep-audits.sh`        — pending section 13 audit reports'
    printf '%s\n' '  - `toolbelt/sweep-breakthroughs.sh` — unindexed/drifted section 22 breakthrough ledger entries'
    printf '%s\n' '  - `toolbelt/verify-registry.sh`     — TARGETS.md master-table drift'
    printf '%s\n' '  - `toolbelt/verify-kit-clean.sh`    — kit dirty / unpushed warning'
    printf '%s\n' '  - `toolbelt/sweep-tools.sh`         — unrecorded tools across all targets'
    printf '%s\n' '  - `toolbelt/verify-tool-catalog.sh` — installed tools missing a capability-catalog entry'
    printf '%s\n' '  - `toolbelt/verify-skill-drift.sh`  — deployed SKILL.md(s) diverged from kit source'
    printf '%s\n' ''
    printf '%s\n' 'Session-end retro (MANDATORY — there is no Stop hook here, so nothing blocks you): the run is'
    printf '%s\n' 'not over until the retro exists. Once it is written, seed its deltas by hand:'
    printf '%s\n' '  `toolbelt/stage-retro-issues.sh <retro> --apply`'
  fi
  printf '%s\n' '<!-- research-sdd:end -->'
}

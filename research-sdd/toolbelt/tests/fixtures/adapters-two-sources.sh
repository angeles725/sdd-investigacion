#!/usr/bin/env bash
# adapters-two-sources.sh — test fixture: two harnesses with DISTINCT skill_src_relkit values.
#
# NOT a real adapters.sh. Used only by verify-skill-drift.test.sh to verify that the
# per-harness source lookup (rsdd_field $h skill_src_relkit) is actually used when
# iterating harnesses in --all mode. No installed harness in the real adapters.sh
# has a source distinct from skills/research-sdd/SKILL.md after OpenCode removal,
# so this fixture proves the lookup with two synthetic harnesses that differ.
#
# harness_a → skills/source_a/SKILL.md
# harness_b → skills/source_b/SKILL.md  (distinct — TOOTH E bites on this difference)

# shellcheck disable=SC2034  # read by SUT after sourcing (for h in $RESEARCH_SDD_HARNESSES)
RESEARCH_SDD_HARNESSES="harness_a harness_b"

declare -A _RSDD_SKILL_SRC_RELKIT=(
  [harness_a]="skills/source_a/SKILL.md"
  [harness_b]="skills/source_b/SKILL.md"
)
declare -A _RSDD_CONFIG_ROOT_REL=(
  [harness_a]=".harness_a"
  [harness_b]=".harness_b"
)

# rsdd_field: minimal subset needed by verify-skill-drift.sh
rsdd_field() {
  local harness="$1" field="$2" home="${3:-${HOME:-}}"
  local rel="${_RSDD_CONFIG_ROOT_REL[$harness]:-}"
  if [ -z "$rel" ]; then
    echo "rsdd_field: unknown harness '$harness'" >&2
    return 2
  fi
  local root="$home/$rel"
  case "$field" in
    config_root)      printf '%s\n' "$root" ;;
    skills_dir)       printf '%s\n' "$root/skills" ;;
    skill_path)       printf '%s\n' "$root/skills/research-sdd/SKILL.md" ;;
    skill_src_relkit) printf '%s\n' "${_RSDD_SKILL_SRC_RELKIT[$harness]:-}" ;;
    # Fields not needed by verify-skill-drift.sh — return empty (not an error)
    prompt_file|prompt_strategy|supports_slash_commands|needs_manual_sweep_doc|\
    needs_mcp_config_doc|plugin_dir|mcp_config_file|mcp_toml_shape)
      printf '\n' ;;
    *) echo "rsdd_field: unknown field '$field'" >&2; return 2 ;;
  esac
}

#!/usr/bin/env bash
# research-sdd-install.sh — kit-owned, pure-bash multi-harness installer.
#
# Surfaces the single neutral asset (skills/research-sdd/SKILL.md) + a thin launcher into every AI
# harness's OWN paths by iterating the adapter table in adapters.sh. The loop body has ZERO
# per-harness `if`/`case`: WHERE/HOW/WHAT all come from the table, so a 4th harness is one table row.
#
# Usage:
#   research-sdd-install.sh [--harness claude|opencode|codex|all] [--home <dir>] [--dry-run]
#
#   --harness  which harness(es) to install into (default: all, in registration order)
#   --home     the home dir whose config roots are targeted (default: $HOME)
#   --dry-run  print the exact plan (files + rendered section) WITHOUT touching the filesystem
#
# Idempotent: re-running is a clean update, never a duplicate. markdown-sections splices a marked
# block into a SHARED prompt file, preserving all surrounding user content (including the harness's
# own global system prompt, e.g. opencode's ~/.config/opencode/AGENTS.md).
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"
SRC_SKILL="$KIT/skills/research-sdd/SKILL.md"
# shellcheck source=adapters.sh
. "$SELF/adapters.sh"

usage() { sed -n '3,17p' "$SELF/$(basename "$0")" | sed 's/^# \{0,1\}//'; }

# --- prompt-surfacing strategies: dispatched by the STRATEGY VALUE, never by harness name ----------
# Each prints its plan line(s) + the rendered section, then (unless dry) performs the write.
emit_section() { printf '%s\n' "$1" | sed 's/^/  | /'; }

# Write $tmp back onto $file. A symlinked target is written THROUGH (link + real target preserved);
# a regular file is replaced atomically via mv. Returns nonzero on any write failure.
_rsdd_write_back() {
  local tmp="$1" file="$2"
  if [ -L "$file" ]; then
    # `> "$file"` follows the link and truncates its TARGET, so the symlink itself survives and the
    # real file it points at is updated in place — never severed into a plain file.
    if cat "$tmp" > "$file"; then rm -f "$tmp"; else rm -f "$tmp"; return 1; fi
  else
    mv -f "$tmp" "$file"
  fi
}

# markdown-sections: the prompt file is SHARED — splice our marked block, preserving everything else.
# The rewrite removes ONLY a well-formed start..end pair (no nested start between them). An orphaned
# start marker (no matching end, or a second start before the end — a hand-edited/partial file) is
# treated as user content: it is PRESERVED verbatim and a fresh section is appended, never truncated.
_surface__markdown_sections() {
  local harness="$1" home="$2" file="$3" dry="$4" section
  section="$(rsdd_render_section "$harness" "$home")"
  printf '  SPLICE  %s  [markdown-sections: marker <!-- research-sdd:start/end -->]\n' "$file"
  emit_section "$section"
  [ "$dry" = 1 ] && return 0
  mkdir -p "$(dirname "$file")" || { echo "research-sdd-install: mkdir failed for $(dirname "$file")" >&2; return 1; }
  if [ -f "$file" ] && grep -q '<!-- research-sdd:start -->' "$file"; then
    local tmp aw; tmp="$(mktemp)" || return 1
    # Remove the FIRST well-formed start..end pair; keep every other line verbatim. If a start has no
    # matching end (orphan), flush it back out and signal via exit 3 so we can warn (exit 0 = clean).
    awk '
      BEGIN { done=0; inblk=0; orphan=0 }
      {
        if (!done && !inblk && $0 ~ /<!-- research-sdd:start -->/) { inblk=1; buf=$0 ORS; next }
        if (inblk) {
          if ($0 ~ /<!-- research-sdd:start -->/) { printf "%s", buf; orphan=1; buf=$0 ORS; next }
          if ($0 ~ /<!-- research-sdd:end -->/)   { inblk=0; done=1; buf=""; next }
          buf=buf $0 ORS; next
        }
        print
      }
      END { if (inblk) { printf "%s", buf; orphan=1 } exit (orphan?3:0) }
    ' "$file" > "$tmp"; aw=$?
    if [ "$aw" = 3 ]; then
      printf 'research-sdd-install: WARNING malformed research-sdd marker in %s (start without matching end) — preserved existing content and appended a fresh section; please remove the stray marker\n' "$file" >&2
    fi
    printf '%s\n' "$section" >> "$tmp"
    _rsdd_write_back "$tmp" "$file" || { echo "research-sdd-install: write failed for $file" >&2; return 1; }
  else
    { [ -f "$file" ] && printf '\n'; printf '%s\n' "$section"; } >> "$file" \
      || { echo "research-sdd-install: append failed for $file" >&2; return 1; }
  fi
}

# --- the ONE install loop body — table-driven, no per-harness branching --------------------------
install_one() {
  local h="$1" home="$2" dry="$3" rc=0
  local skill_path prompt_file strategy plugin_dir slash dispatch
  skill_path="$(rsdd_field "$h" skill_path "$home")"
  prompt_file="$(rsdd_field "$h" prompt_file "$home")"
  strategy="$(rsdd_field "$h" prompt_strategy "$home")"
  plugin_dir="$(rsdd_field "$h" plugin_dir "$home")"
  slash="$(rsdd_field "$h" supports_slash_commands "$home")"

  printf 'harness=%s\n' "$h"

  # 1. neutral asset → this harness's skills dir (check every filesystem-mutating step)
  printf '  INSTALL %s (from kit skills/research-sdd/SKILL.md)\n' "$skill_path"
  if [ "$dry" != 1 ]; then
    if ! mkdir -p "$(dirname "$skill_path")"; then
      echo "research-sdd-install: [$h] mkdir failed for $(dirname "$skill_path")" >&2; rc=1
    elif ! cp "$SRC_SKILL" "$skill_path"; then
      echo "research-sdd-install: [$h] cp failed → $skill_path" >&2; rc=1
    fi
  fi

  # 2. launcher → this harness's prompt file, via the strategy the TABLE named (data, not a branch)
  dispatch="_surface__${strategy//-/_}"
  if ! declare -F "$dispatch" >/dev/null; then
    echo "research-sdd-install: [$h] no surfacing strategy '$strategy'" >&2; return 2
  fi
  if ! "$dispatch" "$h" "$home" "$prompt_file" "$dry"; then
    echo "research-sdd-install: [$h] surfacing launcher failed ($prompt_file)" >&2; rc=1
  fi

  # 3. plugin note — printed only when the table gives this harness a plugin dir (opencode)
  if [ -n "$plugin_dir" ]; then
    printf '  PLUGIN  %s (symlink research-sdd-sweep.ts — see toolbelt/opencode/README.md)\n' "$plugin_dir"
  fi
  printf '  slash_commands=%s\n' "$slash"
  return "$rc"
}

main() {
  local harness="all" home="$HOME" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) harness="${2:-}"; shift 2 ;;
      --home)    home="${2:-}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) echo "research-sdd-install: unknown argument '$1'" >&2; usage >&2; return 2 ;;
    esac
  done
  [ -f "$SRC_SKILL" ] || { echo "research-sdd-install: source SKILL not found: $SRC_SKILL" >&2; return 2; }

  local list
  if [ "$harness" = all ]; then list="$RESEARCH_SDD_HARNESSES"; else list="$harness"; fi

  local h
  for h in $list; do
    if [ -z "${_RSDD_CONFIG_ROOT_REL[$h]:-}" ]; then
      echo "research-sdd-install: unknown harness '$h' (known: $RESEARCH_SDD_HARNESSES all)" >&2
      return 2
    fi
  done
  # Aggregate: a mid-loop harness failure must NOT abort the run (still install the writable ones),
  # but the overall exit code must be nonzero if ANY harness failed. Dry-run mutates nothing → 0.
  local rc=0
  for h in $list; do
    install_one "$h" "$home" "$dry" || rc=1
  done
  return "$rc"
}

main "$@"

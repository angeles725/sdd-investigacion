#!/usr/bin/env bash
# hook-kit-run.sh <kit-relative-script> [args...] — run a research-sdd kit script with the kit resolved at RUN time (kit #2175).
#
# WHY: a tracked .claude/settings.json that names the kit by absolute path (/home/<user>/...) breaks on every other machine, in
# a worktree and in a fresh clone. research-sdd-init.sh (portable wiring, the default since kit #2183; --absolute opts out) copies THIS file to <target>/tools/hooks/kit-run.sh (tracked)
# and wires the kit-owned hooks as:  bash "$CLAUDE_PROJECT_DIR"/tools/hooks/kit-run.sh toolbelt/<tool>.sh [args...]
#
# Kit resolution order (first candidate with a toolbelt/ directory wins):
#   1. $RESEARCH_SDD_KIT
#   2. the `Kit checkout:` / `Kit path:` line of an installed launcher file: AGENTS.md under $GENTLE_PI_AGENT_HOME,
#      $PI_CODING_AGENT_DIR, ~/.gentle-shell/agent, ~/.pi/agent; or ~/.claude/CLAUDE.md (a leading ~ is expanded)
#   3. $HOME/investigacion/sdd-investigacion/research-sdd (the kit's default checkout)
#
# Contract: stdin (the hook JSON) and the exit code pass through unchanged (exec). An unresolvable kit or a missing script is
# a typed, visible failure, never a silent allow: `kit-run: DEGRADED: <why>` on stderr + exit 1. EXCEPTION: the PreToolUse
# pkill guard (templates/hook-pretool-pkill-guard.sh) fails CLOSED — a command that mentions pkill/pgrep gets a
# permissionDecision "ask" naming the cause; any other command passes (exit 0).
set -uo pipefail

rel="${1:-}"
[ -n "$rel" ] || { echo "kit-run: DEGRADED: no script given" >&2; exit 1; }
shift

kit_resolve() {
  local cand f key line d
  local cands=("${RESEARCH_SDD_KIT:-}")
  # A set-but-unusable $RESEARCH_SDD_KIT is reported (typed, stderr) before falling through, never silently skipped.
  if [ -n "${RESEARCH_SDD_KIT:-}" ] && [ ! -d "$RESEARCH_SDD_KIT/toolbelt" ]; then
    echo "kit-run: DEGRADED: RESEARCH_SDD_KIT=$RESEARCH_SDD_KIT invalid (no toolbelt/ directory); trying the launcher files and the default checkout" >&2
  fi
  local files=()
  for d in "${GENTLE_PI_AGENT_HOME:-}" "${PI_CODING_AGENT_DIR:-}"; do [ -n "$d" ] && files+=("$d/AGENTS.md"); done
  files+=("$HOME/.gentle-shell/agent/AGENTS.md" "$HOME/.pi/agent/AGENTS.md" "$HOME/.claude/CLAUDE.md")
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    for key in "Kit checkout" "Kit path"; do
      line="$(sed -n "/^${key}:/{s/^${key}:[[:space:]]*\\(.*[^[:space:]]\\)[[:space:]]*\$/\\1/p;q;}" "$f" 2>/dev/null)" || line=""
      line="${line//\`/}"   # a launcher value may be backtick-quoted in markdown
      [ -n "$line" ] && cands+=("${line/#\~/$HOME}")
    done
  done
  cands+=("$HOME/investigacion/sdd-investigacion/research-sdd")
  for cand in "${cands[@]}"; do
    [ -n "$cand" ] && [ -d "$cand/toolbelt" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

degraded() {
  if [[ "$rel" == *hook-pretool-pkill-guard.sh ]]; then
    local in; in="$(cat || true)"
    if printf '%s' "$in" | grep -Eq 'pkill|pgrep'; then
      if command -v jq >/dev/null 2>&1; then
        jq -n --arg r "kit-run pkill-guard DEGRADED: $1; this command mentions pkill/pgrep and cannot be checked for a self-matching -f pattern. Approve only if the pattern is bracket-escaped or uses -x/a PID." \
          '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
      else
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"kit-run pkill-guard DEGRADED: kit unresolved and jq missing; this command mentions pkill/pgrep"}}'
      fi
    fi
    exit 0
  fi
  echo "kit-run: DEGRADED: $1; $rel did NOT run" >&2
  exit 1
}

# The script path is kit-relative: an absolute path or a `..` segment would escape the kit.
if [[ "$rel" == /* || "/$rel/" == */../* ]]; then degraded "script path '$rel' must be kit-relative without '..'"; fi
kit="$(kit_resolve)" || degraded "research-sdd kit not found (set RESEARCH_SDD_KIT)"
[ -f "$kit/$rel" ] || degraded "$kit/$rel is missing"
exec bash "$kit/$rel" "$@"

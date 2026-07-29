#!/usr/bin/env bash
# target-paths.sh — shared target-path derivation for research-sdd sweeps.
# Sourced (never executed); exports: target_paths_all.
#
# Handles `/abs/path`, `$RESEARCH_HOME/rest`, and `${RESEARCH_HOME}/rest` forms.
# Truncated '...' entries pass through so callers can WARN (sweep is PARTIAL).
# Non-path tokens (e.g. `/mrdoob/three.js`) pass through; callers do [ -d ] || continue.

# Idempotent: safe to source more than once.
if ! declare -F target_paths_all >/dev/null 2>&1; then

  # target_paths_all <targets_md>
  #   One path per line, sorted -u, $RESEARCH_HOME forms expanded.
  #   Returns 1 (with a message to stderr) if the file is absent or unreadable —
  #   a confident empty list must never be returned for a file that was never read.
  target_paths_all() {
    local f="${1:-}"
    [ -n "$f" ] || return 0
    if [ ! -f "$f" ]; then
      echo "target-paths: cannot read ${f}" >&2
      return 1
    fi
    local rh="${RESEARCH_HOME:-$HOME}"
    {
      # Form 1: `/abs/path`
      grep -oE '`/[^`]+`' "$f" 2>/dev/null | tr -d '`'
      # Form 2: `$RESEARCH_HOME/rest` or `${RESEARCH_HOME}/rest` — expand via awk.
      grep -oE '`\$(\{RESEARCH_HOME\}|RESEARCH_HOME)/[^`]+`' "$f" 2>/dev/null \
        | tr -d '`' \
        | awk -v rh="$rh" '{
            sub(/^\$\{RESEARCH_HOME\}\//, rh "/")
            sub(/^\$RESEARCH_HOME\//, rh "/")
            print
          }'
    } | sort -u
  }

  # target_paths_pairs <targets_md>
  #   One "<raw>\t<expanded>" pair per line, sorted -u.
  #   raw:      the token exactly as written in the file (e.g. $RESEARCH_HOME/rest or /abs/path).
  #   expanded: the filesystem-usable path after $RESEARCH_HOME substitution.
  #   For absolute paths raw == expanded; for $RESEARCH_HOME/... forms they differ.
  #   Truncated '...' entries pass through with raw == expanded (no substitution applies).
  #   Returns 1 (with a message to stderr) if the file is absent or unreadable.
  #   Used by verify-registry.sh to recover the raw token for TARGETS.md row lookup.
  target_paths_pairs() {
    local f="${1:-}"
    [ -n "$f" ] || return 0
    if [ ! -f "$f" ]; then
      echo "target-paths: cannot read ${f}" >&2
      return 1
    fi
    local rh="${RESEARCH_HOME:-$HOME}"
    {
      # Form 1: `/abs/path` — raw == expanded; emit as "<path>\t<path>".
      grep -oE '`/[^`]+`' "$f" 2>/dev/null | tr -d '`' | awk '{print $0 "\t" $0}'
      # Form 2: `$RESEARCH_HOME/rest` or `${RESEARCH_HOME}/rest` — raw is kept as-is;
      # expanded substitutes $RESEARCH_HOME. Emit as "<raw>\t<expanded>".
      grep -oE '`\$(\{RESEARCH_HOME\}|RESEARCH_HOME)/[^`]+`' "$f" 2>/dev/null \
        | tr -d '`' \
        | awk -v rh="$rh" '{
            raw=$0
            xp=$0
            sub(/^\$\{RESEARCH_HOME\}\//, rh "/", xp)
            sub(/^\$RESEARCH_HOME\//, rh "/", xp)
            print raw "\t" xp
          }'
    } | sort -u
  }

fi

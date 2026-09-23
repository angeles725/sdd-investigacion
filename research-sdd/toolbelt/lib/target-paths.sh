#!/usr/bin/env bash
# target-paths.sh — shared target-path derivation for research-sdd sweeps.
# Sourced (never executed); exports: target_paths_all, target_paths_pairs.
#
# Scans only markdown table rows (lines starting with optional whitespace then |).
# Handles `/abs/path`, `$RESEARCH_HOME/rest`, and `${RESEARCH_HOME}/rest` forms.
# Truncated '...' entries in table rows pass through so callers can WARN (sweep is PARTIAL).
# Non-path tokens (e.g. `/mrdoob/three.js`) pass through; callers do [ -d ] || continue.

# Idempotent: safe to source more than once.
if ! declare -F target_paths_all >/dev/null 2>&1; then

  # target_paths_all <targets_md>
  #   One path per line, sorted -u, $RESEARCH_HOME forms expanded.
  #   Returns 1 (with a message to stderr) if the file is absent or unreadable —
  #   a confident empty list must never be returned for a file that was never read.
  target_paths_all() {
    local f="${1:-}"
    # SENTINEL-TP-ALL-NOARG-START
    [ -n "$f" ] || { echo "target-paths: called with no argument" >&2; return 1; }
    # SENTINEL-TP-ALL-NOARG-END
    if [ ! -f "$f" ]; then
      echo "target-paths: cannot read ${f}" >&2
      return 1
    fi
    local rh="${RESEARCH_HOME:-$HOME}"
    rh="${rh%/}"   # normalize trailing slash (#923-B): avoid // in expanded paths
    {
      # Form 1: `/abs/path` — table rows only
      grep -E '^\s*\|' "$f" 2>/dev/null | grep -oE '`/[^`]+`' 2>/dev/null | tr -d '`'
      # Form 2: `$RESEARCH_HOME/rest` or `${RESEARCH_HOME}/rest` — table rows only; expand via awk.
      # Pass rh via ENVIRON["_TP_RH"] (not -v): awk -v interprets & and backslash in values,
      # corrupting rh values that contain those characters (#923-B).
      grep -E '^\s*\|' "$f" 2>/dev/null \
        | grep -oE '`\$(\{RESEARCH_HOME\}|RESEARCH_HOME)/[^`]+`' 2>/dev/null \
        | tr -d '`' \
        | _TP_RH="$rh" awk 'BEGIN { rh = ENVIRON["_TP_RH"] }
            {
              pfx1 = "${RESEARCH_HOME}/"
              pfx2 = "$RESEARCH_HOME/"
              if (substr($0, 1, length(pfx1)) == pfx1)
                print rh "/" substr($0, length(pfx1) + 1)
              else if (substr($0, 1, length(pfx2)) == pfx2)
                print rh "/" substr($0, length(pfx2) + 1)
              else
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
    # SENTINEL-TP-PAIRS-NOARG-START
    [ -n "$f" ] || { echo "target-paths: called with no argument" >&2; return 1; }
    # SENTINEL-TP-PAIRS-NOARG-END
    if [ ! -f "$f" ]; then
      echo "target-paths: cannot read ${f}" >&2
      return 1
    fi
    local rh="${RESEARCH_HOME:-$HOME}"
    rh="${rh%/}"   # normalize trailing slash (#923-B): avoid // in expanded paths
    {
      # Form 1: `/abs/path` — table rows only; raw == expanded; emit as "<path>\t<path>".
      grep -E '^\s*\|' "$f" 2>/dev/null | grep -oE '`/[^`]+`' 2>/dev/null | tr -d '`' | awk '{print $0 "\t" $0}'
      # Form 2: `$RESEARCH_HOME/rest` or `${RESEARCH_HOME}/rest` — table rows only; raw is kept
      # as-is; expanded substitutes $RESEARCH_HOME. Emit as "<raw>\t<expanded>".
      # Pass rh via ENVIRON["_TP_RH"] (not -v): awk -v interprets & and backslash in values,
      # corrupting rh values that contain those characters (#923-B).
      grep -E '^\s*\|' "$f" 2>/dev/null \
        | grep -oE '`\$(\{RESEARCH_HOME\}|RESEARCH_HOME)/[^`]+`' 2>/dev/null \
        | tr -d '`' \
        | _TP_RH="$rh" awk 'BEGIN { rh = ENVIRON["_TP_RH"] }
            {
              raw = $0
              pfx1 = "${RESEARCH_HOME}/"
              pfx2 = "$RESEARCH_HOME/"
              if (substr(raw, 1, length(pfx1)) == pfx1)
                xp = rh "/" substr(raw, length(pfx1) + 1)
              else if (substr(raw, 1, length(pfx2)) == pfx2)
                xp = rh "/" substr(raw, length(pfx2) + 1)
              else
                xp = raw
              print raw "\t" xp
            }'
    } | sort -u
  }

fi

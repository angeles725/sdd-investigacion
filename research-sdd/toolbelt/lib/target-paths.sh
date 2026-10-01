#!/usr/bin/env bash
# target-paths.sh — shared target-path derivation for research-sdd sweeps.
# Sourced (never executed); exports: target_paths_all, target_paths_pairs, target_name_for_retro.
#
# Consumers (kit issue #949 item 5: the header used to name 2; `grep -rl target-paths.sh
# research-sdd/toolbelt` is the authoritative list — an edit here must be checked against every one):
#   sweep-retros.sh, sweep-audits.sh, sweep-breakthroughs.sh, sweep-tools.sh, verify-registry.sh,
#   reconcile-issues.sh, stage-retro-issues.sh, stage-retro.sh (target_name_for_retro).
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
      # Use ENVIRON (not -v): awk -v interprets & and \ in values; ENVIRON does not (#923-B).
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
      # Use ENVIRON (not -v): awk -v interprets & and \ in values; ENVIRON does not (#923-B).
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

  # target_name_for_retro <targets_md> <retro>   (kit issue #1287)
  #   The ONE walk-up + name lookup shared by stage-retro-issues.sh, reconcile-issues.sh and
  #   stage-retro.sh, so the `Source retro: <name>/retros/<file>` signature a writer stamps is
  #   the signature a reader searches for (a per-script copy drifted once already).
  #   Walks UP from the directory that holds the retro's retros/ dir and prints the Target NAME
  #   (TARGETS.md row cell 2 — what the `target:<name>` labels are named after, NOT the path
  #   basename) of the NEAREST registered ancestor. That covers the flat layout
  #   (<target>/retros/), the nested one (<target>/corpus/retros/, METHODOLOGY §3b) and any
  #   deeper one; with nested registered targets the innermost wins, in any row order.
  #   A retro under an UNREGISTERED subdirectory of a registered target takes the registered
  #   parent's name (the subdirectory has no label of its own to claim).
  #   Both sides compare PHYSICAL paths (cd -P / pwd -P), so a symlinked retro directory or a
  #   registered path written through a symlink still matches.
  #   A name cell that is empty, or contains whitespace, falls back to the path basename; the
  #   whitespace case also prints a WARN (a name that cannot be a label must not vanish quietly).
  #   Returns: 0 + name on stdout            — nearest registered ancestor found
  #            2 + empty stdout              — TARGETS.md read fine, no ancestor registered
  #                                            (no-match; the caller picks its own fallback)
  #            1 + typed message on stderr   — operational failure: bad arguments, TARGETS.md
  #                                            absent/unreadable, no registered path parsed from
  #                                            it, NONE of the parsed paths resolves to a directory
  #                                            (a wrong RESEARCH_HOME — kit issue #1304 item 3), or
  #                                            the retro's directory does not exist
  #   The row is selected by its PATH cell only (kit issue #1304 item 4): a path merely quoted in
  #   another row's other cells never wins.
  target_name_for_retro() {
    local f="${1:-}" retro="${2:-}"
    if [ -z "$f" ] || [ -z "$retro" ]; then
      echo "target-paths: target_name_for_retro needs <targets_md> <retro>" >&2
      return 1
    fi
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
      echo "target-paths: cannot read ${f}" >&2
      return 1
    fi
    local rdir
    rdir="$(cd -P "$(dirname "$retro")" 2>/dev/null && pwd -P)" || {
      echo "target-paths: retro directory not found for ${retro}" >&2
      return 1
    }
    # The exit status of target_paths_pairs is deliberately NOT consulted: under `set -o pipefail`
    # (every consumer sets it) its last pipeline — the $RESEARCH_HOME form — exits 1 whenever a
    # registry has no such rows, even though Form 1 rows were emitted. The two real failure modes
    # (absent / unreadable file) were rejected above, so an EMPTY result is the signal.
    local pairs
    pairs="$(target_paths_pairs "$f" 2>/dev/null)"
    if [ -z "$pairs" ]; then
      echo "target-paths: no registered target paths parsed from ${f}" >&2
      return 1
    fi
    local rows
    rows="$(grep -E '^\s*\|' "$f")"
    local -a _tnr_raw=() _tnr_exp=() _tnr_path=()
    local _raw _path _exp
    while IFS=$'\t' read -r _raw _path; do
      _exp="$(cd -P "$_path" 2>/dev/null && pwd -P)" || continue
      _tnr_raw+=("$_raw"); _tnr_exp+=("$_exp"); _tnr_path+=("$_path")
    done <<<"$pairs"
    # kit issue #1304 item 3: paths WERE parsed (the check above) but none is a directory — a
    # wrong RESEARCH_HOME, a moved corpus root. That is an absent-input failure, never the quiet
    # "no ancestor registered" rc 2 (callers answer rc 2 with a basename fallback and one WARN).
    # SENTINEL-TNR-NODIR-START
    if [ "${#_tnr_exp[@]}" -eq 0 ]; then
      echo "target-paths: no registered target path in ${f} resolves to a directory (wrong RESEARCH_HOME?)" >&2
      return 1
    fi
    # SENTINEL-TNR-NODIR-END
    local anc i hit=-1
    anc="$(dirname "$rdir")"
    while :; do
      for i in "${!_tnr_exp[@]}"; do
        if [ "${_tnr_exp[$i]}" = "$anc" ]; then
          hit="$i"
          break 2   # SENTINEL-TNR-NEAREST: first (innermost) ancestor wins
        fi
      done
      [ "$anc" = "/" ] && break
      anc="$(dirname "$anc")"
    done
    [ "$hit" -ge 0 ] || return 2
    # kit issue #1304 item 4: match the PATH cell ($4 of a '| # | name | path |' row) only. The
    # former `grep -F -m1` over the whole row returned the FIRST row that merely QUOTED the path
    # anywhere (a Notes cell, an earlier row's evidence), i.e. the wrong row's name. The
    # backtick-delimited token keeps a path that prefixes another row's path from matching it.
    # SENTINEL-TNR-PATHCELL: the one place the row is selected.
    local name arc
    name="$(_TP_RAW="${_tnr_raw[$hit]}" awk -F'|' 'BEGIN { want = "`" ENVIRON["_TP_RAW"] "`" } index($4, want) { n = $3; gsub(/[`*]/, "", n); gsub(/^[[:space:]]+|[[:space:]]+$/, "", n); print n; exit }' <<<"$rows")"; arc=$?
    if [ "$arc" -ne 0 ]; then
      echo "target-paths: awk failed (exit ${arc}) reading the row for ${_tnr_raw[$hit]}" >&2
      return 1
    fi
    case "$name" in
      '') name="$(basename "${_tnr_path[$hit]}")" ;;
      *[[:space:]]*)
        echo "WARN: target name cell '${name}' for ${_tnr_raw[$hit]} contains whitespace and cannot be a label — using basename" >&2
        name="$(basename "${_tnr_path[$hit]}")" ;;
    esac
    printf '%s\n' "$name"
  }

fi

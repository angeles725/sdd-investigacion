#!/usr/bin/env bash
#
# verify-target-paths.sh — Research-SDD target-path resolver / presence check.
#
# WHY: TARGETS.md is committed and shared, but target paths are per-machine. A clone on
# a second host inherits absolute paths under the ORIGINAL author's home and every one of
# them silently fails to resolve — the loop then "starts" against a directory that is not
# there. This is the exact failure that motivated the $RESEARCH_HOME convention.
#
# WHAT IT DOES: parses the master table in TARGETS.md, expands $RESEARCH_HOME (default
# $HOME), and reports for each target whether it is PRESENT on this host, with its real
# block count. Read-only: it never edits TARGETS.md.
#
# EXIT CODES
#   0  every registered target resolves on this host
#   1  at least one target is missing (normal on a fresh clone — informational, not fatal)
#   2  usage / TARGETS.md not found
#
# USAGE
#   verify-target-paths.sh [--targets PATH] [--quiet] [--missing-only]
#
#   --targets PATH   TARGETS.md to read (default: sibling ../TARGETS.md)
#   --missing-only   list only the targets that do NOT resolve
#   --quiet          suppress the table; exit code only
#
# ENVIRONMENT
#   RESEARCH_HOME    base dir the $RESEARCH_HOME placeholder expands to (default: $HOME)

set -uo pipefail

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGETS="$KIT_DIR/TARGETS.md"
QUIET=0
MISSING_ONLY=0
: "${RESEARCH_HOME:=$HOME}"

while [ $# -gt 0 ]; do
  case "$1" in
    --targets) TARGETS="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --missing-only) MISSING_ONLY=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -f "$TARGETS" ] || { echo "error: TARGETS.md not found: $TARGETS" >&2; exit 2; }

missing=0
present=0

[ "$QUIET" -eq 1 ] || {
  echo "== verify-target-paths =="
  echo "   TARGETS.md    : $TARGETS"
  echo "   RESEARCH_HOME : $RESEARCH_HOME"
  echo
  printf '%-4s %-28s %-9s %-7s %s\n' "#" "TARGET" "STATUS" "BLOCKS" "PATH"
}

# Master-table rows look like: | N | name | `path` | ... — take the first three cells.
while IFS= read -r line; do
  case "$line" in
    \|[[:space:]][0-9]*)
      num=$(printf '%s' "$line" | awk -F'|' '{gsub(/ /,"",$2); print $2}')
      name=$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
      raw=$(printf '%s' "$line" | awk -F'|' '{print $4}' | tr -d '`' | sed 's/^ *//; s/ *$//')
      [ -n "$raw" ] || continue

      # Expand the placeholder; leave a literal absolute path untouched.
      path=${raw//\$RESEARCH_HOME/$RESEARCH_HOME}
      path=${path//\$\{RESEARCH_HOME\}/$RESEARCH_HOME}

      if [ -d "$path" ]; then
        blocks=$(find "$path" -maxdepth 2 -name '*-block*.md' -o -maxdepth 2 -name '*-bloque*.md' 2>/dev/null | wc -l | tr -d ' ')
        present=$((present + 1))
        [ "$MISSING_ONLY" -eq 1 ] && continue
        [ "$QUIET" -eq 1 ] || printf '%-4s %-28s %-9s %-7s %s\n' "$num" "$name" "PRESENT" "$blocks" "$path"
      else
        missing=$((missing + 1))
        [ "$QUIET" -eq 1 ] || printf '%-4s %-28s %-9s %-7s %s\n' "$num" "$name" "MISSING" "-" "$path"
      fi
      ;;
  esac
done < "$TARGETS"

[ "$QUIET" -eq 1 ] || {
  echo
  echo "   present: $present · missing: $missing"
  [ "$missing" -gt 0 ] && {
    echo
    echo "   NOTE: missing targets are EXPECTED on a clone that is not the authoring host."
    echo "   They are other machines' corpora, not broken state. Set RESEARCH_HOME if your"
    echo "   corpora live outside \$HOME:  RESEARCH_HOME=/data/research $0"
  }
}

[ "$missing" -gt 0 ] && exit 1
exit 0

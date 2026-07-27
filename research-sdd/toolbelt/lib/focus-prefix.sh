#!/usr/bin/env bash
# focus-prefix.sh — shared helper: derive the block filename prefix for a RESEARCH-STATE*.md.
# Sourced by verify-state.sh and research-sdd-status.sh so both use IDENTICAL derivation logic —
# the two scripts previously carried hand-copied implementations that could drift (verify-state.sh
# had _focus_prefix(), research-sdd-status.sh had derive_focus_prefix()); this file is the single
# source of truth.
#
#   derive_focus_prefix <state-file>
#     RESEARCH-STATE-<focus>.md  →  "<focus>-"  (§16 naming convention: block prefix mirrors state suffix)
#     RESEARCH-STATE.md          →  looks in sibling FOCUSES.md for the "Block prefix" column; echoes ""
#                                   (no prefix filter, counts all blocks — correct for single-focus corpora)
#     Always returns 0.

# Idempotent: safe to source more than once (both consumers may pull it in the same shell in tests).
if ! declare -F derive_focus_prefix >/dev/null 2>&1; then
  derive_focus_prefix() {
    local sf="$1" base; base="$(basename "$sf")"
    case "$base" in
      RESEARCH-STATE-*.md)
        local f="${base#RESEARCH-STATE-}"; printf '%s' "${f%.md}-"; return ;;
      RESEARCH-STATE.md)
        local fm; fm="$(dirname "$sf")/FOCUSES.md"
        [ -f "$fm" ] || return 0
        awk -F'|' '
          /^\|/ {
            sfcol=$4; gsub(/^[[:blank:]`]+|[[:blank:]`]+$/,"",sfcol)
            if (sfcol ~ /^\[/) { sub(/^\[/,"",sfcol); sfcol=substr(sfcol,1,index(sfcol,"]")-1) }
            if (sfcol!="RESEARCH-STATE.md") next
            bpcol=$5; gsub(/^[[:blank:]`]+|[[:blank:]`]+$/,"",bpcol)
            sub(/block[A-Za-z0-9]*\.md.*/,"",bpcol)
            if (bpcol ~ /^[A-Za-z]/ && bpcol ~ /-$/) {print bpcol; exit}
          }' "$fm"
        ;;
    esac
  }
fi

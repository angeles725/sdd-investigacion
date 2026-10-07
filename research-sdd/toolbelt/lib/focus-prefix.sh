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

# ---------------------------------------------------------------------------------------------------------------
# In-place blocked bucket (kit #1915) — shared by research-sdd-status.sh (--sync-state) and verify-state.sh (CHECK H).
# Lives in THIS file on purpose: it is the one lib every harness that copies either tool already copies, so the
# bucket has ONE definition without every mock kit growing a new file to copy.
#
#   inplace_gap_id TEXT
#     Normalised leading ID token of a gap cell / bullet: `**` and a trailing `.`/`:` stripped, upcased (`AB.`, `AB`,
#     `ab:` all give `AB`). ID-shaped = [A-Za-z0-9][A-Za-z0-9.-]* that holds a digit or is at most 3 characters;
#     prints nothing otherwise (a plain word like `Builders` is never an ID). Always returns 0.
#
#   inplace_blocked_count BLOCKED_BODY < ROWS
#     ROWS (stdin) : the backlog_rows stream, "priority<TAB>gap<TAB>status" (status already lowercased).
#     BLOCKED_BODY : the text of the Blocked-gaps / Non-investigable-gaps / Blocked-/ sections.
#     stdout       : the number of OPEN rows whose leading Status token is `blocked` / `blocked:` / `blocked,` /
#                    `blocked-on-*` (METHODOLOGY §21.1 in-place form) that blocked_open does not already count: closed
#                    rows (struck gap, ~~/✅ in the status) are skipped, and a row also listed under a Blocked-gaps
#                    section is counted once (by exact name or by gap ID) — but only a bullet that blocked_open actually
#                    counts (it carries `needs:`) may suppress a row.
if ! declare -F inplace_blocked_count >/dev/null 2>&1; then
  inplace_gap_id() {
    local t="${1#"${1%%[![:space:]]*}"}"; t="${t#\*\*}"; t="${t%%[[:space:]]*}"; t="${t%\*\*}"; t="${t%[.:]}"
    case "$t" in ''|*[!A-Za-z0-9.-]*) return 0 ;; esac
    case "$t" in [A-Za-z0-9]*) ;; *) return 0 ;; esac
    case "$t" in *[0-9]*) ;; *) [ "${#t}" -le 3 ] || return 0 ;; esac
    printf '%s\n' "${t^^}"
  }
  inplace_blocked_count() {
    local gap st lead tok n=0 _ipb_id _blk_ids _blk_names _bn
    _blk_names="$(printf '%s\n' "$1" | grep -iE '^[[:space:]]*-[[:space:]].*needs:' | sed -n 's/^[[:space:]]*-[[:space:]]*//p' \
      | sed -E 's/[[:space:]]*[-–—]+[[:space:]]*needs:.*$//I; s/[[:space:]]*needs:.*$//I' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    # gap IDs of those bullets: the in-place row's Gap cell and the bullet rarely share the full text
    # (fleet: `AB. Builders de config … — offsets` vs `**AB. Offsets de campo …**`), so match by leading ID token.
    _blk_ids="$(while IFS= read -r _bn; do inplace_gap_id "$_bn"; done <<<"$_blk_names")"
    while IFS=$'\t' read -r _ gap st; do
      [ -z "$gap" ] && continue
      case "$gap" in *'~~'*) continue ;; esac
      case "$st" in *'~~'*|*'✅'*) continue ;; esac
      lead="${st#\*\*}"; lead="${lead/\*\*/}"
      tok="${lead%% *}"
      case "$tok" in blocked-on-*|blocked|blocked:|blocked,) ;; *) continue ;; esac  # INPLACE-BLOCKED-TOKENS
      case $'\n'"$_blk_names"$'\n' in *$'\n'"$gap"$'\n'*) continue ;; esac  # INPLACE-DUAL-GUARD: already counted once by the Blocked-gaps section
      _ipb_id="$(inplace_gap_id "$gap")"
      if [ -n "$_ipb_id" ]; then  # INPLACE-DUAL-ID: same gap ID as a counted Blocked-gaps bullet (IDs hold only [A-Z0-9.-], so no glob chars)
        case $'\n'"$_blk_ids"$'\n' in *$'\n'"$_ipb_id"$'\n'*) continue ;; esac  # INPLACE-DUAL-ID-CASE
      fi
      n=$((n+1))
    done
    echo "$n"
  }
fi

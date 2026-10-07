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
# FOCUSES.md block RANGE cell (kit #906) — METHODOLOGY §16 "Block-scope cell grammar".
#
#   derive_focus_range <state-file>
#     RESEARCH-STATE.md only (a suffixed state file takes its prefix from its filename): reads the un-suffixed root's
#     FOCUSES.md row and returns the first cell right of the State-file cell shaped `B<a>–B<b>` (en dash or hyphen).
#       stdout "<a>-<b>"    a readable range (a <= b)
#       stdout "!<cell>"    range-SHAPED but unreadable (a > b) — a typed malformed state, distinct from absent
#       stdout ""           no FOCUSES.md / no root row / no range-shaped cell (the prefix path or the corpus-wide count applies)
#     Always returns 0. A prefix-shaped cell is returned by derive_focus_prefix, which callers consult FIRST.
#   block_range_filter [-n] <lo> <hi>
#     stdin: candidate paths (already canonical block files); stdout: those whose block number is in [lo, hi], inclusive
#     (-n: the block numbers instead of the paths).
#   focus_range_block_count <dir> <lo-hi>
#     The number of DISTINCT block numbers in the range among the canonical block files directly under <dir>
#     (needs lib/block-files.sh): files of two families that share a number are one block id.
if ! declare -F derive_focus_range >/dev/null 2>&1; then
  derive_focus_range() {
    local sf="$1" base fm; base="$(basename "$sf")"
    [ "$base" = "RESEARCH-STATE.md" ] || return 0  # RANGE-ROOT-ONLY
    fm="$(dirname "$sf")/FOCUSES.md"
    [ -f "$fm" ] || return 0
    LC_ALL=C awk -F'|' '
      /^\|/ {
        sfcol=$4; gsub(/^[[:blank:]`]+|[[:blank:]`]+$/,"",sfcol)
        if (sfcol ~ /^\[/) { sub(/^\[/,"",sfcol); sfcol=substr(sfcol,1,index(sfcol,"]")-1) }
        if (sfcol!="RESEARCH-STATE.md") next
        for (i=5; i<NF; i++) {
          c=$i; gsub(/^[[:blank:]`*]+|[[:blank:]`*]+$/,"",c)
          if (c !~ /^[Bb][0-9]+(–|-)[Bb][0-9]+$/) continue
          orig=c
          sub(/–/,"-",c)  # RANGE-ENDASH
          gsub(/[Bb]/,"",c); split(c,r,"-")
          if (r[1]+0 <= r[2]+0) print (r[1]+0) "-" (r[2]+0)
          else print "!" orig  # RANGE-MALFORMED
          exit
        }
      }' "$fm"
  }
  block_range_filter() {
    local _num=0; if [ "${1:-}" = "-n" ]; then _num=1; shift; fi
    LC_ALL=C awk -v lo="$1" -v hi="$2" -v num="$_num" '
      { n=$0; sub(/.*\//,"",n)
        if (!match(n,/-(block|bloque)[0-9]+/)) next
        v=substr(n,RSTART,RLENGTH); sub(/^-(block|bloque)/,"",v)
        if (v+0 >= lo+0) {  # RANGE-LO-BOUND
          if (v+0 <= hi+0) { if (num) print v+0; else print }  # RANGE-HI-BOUND
        } }'
  }
  focus_range_block_count() {
    # DISTINCT block numbers: two filename families that share low numbers (niagara: `…-mental-model-bloque4.md` and
    # `…-reflow-block4.md`) are one block id B4, so the count never exceeds the range size.
    find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | block_file_filter | block_range_filter -n "${2%-*}" "${2#*-}" | sort -un | wc -l | tr -d ' '  # RANGE-DISTINCT
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

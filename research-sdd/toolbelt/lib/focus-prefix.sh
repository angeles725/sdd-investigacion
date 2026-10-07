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
#     FOCUSES.md row. The cell is chosen by the RANGE header (whole cell: Bloques / Blocks / Block range / Rango; a
#     "Block prefix" / Prefijo / Prefix column is the PREFIX column, never the range one, and "Blocked …" matches neither)
#     when the table has one, else it is the first range-shaped cell right of the State-file cell (a last cell without a
#     closing pipe is a cell). If the header-chosen cell is not range-shaped but another cell is, that one is read and
#     focus_range_report WARNs.
#       stdout "<a>-<b>"    a readable range B<a>–B<b> (en dash or hyphen, a <= b)
#       stdout "!<cell>"    range-SHAPED but not the exact grammar (a > b, em dash, U+2011, minus, spaces around the dash,
#                           `B1–130`, open-ended `B1157–`, lists `B841–B861, B866`): typed malformed, never silent empty
#       stdout ""           no FOCUSES.md / no root row / no range-shaped cell (the prefix path or the corpus-wide count applies)
#     Always returns 0. A prefix-shaped cell is returned by derive_focus_prefix, which callers consult FIRST.
#   block_range_filter [-n] <lo> <hi>
#     stdin: candidate paths (already canonical block files); stdout: those whose block number is in [lo, hi], inclusive
#     (-n: the block numbers instead of the paths).
#   focus_range_stat <dir> <lo-hi> <state-file|""> COUNT|FILES|SPAN
#     COUNT: DISTINCT block numbers in the range among the canonical block files directly under <dir> that NO OTHER
#     FOCUSES.md row claims (an other row's prefix, or a number inside an other row's own range); FILES: how many files
#     carried those numbers; SPAN: b - a + 1. Always an integer. Needs lib/block-files.sh.
#   focus_range_block_count <dir> <lo-hi> [<state-file>]     = focus_range_stat ... COUNT
#   focus_range_report <state-file> <fmt>
#     Typed diagnostics for the root's range cell, one printf per line with <fmt> taking (KIND, TEXT), KIND WARN|NOTE:
#     malformed cell; more than one range-shaped cell in the row; unclaimed block FAMILIES contributing to the range
#     (each with its file count); missing numbers (range size - distinct, first 10 listed); a range matching nothing
#     while block files exist outside it. Prints nothing when the cell is absent or clean.
if ! declare -F derive_focus_range >/dev/null 2>&1; then
  # _focus_range_awk MODE FOCUSES.md — MODE root: "V<TAB>value" (+ "M<TAB>n" when n > 1 cells are range-shaped);
  # MODE claims: one "P<TAB>prefix" / "R<TAB>lo<TAB>hi" line per NON-root data row (what that focus claims).
  _focus_range_awk() {
    LC_ALL=C awk -F'|' -v mode="$1" '
      function trim(c) { gsub(/^[[:blank:]`*]+|[[:blank:]`*]+$/,"",c); return c }
      function strict(c) { return c ~ /^[Bb][0-9]+(–|-)[Bb][0-9]+$/ }
      function near(c) { return c ~ /^[Bb][0-9]+[[:blank:]]*(–|—|‑|−|-)/ }
      function norm(c,   r) { c2=c; sub(/–/,"-",c2); gsub(/[Bb]/,"",c2); split(c2,r,"-")
        if (r[1]+0 <= r[2]+0) return (r[1]+0) "-" (r[2]+0); return "!" c }
      /^\|/ {
        line=$0; endi = (line ~ /\|[[:blank:]]*$/) ? NF-1 : NF
        c2s=trim($2)
        if (c2s ~ /^:?-+:?$/) { n=split(prev,pf,"|"); hdr=0; hdrp=0
          for (i=2;i<=n;i++) { h=tolower(trim(pf[i]))
            if (!hdr && h ~ /^(bloques?|blocks?|block range|rango)$/) hdr=i  # RANGE-HDR-VOCAB
            if (!hdrp && h ~ /^(block prefix|prefijo|prefix)$/) hdrp=i }
          prev=""; next }
        prev=line
        sfcol=$4; gsub(/^[[:blank:]`]+|[[:blank:]`]+$/,"",sfcol)
        if (sfcol ~ /^\[/) { sub(/^\[/,"",sfcol); sfcol=substr(sfcol,1,index(sfcol,"]")-1) }
        if (sfcol !~ /^RESEARCH-STATE.*\.md$/) next
        nsh=0; first=""
        for (i=5;i<=endi;i++) { c=trim($i); if (near(c)) { nsh++; if (first=="") first=c } }
        chosen=first; fb=0
        if (hdr>=5 && hdr<=endi) { chosen=trim($hdr); if (!near(chosen) && first!="") { chosen=first; fb=1 } }  # RANGE-HDR-FALLBACK
        if (mode=="root") {
          if (sfcol!="RESEARCH-STATE.md" || done) next
          done=1
          if (strict(chosen)) print "V\t" norm(chosen); else if (near(chosen)) print "V\t!" chosen
          if (nsh>1) print "M\t" nsh
          if (fb) print "F\t" chosen
        } else if (sfcol!="RESEARCH-STATE.md") {
          if (strict(chosen)) { v=norm(chosen); if (v !~ /^!/) { split(v,q,"-"); print "R\t" q[1] "\t" q[2] } }
          else { bp=trim((hdrp>=5 && hdrp<=endi) ? $hdrp : $5); sub(/block[A-Za-z0-9]*\.md.*/,"",bp)
            if (bp !~ /^[A-Za-z].*-$/ && hdr>=5 && hdr<=endi) { bp=trim($hdr); sub(/block[A-Za-z0-9]*\.md.*/,"",bp) }  # prefix written under the range header
            if (bp ~ /^[A-Za-z].*-$/) print "P\t" bp }
        }
      }' "$2"
  }
  derive_focus_range() {
    local sf="$1" base fm; base="$(basename "$sf")"
    [ "$base" = "RESEARCH-STATE.md" ] || return 0  # RANGE-ROOT-ONLY
    fm="$(dirname "$sf")/FOCUSES.md"
    [ -f "$fm" ] || return 0
    _focus_range_awk root "$fm" | sed -n 's/^V\t//p' | head -1
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
  # _focus_range_scan DIR LO-HI STATE — "COUNT/FILES/SPAN/FAM/MISSING/OUTSIDE" lines (see focus_range_stat / _report)
  _focus_range_scan() {
    local claims="" fm=""
    if [ -n "${3:-}" ] && [ -f "$(dirname "$3")/FOCUSES.md" ]; then fm="$(dirname "$3")/FOCUSES.md"; claims="$(_focus_range_awk claims "$fm")"; fi
    find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | block_file_filter | LC_ALL=C awk -v lo="${2%-*}" -v hi="${2#*-}" -v claims="$claims" '
      BEGIN { lo+=0; hi+=0; nl=split(claims,cl,"\n")
        for (i=1;i<=nl;i++) { split(cl[i],f,"\t"); if (f[1]=="P") pfx[++np]=f[2]; else if (f[1]=="R") { rlo[++nr]=f[2]+0; rhi[nr]=f[3]+0 } } }
      { n=$0; sub(/.*\//,"",n)
        if (!match(n,/-(block|bloque)[0-9]+/)) next
        fam=substr(n,1,RSTART-1); v=substr(n,RSTART,RLENGTH); sub(/^-(block|bloque)/,"",v); v+=0
        if (v<lo || v>hi) { outside++; next }
        claimed=0
        for (p=1;p<=np;p++) if (index(n,pfx[p])==1 && substr(n,length(pfx[p])+1) ~ /^(block|bloque)[0-9]/) claimed=1
        for (r=1;r<=nr;r++) if (v>=rlo[r] && v<=rhi[r]) claimed=1
        if (claimed) next
        files++; ids[v]=1; ff[fam]++ }
      END { for (v in ids) cnt++
        print "COUNT\t" cnt+0; print "FILES\t" files+0; print "SPAN\t" hi-lo+1; print "OUTSIDE\t" outside+0
        for (fam in ff) print "FAM\t" fam "\t" ff[fam]
        miss=0; lst=""
        for (v=lo; v<=hi; v++) if (!(v in ids)) { miss++; if (miss<=10) lst = lst (lst==""?"":",") v }
        print "MISSING\t" miss "\t" lst }'
  }
  focus_range_stat() {
    _focus_range_scan "$1" "$2" "${3:-}" | sed -n "s/^$4\\t//p" | head -1
  }
  focus_range_block_count() { focus_range_stat "$1" "$2" "${3:-}" COUNT; }
  # shellcheck disable=SC2059
  focus_range_report() {
    local sf="$1" fmt="$2" fm rows v m f rng scan fams nf cnt span miss lst out
    [ "$(basename "$sf")" = "RESEARCH-STATE.md" ] || return 0
    fm="$(dirname "$sf")/FOCUSES.md"; [ -f "$fm" ] || return 0
    rows="$(_focus_range_awk root "$fm")"
    v="$(printf '%s\n' "$rows" | sed -n 's/^V\t//p' | head -1)"
    m="$(printf '%s\n' "$rows" | sed -n 's/^M\t//p' | head -1)"
    f="$(printf '%s\n' "$rows" | sed -n 's/^F\t//p' | head -1)"
    [ -z "$f" ] || printf "$fmt" WARN "FOCUSES.md range column cell is not range-shaped; read the range-shaped cell [$f] found elsewhere in the root row — put the range under the Blocks/Bloques header"
    [ -z "$m" ] || printf "$fmt" WARN "FOCUSES.md root row holds $m range-shaped cells — only the header-named (else first) one is read; keep exactly one B<a>–B<b> cell"
    case "$v" in
      '') return 0 ;;
      '!'*) printf "$fmt" WARN "FOCUSES.md block-scope cell [${v#!}] is range-shaped but not the exact grammar B<a>–B<b> (en dash or hyphen, a <= b) — it scopes nothing (METHODOLOGY §16 Block-scope cell grammar)"; return 0 ;;
    esac
    rng="B${v%-*}–B${v#*-}"; scan="$(_focus_range_scan "$(dirname "$sf")" "$v" "$sf")"
    cnt="$(printf '%s\n' "$scan" | sed -n 's/^COUNT\t//p')"; span="$(printf '%s\n' "$scan" | sed -n 's/^SPAN\t//p')"
    nf="$(printf '%s\n' "$scan" | grep -c '^FAM')"
    if [ "$nf" -gt 1 ]; then
      fams="$(printf '%s\n' "$scan" | sed -n 's/^FAM\t\(.*\)\t\([0-9]*\)$/\1=\2/p' | sort | tr '\n' ' ')"
      printf "$fmt" WARN "$rng mixes $nf block families that no other FOCUSES.md row claims (file counts: ${fams% }) — all are counted as distinct block numbers; give a foreign family its own row (prefix or range) to exclude it"
    fi
    miss="$(printf '%s\n' "$scan" | sed -n 's/^MISSING\t\([0-9]*\)\t.*/\1/p')"; lst="$(printf '%s\n' "$scan" | sed -n 's/^MISSING\t[0-9]*\t//p')"
    if [ "${miss:-0}" -gt 0 ] && [ "${cnt:-0}" -gt 0 ]; then
      printf "$fmt" NOTE "$rng spans $span block ids, $cnt present, $miss missing (span - distinct): ${lst}$([ "$miss" -gt 10 ] && echo ", … (first 10 of $miss)")"
    fi
    out="$(printf '%s\n' "$scan" | sed -n 's/^OUTSIDE\t//p')"
    if [ "${cnt:-0}" -eq 0 ] && [ "${out:-0}" -gt 0 ]; then
      printf "$fmt" WARN "no block file is numbered within $rng while $out block file(s) exist outside it — the range may be wrong (cannot-see: the count is 0, not a measured zero)"
    fi
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

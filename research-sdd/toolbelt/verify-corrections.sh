#!/usr/bin/env bash
# verify-corrections.sh — §14 reciprocal-backlink lint for a Research-SDD corpus (retro delta).
#
# WHY: §14 self-correction is BI-directional by design — a later block that refutes/refines an earlier one
# must "keep the original text, add a note 'corrected in BN'" IN THE CORRECTED BLOCK, not only cross-ref it
# FROM the correcting block. In practice only the forward half gets written: the correcting block declares
# "Corrects [Block N] §N.x", but the target block file is never touched — and a self-report can even CLAIM the
# backlink was added when the git diff proves otherwise (the exact B33→B8 gap this lint was born from). This
# mechanizes the reciprocal check, mirroring how §11/§5 mechanized the marker tally / source registry.
#
# It reads each block file, finds CORRECTION DECLARATIONS (a `corrects`/`corrige…` verb bound to a
# [Block N]/[Bloque N] reference WITHIN ITS OWN CLAUSE — see _vc_extract; #1790), and for each declared target requires that block's file to
# carry a reciprocal "corrected in B<this>" (or "corregido en B<this>") note. A one-directional correction
# (declared, not back-linked) is a FAIL. Uses the SAME block-file discriminator as gen-catalog/verify-state/
# archive so "a block file" means one thing corpus-wide.
#
# Usage: verify-corrections.sh <target-dir>
# Exit: 0 = every declared correction is reciprocated (or none) · 1 = a one-directional correction · 2 = bad
#       args / no block files. Operational failure (awk absent or the extractor failed) is a typed
#       `degraded:` line + exit 1, never an "ok" (an unreadable instrument is not a clean corpus).
set -uo pipefail

_vc_bf_lib="$(cd "$(dirname "$0")" && pwd)/lib/block-files.sh"
if [ ! -f "$_vc_bf_lib" ]; then echo "verify-corrections: cannot find helper $_vc_bf_lib" >&2; exit 1; fi
# shellcheck source=lib/block-files.sh
. "$_vc_bf_lib"
declare -F block_file_filter >/dev/null 2>&1 || { echo "verify-corrections: helper lib/block-files.sh failed to define block_file_filter" >&2; exit 1; }
unset _vc_bf_lib

target="${1:-}"
[ -d "$target" ] || { echo "usage: verify-corrections.sh <target-dir>" >&2; exit 2; }

# Block files: `<prefix>-(block|bloque)<N>[-suffix].md` (the corpus-wide discriminator). Exclude templates/.git.
mapfile -t blocks < <(find "$target" -maxdepth 3 -type f -name '*.md' -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null \
  | block_file_filter | sort)
[ "${#blocks[@]}" -gt 0 ] || { echo "verify-corrections: no block files under $target" >&2; exit 2; }

# Trailing block NUMBER from a block filename (t-block33.md → 33; ug67-bloque8-foo.md → 8).
blocknum() { basename "$1" | sed -E 's/.*-(block|bloque)0*([0-9]+).*/\2/'; }

# number → file map (last one wins; corpora keep one file per block number).
declare -A numfile
for f in "${blocks[@]}"; do numfile["$(blocknum "$f")"]="$f"; done

command -v awk >/dev/null 2>&1 || { echo "verify-corrections: degraded: awk not found on PATH; the corpus was NOT checked" >&2; exit 1; }

# CORRECTION-TARGET EXTRACTOR (awk). Prints one block number per line: the [Block N]/[Bloque N] each
# `corrects`/`corrig…` verb in the file GOVERNS. Fixed under #1790: the old per-physical-line grep bound the
# verb to ANY bracket on the line, so a wrapped list `[Block 1] (the claim §17.7 corrects) · [Block 11] (…)`
# reported the unrelated trailing [Block 11]. Binding is now clause-scoped:
#   1. UNITS: physical lines are joined into logical units (a paragraph / blockquote run) so a clause that wraps
#      across lines is one unit; a blank line, heading, list bullet or table row starts a new unit.
#   2. FORWARD (`Corrects [Block 8] §2; cf. [Block 12]`): the first `[Block N]` AFTER the verb,
#      but only inside the verb's own clause — the clause ends at a `;`, a middle dot `·`, a sentence-ending `. `,
#      a `, and`/`, but`/`, y`/`, pero` conjunction, or the `)` that closes the parenthetical the verb sits in.
#      The first ref wins, so a trailing cross-reference is never a target.
#   3. POSTFIX (`[Block 1] (the claim §17.7 corrects) · [Block 11] (…)`): the verb sits inside a parenthetical and
#      no ref follows it before that parenthetical closes, so it governs the ref the parenthetical annotates,
#      i.e. the [Block N] immediately before its opening `(`.
#   A verb with neither binding (or whose clause leads with a bare `B<N>`) is reported as `?` — counted and surfaced
#   as a note by the caller, never guessed onto a neighbouring ref and never silently dropped (anti-silent-zero).
_vc_extract() {
  # LC_ALL=C: byte semantics in every awk (gawk under UTF-8 counts characters, so the 2-byte `·` compare below
  # would never match). The program relies on ASCII classes and that one byte pair only.
  LC_ALL=C awk '
    function flush() { if (u != "") { units[nu++] = u; u = "" } }
    function emit(n) { if (!(n in seen)) { seen[n] = 1; print n } }
    function refnum(t,   m) {          # first [Block N] in t -> N ("" when none)
      if (match(t, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/)) {
        m = substr(t, RSTART, RLENGTH); gsub(/[^0-9]/, "", m); return m
      }
      return ""
    }
    # A `.` ends the clause only when it ends a SENTENCE: not after a known abbreviation (EN + ES, ONE list, below)
    # nor a single-letter initial. Byte-level, lowercase compare (the caller lowercases and runs under LC_ALL=C).
    function abbrev(l, i,   k, tok, ab) {
      ab = " cf e.g i.e vs fig p pp approx aprox pág pag núm num sec sect eq no "
      k = i - 1
      while (k >= 1 && substr(l, k, 1) !~ /[ \t(\[;,:]/) k--
      tok = substr(l, k + 1, i - 1 - k)
      if (tok == "") return 0
      return (tok ~ /^[a-z]$/) || index(ab, " " tok " ") > 0
    }
    function scan(un,   l, n, p, rest, ms, vs, ve, i, c, d, bd, cl, r, j, pre, done, bp) {
      l = tolower(un); n = length(un); p = 1
      while (p <= n) {
        rest = substr(l, p)
        if (!match(rest, /(^|[^a-z0-9_])(corrects|corrig[a-z]*)/)) break
        ms = p + RSTART - 1
        vs = (substr(l, ms, 1) ~ /[a-z]/) ? ms : ms + 1
        ve = ms + RLENGTH
        if (substr(l, vs, 8) == "corrects" && substr(l, ve, 1) ~ /[a-z0-9_]/) { p = ve; continue }
        d = 0; bd = ""
        for (i = ve; i <= n; i++) {
          c = substr(un, i, 1)
          if (c == "(") d++
          else if (c == ")") { if (d == 0) { bd = "close"; break } d-- }
          else if (c == ";") break
          else if (c == "," && substr(l, i, 12) ~ /^,[ \t]+(and|but|while|y|pero)[ \t]/) break
          else if (substr(un, i, 2) == "\302\267") break
          else if (c == "." && (i == n || substr(un, i + 1, 1) ~ /[ \t]/) && !abbrev(l, i)) break
        }
        cl = substr(l, ve, i - ve); r = refnum(cl); done = 0
        # A bare `B<N>` ahead of the first bracketed ref means the verb governs THAT (e.g. "CORRECTS my own B67
        # §67.7, which walked into a trap [Block 34] had described") — the later bracket is not its target.
        if (r != "" && match(cl, /(^|[^a-z0-9_])b[0-9]+([^a-z0-9_]|$)/)) {
          bp = RSTART; match(cl, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/)
          if (bp <= RSTART) r = ""
        }
        if (r != "") { emit(r); done = 1 }
        else if (!done && bd == "close") {
          d = 0
          for (j = vs - 1; j >= 1; j--) {
            c = substr(un, j, 1)
            if (c == ")") d++
            else if (c == "(") { if (d == 0) break; d-- }
          }
          if (j >= 1) {
            pre = substr(l, 1, j - 1); sub(/[ \t]+$/, "", pre)
            if (match(pre, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]$/)) { emit(refnum(substr(pre, RSTART))); done = 1 }
          }
        }
        if (!done) print "?"          # a correction verb that binds to no bracketed ref: surfaced, never guessed
        p = ve
      }
    }
    {
      line = $0; sub(/^[ \t]*(>[ \t]*)+/, "", line)
      if (line ~ /^[ \t]*$/) { flush(); next }
      if (line ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]/ || line ~ /^[ \t]*#/ || line ~ /^[ \t]*\|/) flush()
      u = (u == "") ? line : u " " line
    }
    END { flush(); for (k = 0; k < nu; k++) scan(units[k]) }
  ' "$1"
}

rc=0; unbound=0
echo "== verify-corrections: $(basename "$target") =="
for f in "${blocks[@]}"; do
  c="$(blocknum "$f")"
  if ! _vc_out="$(_vc_extract "$f")"; then
    echo "verify-corrections: degraded: extractor (awk) failed on $(basename "$f"); the corpus was NOT checked" >&2
    exit 1
  fi
  _vc_targets=(); [ -z "$_vc_out" ] || mapfile -t _vc_targets <<<"$_vc_out"
  for n in "${_vc_targets[@]}"; do
    [ -n "$n" ] || continue
    if [ "$n" = "?" ]; then unbound=$((unbound+1)); continue; fi
    n="$((10#$n))"                      # normalize any zero-padding
    [ "$n" = "$c" ] && continue         # a block correcting itself is not a cross-block backlink
    tgt="${numfile[$n]:-}"
    if [ -z "$tgt" ]; then
      echo "   WARN   B$c declares a correction of [Block $n] but no block-$n file exists on disk"
      continue
    fi
    # Reciprocal backlink: the target file must mention "corrected in"/"corregido en" AND B<c>/Block <c>.
    # fixed under #1444: process substitution, no producer | grep -q pipe, so no SIGPIPE race is possible.
    if grep -qiE "\bb0*$c\b|\bblock[[:space:]]*0*$c\b|\bbloque[[:space:]]*0*$c\b" < <(grep -iE 'corrected|corregido' "$tgt" 2>/dev/null); then
      : # reciprocated
    else
      echo "   FAIL   B$c corrects [Block $n] but $(basename "$tgt") has no reciprocal 'corrected in B$c' backlink (§14)"
      rc=1
    fi
  done
done

[ "$unbound" -eq 0 ] || echo "   note   $unbound correction verb(s) governed no bracketed [Block N] ref in their own clause (bare B<N> or unbound) and were NOT checked (#1790)"
[ "$rc" -eq 0 ] && echo "   ok     every declared correction has its reciprocal 'corrected in BN' backlink."
echo "== exit $rc =="
exit $rc

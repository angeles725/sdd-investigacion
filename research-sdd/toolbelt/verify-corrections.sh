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

# Filename PREFIX of a block file (hh-block4.md → hh; ug67-bloque8-foo.md → ug67). Multi-focus corpora keep
# several prefixes whose block numbers collide, so a number alone does not identify a block (#1835 item 1).
blockprefix() { basename "$1" | sed -E 's/^(.*)-(block|bloque)0*[0-9]+.*/\1/'; }

# (prefix,number) → file map (last one wins WITHIN a prefix; corpora keep one file per block number per prefix).
# numany/numcnt: the same number across ALL prefixes, used only as a fallback when the correcting block's own
# prefix lacks the target: a UNIQUE other-prefix match is taken, an ambiguous one is surfaced, never guessed.
declare -A numfile numany numcnt
for f in "${blocks[@]}"; do
  _vc_p="$(blockprefix "$f")"; _vc_n="$(blocknum "$f")"
  if [ -z "${numfile["$_vc_p|$_vc_n"]:-}" ]; then numcnt["$_vc_n"]=$(( ${numcnt["$_vc_n"]:-0} + 1 )); fi
  numfile["$_vc_p|$_vc_n"]="$f"; numany["$_vc_n"]="$f"
done

# Backlink vocabulary: a target block "carries the note" when a line matches this AND names the correcting block
# (#1835 item 2, #1868 item 6; decided in METHODOLOGY §14). English/Spanish past participles, the corrigendum/erratum
# noun forms and the refinement forms a scope-narrowing correction uses (case-insensitive).
# The refine words only count in a BACKLINK SHAPE (`refined in B4`, `§14 refinement (…)`, `refinado en`, `Refinamiento (B4)`),
# never as a bare word: "Refinement planned, see B12" is not a note that B12 refined this block (#1868 review).
_vc_backlink_re='corrected|corregid[oa]s?|corrigend(um|a)|errat(um|a)|refined[[:space:]]+(in|by|at|as|per)|refinad[oa]s?[[:space:]]+(en|por)|§14[[:space:]]+refinement|refinement[[:space:]]*\(|refinamiento[[:space:]]*(\(|§14)'

# FOCUSES.md (anywhere under the target, depth <= 3): focus slug -> block prefix, so a cross-focus qualifier such as
# "corrects `integration` [Block 5]" resolves to the focus's own prefix (#1868 item 1). Row shape:
# | `slug` | status | state | `prefix-blockN.md` | question |   (the prefix is the `<prefix>-blockN` token of any cell).
declare -A focuspfx
while IFS= read -r _vc_fm; do
  while IFS='|' read -r -a _vc_cols; do
    [ "${#_vc_cols[@]}" -ge 3 ] || continue
    _vc_slug="${_vc_cols[1]//[\`*[:space:]]/}"; _vc_slug="${_vc_slug,,}"
    [ -n "$_vc_slug" ] || continue
    for _vc_cell in "${_vc_cols[@]:2}"; do
      if [[ "$_vc_cell" =~ ([A-Za-z0-9][A-Za-z0-9._-]*)-(block|bloque)(N|[0-9]+) ]]; then focuspfx["$_vc_slug"]="${BASH_REMATCH[1]}"; break; fi
    done
  done < <(grep -E '^[[:space:]]*\|' "$_vc_fm" 2>/dev/null)
done < <(find "$target" -maxdepth 3 -type f -name 'FOCUSES.md' -not -path '*/.git/*' 2>/dev/null | sort)
# slug -> prefix of an existing block file ("" when the slug names no focus we can resolve; never guessed).
declare -A pfxset
for f in "${blocks[@]}"; do pfxset["$(blockprefix "$f")"]=1; done
resolve_slug() {
  local s="${1,,}" p
  for p in "${!pfxset[@]}"; do [ "${p,,}" = "$s" ] && { printf '%s' "$p"; return; }; done
  [ -z "${focuspfx[$s]:-}" ] || { printf '%s' "${focuspfx[$s]}"; return; }
}

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
#   Output: one typed record per line (the caller owns the wording), never a bare number:
#     `T <n>`            a plain declared target
#     `Q <n> <slug>`     a target qualified by a focus slug (`corrects \`integration\` [Block 5]`, #1868 item 1)
#     `A <class> <n>`    a TYPED AMBIGUOUS target (#1868): `object` (the verb governs a non-block object: a possessive
#                        or a gap label), `locator` (the block only locates the thing: `junto a`/`alongside [Block N]`),
#                        `assumption` (a reader-assumption correction) or `bare` (a bare `B<N>`, #1835 item 4). The
#                        caller reports them as AMBIG lines — surfaced and named, never a refusal, never dropped.
#     `U`                a verb that binds to no bracketed ref in its clause: counted and surfaced as a note by the
#                        caller, never guessed onto a neighbouring ref and never silently dropped (anti-silent-zero)
#     `S`                a non-assertive form (passive/conditional/past tense) that declares nothing
#   WORD BOUNDARY (#1847): the program runs under LC_ALL=C, so a non-ASCII letter is two bytes >= 0x80. Every word-char
#   class below therefore includes \200-\377: `ñcorrige`, `corrigeñ` and `ñse corrige` are other words, not the verb
#   or the passive guard.
_vc_extract() {
  # LC_ALL=C: byte semantics in every awk (gawk under UTF-8 counts characters, so the 2-byte `·` compare below
  # would never match). The program relies on ASCII classes, byte ranges and that one byte pair only.
  LC_ALL=C awk '
    function flush() { if (u != "") { units[nu++] = u; u = "" } }
    # qcur/qkind: the focus qualifier of the clause (`hard` = an explicit focus reference, `soft` = a backticked token after
    # in/of/en/de that may just be a file name). EVERY ref of a joined list inherits it (#1868 review).
    function emit(n,   k) {
      k = cls "|" qcur "|" n
      if (!(k in seen)) {
        seen[k] = 1
        if (cls != "") print "A " cls " " n
        else if (qcur != "") print "Q " n " " qcur " " qkind
        else print "T " n
      }
    }
    # first bare `B<N>` (not a gap label such as B50-G6, not part of a longer word) in t -> N ("" when none); BP = its start.
    function barenum(t,   rest, off, m, nx) {
      rest = t; off = 0; BP = 0; BE = 0
      while (match(rest, /(^|[^a-z0-9_\200-\377])b[0-9]+/)) {
        m = substr(rest, RSTART, RLENGTH); nx = substr(rest, RSTART + RLENGTH)
        if (nx !~ /^[a-z_\200-\377]/ && nx !~ /^-[a-z][0-9]/) { BP = off + RSTART; BE = off + RSTART + RLENGTH - 1; gsub(/[^0-9]/, "", m); return m }
        off += RSTART + RLENGTH - 1; rest = nx
      }
      return ""
    }
    # moreb(t): every further bare `B<N>` joined to the previous one by and/y/e/&/`/` (same list rule as more()); emits each.
    function moreb(t,   rest, tok, nx) {
      rest = substr(t, BE + 1)
      while (match(rest, /^[ \t0-9.,-]*(and|y|e|&|\/)[ \t]*b[0-9]+/)) {
        tok = substr(rest, 1, RLENGTH); nx = substr(rest, RLENGTH + 1)
        if (nx ~ /^[a-z_\200-\377]/ || nx ~ /^-[a-z][0-9]/) return
        gsub(/.*b/, "", tok); emit(tok)
        rest = nx
      }
    }
    # Inferential classes decided from the text between the verb and the ref (pre) / the whole clause object (obj).
    function classify(pre,   c) {
      if (pre ~ /(assumption|expectation|suposici[^ ]*)[ \t]+(behind|underlying|detr[^ ]*|subyacente)[ \t]*(the[ \t]+|el[ \t]+|la[ \t]+)?$/) return "assumption"
      if (pre ~ /(junto[ \t]+a|together[ \t]+with|alongside|along[ \t]+with)[ \t]*(the[ \t]+|el[ \t]+|la[ \t]+)?$/) return "locator"
      # object: a gap label (B50-G6) in the object, or the possessive of a PROCESS noun (focus, caller, backlog, queue, session, run:
      # the measured shapes). A possessive of a code artifact (decompiler, parser: a reading in the cited block) is a claim of
      # that block and stays a plain declaration.
      if (pre ~ /(^|[^a-z0-9_\200-\377])(this|that|the|our|my)[ \t]+(focus|caller|backlog|queue|session|run)(\047|\342\200\231)s[ \t]/ || pre ~ /(^|[^a-z0-9_\200-\377])b[0-9]+-[a-z][0-9]+/) return "object"
      return ""
    }
    function refnum(t,   m) {          # first [Block N] in t -> N ("" when none)
      if (match(t, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/)) {
        m = substr(t, RSTART, RLENGTH); gsub(/[^0-9]/, "", m); return m
      }
      return ""
    }
    # A `.` ends the clause only when it ends a SENTENCE: not after a known abbreviation (EN + ES, ONE list, below)
    # nor a single-letter initial. Byte-level, lowercase compare (the caller lowercases and runs under LC_ALL=C).
    # MULTI-TARGET (#1835 item 3): after the first bound ref, further [Block N] refs in the SAME clause are targets
    # too, but only when joined to the previous one by the WORD `and`/`y`/`e`, `&` or `/` (optionally with section locators
    # such as `§6.3–6.4` between them). Any other text between two refs ends the list: a cross-reference is not a target.
    # `/` joins since #1868 item 5 (`usado en [Block 9]/[Block 10]`: the second ref was never checked). The evidence-citation
    # shape that made `/` unsafe in #1835 (`corrects <possessive> remittance … ([Block 537]/[Block 538]/[Block 545])`, 1 FAIL
    # became 3) is now typed instead: its possessive object makes EVERY ref of the list an AMBIG `object` (see classify).
    # Deliberately NOT joiners: `+` and a bare comma (`[Block 3], [Block 4] is related` could false-bind a cross-reference;
    # tests/verify-corrections-binding.test.sh case 17 pins both). A `, and` already ends the clause above.
    function more(cl,   rest, g, m, st, ln) {
      if (!match(cl, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/)) return
      rest = substr(cl, RSTART + RLENGTH)
      while (match(rest, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/)) {
        st = RSTART; ln = RLENGTH
        g = substr(rest, 1, st - 1); m = substr(rest, st, ln)
        gsub("\302\247", "", g); gsub("\342\200\223", "-", g)
        if (g !~ /^[ \t0-9.,-]*(and|y|e|&|\/)[ \t0-9.,-]*$/) return
        gsub(/[^0-9]/, "", m); emit(m)
        rest = substr(rest, st + ln)
      }
    }
    # noundecl(rest): 1 when the text after a corrigendum noun is `[tag] <preposition> [the] [tag] [Block N]` (the ref
    # directly after an explicit preposition; a tag is a short bracket that is NOT itself a block ref), else 0.
    function noundecl(rest,   tail, tg) {
      if (!match(rest, /^[ \t]*(`?\[[^]\[]*\]`?)?[ \t]*(al|a|to|of|for)[ \t]+(the[ \t]+)?/)) return 0
      if (substr(rest, 1, RLENGTH) ~ /(block|bloque)[ \t]*[0-9]/) return 0     # the LEADING tag is itself a block ref (#1847)
      tail = substr(rest, RLENGTH + 1)
      if (tail ~ /^\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/) return 1
      if (match(tail, /^`?\[[^]\[]*\]`?[ \t]*/)) {
        tg = substr(tail, 1, RLENGTH); tail = substr(tail, RLENGTH + 1)
        if (tg !~ /(block|bloque)[ \t]*[0-9]/ && tail ~ /^\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/) return 1
      }
      return 0
    }
    function abbrev(l, i,   k, tok, ab) {
      ab = " cf e.g i.e vs fig p pp approx aprox pág pag núm num sec sect eq no "
      k = i - 1
      while (k >= 1 && substr(l, k, 1) !~ /[ \t(\[;,:]/) k--
      tok = substr(l, k + 1, i - 1 - k)
      if (tok == "") return 0
      return (tok ~ /^[a-z]$/) || index(ab, " " tok " ") > 0
    }
    function scan(un,   l, n, p, rest, ms, vs, ve, i, c, d, bd, cl, r, j, pre, done, bp, tok, isnoun, rl, nb, past, bn, rs, post, qual, qm, qt) {
      l = tolower(un); n = length(un); p = 1
      while (p <= n) {
        rest = substr(l, p)
        if (!match(rest, /(^|[^a-z0-9_\200-\377])(corrects|corrig[a-z]*)/)) break
        ms = p + RSTART - 1
        vs = (substr(l, ms, 1) ~ /[a-z]/) ? ms : ms + 1
        ve = ms + RLENGTH
        if (substr(l, vs, 8) == "corrects" && substr(l, ve, 1) ~ /[a-z0-9_\200-\377]/) { p = ve; continue }
        tok = substr(l, vs, ve - vs); cls = ""; qcur = ""; qkind = ""
        # `corrigendum`/`corrigenda` is a NOUN, handled by its own STRICT rule (never the verb clause scan, which bound the first
        # ref even inside a parenthetical and turned backlinks and prose into false FAILs):
        #   - bare noun directly followed by a ref (`CORRIGENDUM [Bloque N]`) = BACKLINK: declares nothing;
        #   - an explicit PREPOSITION right before the ref (`al`/`a`/`to`/`to the`/`of`/`for`, optional short non-ref tag such as
        #     `[CERT]` before the preposition or after it) = DECLARATION of that block (niagara-research bloque107/108);
        #   - `CORRIGENDUM [Bloque 33] al [Bloque 32]`: the leading ref-shaped "tag" is skipped; 32 is the target;
        #   - EVERY OTHER noun form (colon, em dash, parenthetical, "see", a ref later in the clause, prose) prints `U`: counted in
        #     the unbound note, never a declaration and never silently dropped (§7). That includes the accepted, surfaced false
        #     negative `Corrigendum: [Block 8] §2 was wrong`.
        isnoun = 0
        if (tok ~ /^corrigend/) {
          isnoun = 1; rest = substr(l, ve)
          if (match(rest, /^[ \t]*\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/)) {
            rl = RLENGTH
            if (substr(rest, rl + 1) ~ /^[ \t]*(al|a|to|of|for)[ \t]+(the[ \t]+)?\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/) ve += rl
            else { p = ve; continue }
          }
          else if (!noundecl(rest)) { print "U"; p = ve; continue }
        }
        # NON-ASSERTIVE forms declare nothing (#1835 item 5): passive/conditional `se corrige` (incl. `si no se
        # corrige`) and past-tense narrative `corrigió`/`corrigieron`. Counted and surfaced, never silently dropped.
        # #1847: a word that CONTINUES past the verb token with a digit, `_` or a non-ASCII letter (`corrigeñ`,
        # `corrigióñ`, `corrigiéndose`) is not one of these forms nor the verb: it is surfaced as `U`.
        nb = substr(l, ve, 1); past = 0
        if (tok == "corrigi" && (substr(l, ve, 2) == "\303\263" || substr(l, ve, 2) == "\303\223")) {
          if (substr(l, ve + 2, 1) ~ /[a-z0-9_\200-\377]/) { print "U"; p = ve + 2; continue }
          past = 1
        }
        else if (nb ~ /[0-9_\200-\377]/) { print "U"; p = ve; continue }
        pre = substr(l, 1, vs - 1)
        if (pre ~ /(^|[^a-z0-9_\200-\377])se[ \t]+$/ || tok == "corrigieron" || tok == "corrigio" || past) {
          print "S"; p = ve; continue
        }
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
        bn = barenum(cl); rs = 0
        if (r != "") { match(cl, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/); rs = RSTART }
        # A bare `B<N>` ahead of the first bracketed ref means the verb governs THAT (e.g. "CORRECTS my own B67
        # §67.7, which walked into a trap [Block 34] had described") — the later bracket is not its target. Since #1868
        # (#1835 item 4) it is a typed `bare` target, checked as advisory by the caller, not an anonymous unbound note.
        if (bn != "" && (r == "" || BP < rs)) { cls = "bare"; emit(bn); moreb(cl); done = 1 }
        else if (r != "") {
          pre = substr(cl, 1, rs - 1); cls = classify(pre)
          qcur = ""; qkind = ""
          if (cls == "") {
            if (match(pre, /`[a-z0-9._-]+`[ \t]*$/)) { qm = substr(pre, RSTART, RLENGTH); gsub(/[` \t]/, "", qm); qcur = qm; qkind = "hard" }
            else {
              post = substr(cl, rs)
              if (match(post, /^\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/)) post = substr(post, RLENGTH + 1)
              if (match(post, /^[ \t]*(of|del|de|in|en)[ \t]+(the[ \t]+|el[ \t]+)?(focus[ \t]+)?`[a-z0-9._-]+`([ \t]+focus)?/)) { qm = substr(post, RSTART, RLENGTH); qt = qm; sub(/`[^`]*`/, "", qt); qkind = (qt ~ /focus/) ? "hard" : "soft"; sub(/^[^`]*`/, "", qm); sub(/`.*$/, "", qm); qcur = qm }
            }
          }
          emit(r)
          more(cl); done = 1; qcur = ""; qkind = ""
        }
        else if (!isnoun && bd == "close") {
          d = 0
          for (j = vs - 1; j >= 1; j--) {
            c = substr(un, j, 1)
            if (c == ")") d++
            else if (c == "(") { if (d == 0) break; d-- }
          }
          if (j >= 1) {
            pre = substr(l, 1, j - 1); sub(/[ \t]+$/, "", pre)
            if (match(pre, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]$/)) { cls = classify(cl); emit(refnum(substr(pre, RSTART))); done = 1 }
          }
        }
        if (!done) print "U"          # a correction verb that binds to no bracketed ref: surfaced, never guessed
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

rc=0; unbound=0; skipped=0; unchecked=0; ambiguous=0; skipnames=""
# amb <class-text> — one typed AMBIG line (#1868): an inferential binding the linter will not turn into a refusal. The
# caller (research-sdd-archive.sh) tells these apart from FAIL lines by the `AMBIG` token and counts them as PARTIAL.
amb() { echo "   AMBIG  B$c corrects [Block $n] — $1; NOT checked as a declaration (typed ambiguous, not a refusal) [correcting: $(basename "$f")]"; ambiguous=$((ambiguous+1)); }
echo "== verify-corrections: $(basename "$target") =="
for f in "${blocks[@]}"; do
  c="$(blocknum "$f")"
  if ! _vc_out="$(_vc_extract "$f")"; then
    echo "verify-corrections: degraded: extractor (awk) failed on $(basename "$f"); the corpus was NOT checked" >&2
    exit 1
  fi
  _vc_targets=(); [ -z "$_vc_out" ] || mapfile -t _vc_targets <<<"$_vc_out"
  for _vc_i in ${_vc_targets[@]+"${!_vc_targets[@]}"}; do
    rec="${_vc_targets[$_vc_i]}"; cls=""; qual=""
    [ -n "$rec" ] || continue
    case "$rec" in
      U) unbound=$((unbound+1)); continue ;;
      S) skipped=$((skipped+1)); skipnames="${skipnames:+$skipnames, }B$c"; continue ;;
      T\ *) n="${rec#T }" ;;
      Q\ *) read -r _ n qual qkind <<<"$rec" ;;
      A\ *) read -r _ cls n <<<"$rec" ;;
      *) echo "verify-corrections: degraded: extractor emitted an unknown record '$rec' for $(basename "$f"); the corpus was NOT checked" >&2; exit 1 ;;
    esac
    n="$((10#$n))"                      # normalize any zero-padding
    case "$cls" in
      object|locator|assumption) [ "$n" = "$c" ] && continue ;;   # the correcting block's own number: not a cross-block declaration
    esac
    case "$cls" in
      object)     amb "the verb governs a non-block object (a possessive or a gap label), not this block"; continue ;;
      locator)    amb "locator reference: the block only LOCATES the thing corrected ('junto a'/'alongside [Block $n]'), it carries no claim of its own"; continue ;;
      assumption) amb "a reader-assumption correction ('the assumption behind [Block $n]'), not a claim the cited block makes"; continue ;;
    esac
    _vc_own="$(blockprefix "$f")"
    _vc_qp=""
    if [ -n "$qual" ]; then
      _vc_qp="$(resolve_slug "$qual")"
      # A SOFT qualifier (a backticked token after in/of/en/de with no `focus` word: probably a file name) that names no focus
      # falls back to the strict unqualified lookup (#1868 review); only a HARD one is a typed ambiguity.
      if [ -z "$_vc_qp" ] && [ "$qkind" = soft ]; then qual=""; fi
    fi
    if [ -n "$qual" ]; then
      # An explicit focus qualifier (#1868 item 1): the target lives in THAT focus, never in the own prefix.
      if [ -z "$_vc_qp" ]; then
        amb "cross-focus qualifier \`$qual\` names no focus prefix (no block file carries it, no FOCUSES.md row maps it); target NOT guessed"; continue
      fi
      tgt="${numfile["$_vc_qp|$n"]:-}"
      if [ -z "$tgt" ]; then
        echo "   WARN   B$c declares a correction of [Block $n] of focus \`$qual\` but no block-$n file exists in its prefix '$_vc_qp'; NOT checked"
        unchecked=$((unchecked+1)); continue
      fi
    else
      tgt="${numfile["$_vc_own|$n"]:-}"       # the correcting block's OWN prefix first (#1835 item 1)
      if [ -z "$tgt" ]; then
        case "${numcnt[$n]:-0}" in
          0) ;;
          1) tgt="${numany[$n]}" ;;
          *) if [ "$cls" = bare ]; then amb "bare B$n reference, number ambiguous across ${numcnt[$n]} other prefixes (advisory)"; continue; fi
             echo "   WARN   B$c declares a correction of [Block $n] but no block-$n file exists in its prefix '$_vc_own' and the number is ambiguous across ${numcnt[$n]} other prefixes; NOT checked"
             unchecked=$((unchecked+1)); continue ;;
        esac
      fi
      if [ -z "$tgt" ]; then
        if [ "$cls" = bare ]; then amb "bare B$n reference, no block-$n file exists on disk (advisory)"; continue; fi
        echo "   WARN   B$c declares a correction of [Block $n] but no block-$n file exists on disk"
        unchecked=$((unchecked+1))
        continue
      fi
    fi
    # A block correcting ITSELF (the RESOLVED target is this very file) is not a cross-block backlink. Decided on the resolved
    # file, not on the bare number: `Corrects `integration` [Block 5]` inside pi5-decoding-block5 targets ANOTHER focus's block 5.
    [ "$tgt" = "$f" ] && continue
    # Reciprocal backlink: the target file must carry a backlink-vocabulary word AND name B<c>/Block <c>.
    # fixed under #1444: process substitution, no producer | grep -q pipe, so no SIGPIPE race is possible.
    if grep -qiE "\bb0*$c\b|\bblock[[:space:]]*0*$c\b|\bbloque[[:space:]]*0*$c\b" < <(grep -iE "$_vc_backlink_re" "$tgt" 2>/dev/null); then
      : # reciprocated
    elif [ "$cls" = bare ]; then
      amb "bare B$n reference with no reciprocal backlink in $(basename "$tgt") (advisory: a bare ref is checked, never refused)"
    else
      echo "   FAIL   B$c corrects [Block $n] but $(basename "$tgt") has no reciprocal backlink to B$c (accepted: 'corrected in'/'corregido en'/'refined in'/corrigendum/erratum naming it) (§14) [correcting: $(basename "$f")]"
      rc=1
    fi
  done
done

[ "$unbound" -eq 0 ] || echo "   note   $unbound correction verb(s) governed no bracketed [Block N] ref in their own clause (unbound, or a word that merely contains the verb) and were NOT checked (#1790)"
[ "$skipped" -eq 0 ] || echo "   note   $skipped correction verb(s) in a non-assertive form (passive 'se corrige', conditional, or past tense) were skipped, not treated as declarations (#1835): $skipnames"
if [ "$rc" -eq 0 ]; then
  _vc_partial=$((unchecked+ambiguous))
  if [ "$_vc_partial" -eq 0 ]; then echo "   ok     every declared correction has its reciprocal 'corrected in BN' backlink."
  else echo "   ok-partial $_vc_partial declared correction(s) NOT checked (ambiguous/missing target: $ambiguous AMBIG, $unchecked WARN) — see WARN/AMBIG above"; fi
fi
echo "== exit $rc =="
exit $rc

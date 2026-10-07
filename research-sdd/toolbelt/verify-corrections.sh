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
_vc_hi="$(printf '\200-\377')"   # the non-ASCII BYTE range: grep runs under LC_ALL=C below, so a multi-byte letter is word text (#1847)
_vc_backlink_re='corrected|corregid[oa]s?|corrigend(um|a)|errat(um|a)|refined[[:space:]]+(in|by|at|as|per)|refinad[oa]s?[[:space:]]+(en|por)|§14[[:space:]]+refinement|refinement[[:space:]]*\(|refinamiento[[:space:]]*(\(|§14)'
# Left word boundary (#1835 follow-up): `uncorrected`/`miscorrected`/`pañcorrected` contain `corrected` but are not the note.
# `_` is NOT word text here: markdown italics `_corrected in B33_` is a real note. Applied to the whole alternation.
# UTF-8 PUNCTUATION that may directly precede the word is a boundary, not word text: em/en dash, curly single/double quotes,
# guillemets, inverted ? and !, middle dot (`—corrected in B33`, `“corrected in B33”`, `«corregido en B33»`, `¿corregido?`).
_vc_pun="$(printf '\342\200\224|\342\200\223|\342\200\230|\342\200\231|\342\200\234|\342\200\235|\302\253|\302\273|\302\277|\302\241|\302\267')"
_vc_backlink_pre="(^|[^[:alnum:]${_vc_hi}]|${_vc_pun})("

# The corrigendum NOUN as a backlink (#1874 item 1): `**CORRECCIÓN (2026-07-26) — [Block 292].**` in the corrected block. The
# noun alone is prose ("a correction was considered"), so the shape is strict: `corrección`/`correction`, an optional
# parenthetical tag, an optional dash/colon, then DIRECTLY the `[Block N]` ref of the correcting block (N is appended per pair).
# Both cases of the accented capital are spelled out: `grep -i` does not fold `Ó` under every locale.
# Three guards keep it from reading a FORWARD correction as a backlink (`Correction: [Block 8] was wrong` says the target
# corrects block 8): a left word boundary (no `miscorrection`), no colon (a colon introduces the corrected thing), and a CUE
# after the ref: it must close its sentence (`.`, `;` or the end of the line) or be followed by a `§` locator; a `:` or `,` after the ref continues the sentence (`— [Block 292].**`, `— [Block 292] §292.5.**`).
_vc_noun_re="(^|[^[:alnum:]_${_vc_hi}]|${_vc_pun})"'(correcci(ó|Ó|o)n|correction)[[:space:]*]*(\([^)]*\))?[[:space:]*]*(—|–|-)?[[:space:]*]*\[[[:space:]]*(block|bloque)[[:space:]]*0*'
_vc_noun_tail='[[:space:]]*\][[:space:]*]*(§[[:space:]]*[0-9][0-9.]*)?[[:space:]*]*([.;]|$)'

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
#      i.e. the [Block N] immediately before its opening `(`. When that ref ends a JOINED list (`[Block 50]/[Block 51]
#      (corrige …)`, joiners as in 2., the walk back stopping at a `;`, `·` or sentence-ending `. `), the clause attaches
#      to the list as a whole: only the FIRST ref of the list is the declaration and every later one is `A list <n>`
#      (#1874 item 2; see postlist).
#   Output: one typed record per line (the caller owns the wording), never a bare number:
#     `T <n>`            a plain declared target
#     `Q <n> <slug>`     a target qualified by a focus slug (`corrects \`integration\` [Block 5]`, #1868 item 1)
#     `A <class> <n>`    a TYPED AMBIGUOUS target (#1868): `object` (the verb governs a non-block object: a possessive
#                        or a gap label), `locator` (the block only locates the thing: `junto a`/`alongside [Block N]`),
#                        `assumption` (a reader-assumption correction) or `bare` (a bare `B<N>`, #1835 item 4). The
#                        caller reports them as AMBIG lines — surfaced and named, never a refusal, never dropped.
#     `U`                a verb that binds to no bracketed ref in its clause: counted and surfaced as a note by the
#                        caller, never guessed onto a neighbouring ref and never silently dropped (anti-silent-zero)
#     `A possessive <n>` a bare `corrigendum of [Block N]`: the possessive, typed advisory (counted toward ok-partial) instead of a bare `U`
#     `S`                a non-assertive form (passive/conditional/past tense) that declares nothing
#     `N`                a NEGATED verb (`corrects nothing in B21`, `no corrige`, #1874 item 3): declares nothing, counted in a note
#     (`A list <n>` = a later ref of a joined list followed by the verb's parenthetical; `A mixed <n>` = a bracketed ref joined
#      to a leading bare list: both advisory, #1874 items 2 and 4)
#   WORD BOUNDARY (#1847): the program runs under LC_ALL=C, so a non-ASCII letter is two bytes >= 0x80. Every word-char
#   class below therefore includes \200-\377: `ñcorrige`, `corrigeñ` and `ñse corrige` are other words, not the verb
#   or the passive guard.
_vc_extract() {
  # LC_ALL=C: byte semantics in every awk (gawk under UTF-8 counts characters, so the 2-byte `·` compare below
  # would never match). The program relies on ASCII classes, byte ranges and that one byte pair only.
  LC_ALL=C awk '
    # PREP: the ONE preposition grammar of a corrigendum declaration (used by noundecl and the leading-ref form); TAGMAX: the
    # longest `[tag]` (BYTES between the brackets: the program runs under LC_ALL=C) still read as a short tag rather than a prose aside.
    BEGIN { PREP = "(al|a|to|of|for)"; TAGMAX = 24 }
    function flush() { if (u != "") { units[nu++] = u; u = "" } }
    # qcur/qkind: the focus qualifier of the clause (`hard` = an explicit focus reference, `soft` = a backticked token after
    # in/of/en/de that may just be a file name, `lead` = a backticked token right before the ref that may just be a code
    # identifier, #1874 item 7: soft and lead fall back to the strict unqualified lookup when they name no focus). EVERY ref of a joined list inherits it (#1868 review).
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
    # Then (#1874 item 4) every BRACKETED [Block N] joined to that list by the same joiner rule is emitted as class `mixed`
    # (`Corrects B6 and [Block 12] §3`): checked as an advisory exactly like a bare ref, never a refusal and never dropped.
    function moreb(t,   rest, tok, nx, gm, gp, sv) {
      rest = substr(t, BE + 1)
      while (match(rest, /^[ \t0-9.,-]*(and|y|e|&|\/)[ \t]*b[0-9]+/)) {
        tok = substr(rest, 1, RLENGTH); nx = substr(rest, RLENGTH + 1)
        if (nx ~ /^[a-z_\200-\377]/ || nx ~ /^-[a-z][0-9]/) break
        gsub(/.*b/, "", tok); emit(tok)
        rest = nx
      }
      while (match(rest, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/)) {
        gm = substr(rest, RSTART, RLENGTH); gp = substr(rest, 1, RSTART - 1); rest = substr(rest, RSTART + RLENGTH)
        gsub("\302\247", "", gp); gsub("\342\200\223", "-", gp)
        if (gp !~ /^[ \t0-9.,-]*(and|y|e|&|\/)[ \t0-9.,-]*$/) return
        gsub(/[^0-9]/, "", gm)
        sv = cls; cls = "mixed"; emit(gm); cls = sv
      }
    }
    # Inferential classes decided from the text between the verb and the ref (pre) / the whole clause object (obj).
    function classify(pre,   c) {
      if (pre ~ /(assumption|expectation|suposici[^ ]*)[ \t]+(behind|underlying|detr[^ ]*|subyacente)[ \t]*(the[ \t]+|el[ \t]+|la[ \t]+)?$/) return "assumption"
      if (pre ~ /(junto[ \t]+a|together[ \t]+with|alongside|along[ \t]+with)[ \t]*(the[ \t]+|el[ \t]+|la[ \t]+)?$/) return "locator"
      # object: a gap label (B50-G6) in the object, or the possessive of a PROCESS noun (focus, caller, backlog, queue, session, run:
      # the measured shapes) AT THE START of the object: a possessive inside an aside (a `per this run` review clause before
      # the claim in [Block 8]) is not the object of the verb (#1874 item 6). A possessive of a code artifact (decompiler,
      # parser: a reading in the cited block) is a claim of that block and stays a plain declaration.
      if (pre ~ /^[ \t]*(this|that|the|our|my)[ \t]+(focus|caller|backlog|queue|session|run)(\047|\342\200\231)s[ \t]/ || pre ~ /(^|[^a-z0-9_\200-\377])b[0-9]+-[a-z][0-9]+/) return "object"
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
    # listend(cl): index just past the LAST ref of the joined list that starts at the first ref of the clause (same joiner rule as more()).
    function listend(cl,   rest, g, st, ln, pos) {
      match(cl, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/); pos = RSTART + RLENGTH - 1
      rest = substr(cl, pos + 1)
      while (match(rest, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/)) {
        st = RSTART; ln = RLENGTH; g = substr(rest, 1, st - 1)
        gsub("\302\247", "", g); gsub("\342\200\223", "-", g)
        if (g !~ /^[ \t0-9.,-]*(and|y|e|&|\/)[ \t0-9.,-]*$/) break
        pos += st + ln - 1; rest = substr(rest, st + ln)
      }
      return pos + 1
    }
    # postlist(t): the verb sat in a parenthetical that follows t (the text before its opening paren, ending in a ref). The paren
    # annotates the WHOLE joined list that ends there (`[Block 50]/[Block 51] (corrige …)`): the clause cannot say WHICH member
    # it corrects, so only the FIRST ref of the list is a declaration and every later one is a typed `list` ambiguity (#1874
    # item 2; unlike a FORWARD list, where the verb precedes the refs and governs all of them).
    function postlist(t,   rest, off, nn, adv, v, first, g, k, sv) {
      rest = t; off = 0; nn = 0
      while (match(rest, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/)) {
        nn++; lrs[nn] = off + RSTART; lre[nn] = off + RSTART + RLENGTH - 1
        v = substr(rest, RSTART, RLENGTH); gsub(/[^0-9]/, "", v); lrn[nn] = v
        adv = RSTART + RLENGTH - 1; off += adv; rest = substr(rest, adv + 1)
      }
      first = nn
      while (first > 1) {
        g = substr(t, lre[first - 1] + 1, lrs[first] - lre[first - 1] - 1)
        if (g ~ /\.[ \t]/ || g ~ /;/ || index(g, "\302\267")) break     # a sentence break ends the list, as in the forward scan
        gsub("\302\247", "", g); gsub("\342\200\223", "-", g)
        if (g ~ /^[ \t0-9.,-]*(and|y|e|&|\/)[ \t0-9.,-]*$/) first--; else break
      }
      emit(lrn[first])
      for (k = first + 1; k <= nn; k++) { sv = cls; if (cls == "") cls = "list"; emit(lrn[k]); cls = sv }
    }
    # negpost(post): 1 when the text right after the verb NEGATES it (#1874 item 3, narrowed after the Opus gate). `nothing`/`none`/`nada`
    # negate unless followed by an exception (`nothing but`, `none other than`, `nada excepto`, `nada más que`); `no`/`ninguna?`
    # negate only as `no <noun> in/of/en/de` (`no claim in [Block 8]`), never `no longer`, `no only`, `no solo`, `no fewer/less/more`.
    function excpost(post) {   # 1 when the text after the verb is `nothing/anything but …`: an exception, so the verb still declares
      return (post ~ /^[ \t]+(nothing|none|nada|anything)[ \t]+(but|except|salvo|excepto|other|m[^ \t]*s[ \t]+que)/)
    }
    function negpost(post,   w) {
      if (match(post, /^[ \t]+(nothing|none|nada)([ \t,.;]|$)/)) {
        return !excpost(post)
      }
      if (match(post, /^[ \t]+(no|ninguna?)[ \t]+[^ \t]+[ \t]+(in|of|en|de|del|about|sobre)[ \t]/)) {
        w = substr(post, RSTART, RLENGTH); sub(/^[ \t]+(no|ninguna?)[ \t]+/, "", w); sub(/[ \t].*$/, "", w)
        return !(w ~ /^(longer|only|solo|fewer|less|menos|more|than|further|m[^ \t]*s|s[^ \t]*lo)$/)
      }
      return 0
    }
    # trailq(post): 1 (and sets qcur/qkind) when post starts with a focus qualifier `of the focus `x``/`of the `x` focus`/`in `x``.
    function trailq(post,   qm, qt) {
      if (!match(post, /^[ \t]*(of|del|de|in|en)[ \t]+(the[ \t]+|el[ \t]+)?(focus[ \t]+)?`[a-z0-9._-]+`([ \t]+focus)?/)) return 0
      qm = substr(post, RSTART, RLENGTH); qt = qm; sub(/`[^`]*`/, "", qt)
      qkind = (qt ~ /focus/) ? "hard" : "soft"; sub(/^[^`]*`/, "", qm); sub(/`.*$/, "", qm); qcur = qm
      return 1
    }
    # noundecl(rest): 1 when the text after a corrigendum noun is `[tag] <preposition> [the] [tag] [Block N]` (the ref
    # directly after an explicit preposition; a tag is a short bracket that is NOT itself a block ref), else 0.
    # A tag is SHORT: at most TAGMAX characters between the brackets; longer is a prose aside. A `of` with no tag before OR after it (a bare `of [Block N]`) is
    # the POSSESSIVE (`see the corrigendum of [Block 33]` inside the corrected file), not a declaration; `of` needs a tag (returns 2, with the ref number in NDN).
    function tagok(t,   inner) {         # t = a bracket tag incl. brackets/backticks: 1 when it is short and not a block ref
      inner = t; gsub(/^`?\[|\]`?[ \t]*$/, "", inner)
      return (length(inner) <= TAGMAX && inner !~ /(block|bloque)[ \t]*[0-9]/)
    }
    function noundecl(rest,   lead, hasl, tail, tg) {
      if (!match(rest, "^[ \t]*(`?\\[[^]\\[]*\\]`?)?[ \t]*" PREP "[ \t]+(the[ \t]+)?")) return 0
      lead = substr(rest, 1, RLENGTH); tail = substr(rest, RLENGTH + 1)
      hasl = match(lead, /`?\[[^]\[]*\]`?/)
      if (hasl && !tagok(substr(lead, RSTART, RLENGTH))) return 0       # the LEADING tag is a block ref (#1847) or not short
      if (tail ~ /^\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/) {
        if (!hasl && lead ~ /(^|[^a-z0-9])of[ \t]+(the[ \t]+)?$/) { NDN = refnum(tail); return 2 }   # 2 = the possessive `of`: typed AMBIG, not a bare unbound
        return 1
      }
      if (match(tail, /^`?\[[^]\[]*\]`?[ \t]*/)) {
        tg = substr(tail, 1, RLENGTH); tail = substr(tail, RLENGTH + 1)
        if (tagok(tg) && tail ~ /^\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/) return 1
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
    function scan(un,   nd, l, n, p, rest, ms, vs, ve, i, c, d, bd, cl, r, j, pre, done, bp, tok, isnoun, rl, nb, past, bn, rs, post, qual, qm, qt) {
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
            if (substr(rest, rl + 1) ~ ("^[ \t]*" PREP "[ \t]+(the[ \t]+)?\\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\\]")) ve += rl
            else { p = ve; continue }
          }
          else if ((nd = noundecl(rest)) == 2) { print "A possessive " NDN; p = ve; continue }
          else if (!nd) { print "U"; p = ve; continue }
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
        # NEGATIONS declare nothing (#1874 item 3): `corrects nothing in B21`, `Corrects no claim in B402`, `no corrige`,
        # `never corrects`. Only the word right before / right after the VERB negates it (the corrigendum noun has its own rule above) ("no longer valid" later in the
        # sentence does not). Counted and surfaced as a note by the caller, like the non-assertive forms.
        if (!isnoun && ((pre ~ /(^|[^a-z0-9_\200-\377])(no|nunca|never|tampoco)[ \t]+$/ && !excpost(substr(l, ve))) || negpost(substr(l, ve)))) {
          print "N"; p = ve; continue
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
            if (match(pre, /`[a-z0-9._-]+`[ \t]*$/)) { qm = substr(pre, RSTART, RLENGTH); gsub(/[` \t]/, "", qm); qcur = qm; qkind = "lead" }
            else {
              post = substr(cl, rs)
              if (match(post, /^\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]/)) post = substr(post, RLENGTH + 1)
              if (!trailq(post)) trailq(substr(cl, listend(cl)))   # qualifier right after the FIRST ref, else after the LAST joined ref
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
            if (match(pre, /\[[ \t]*(block|bloque)[ \t]*[0-9]+[ \t]*\]$/)) { cls = classify(cl); postlist(pre); done = 1 }
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

rc=0; unbound=0; negated=0; negnames=""; skipped=0; unchecked=0; ambiguous=0; skipnames=""
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
    rec="${_vc_targets[$_vc_i]}"; cls=""; qual=""; _vc_soft=""
    [ -n "$rec" ] || continue
    case "$rec" in
      U) unbound=$((unbound+1)); continue ;;
      S) skipped=$((skipped+1)); skipnames="${skipnames:+$skipnames, }B$c"; continue ;;
      N) negated=$((negated+1)); negnames="${negnames:+$negnames, }B$c"; continue ;;
      T\ *) n="${rec#T }" ;;
      Q\ *) read -r _ n qual qkind <<<"$rec" ;;
      A\ *) read -r _ cls n <<<"$rec" ;;
      *) echo "verify-corrections: degraded: extractor emitted an unknown record '$rec' for $(basename "$f"); the corpus was NOT checked" >&2; exit 1 ;;
    esac
    n="$((10#$n))"                      # normalize any zero-padding
    _vc_rd="bare B$n reference"; _vc_adv="bare"
    [ "$cls" != mixed ] || { _vc_rd="bracketed [Block $n] joined to a leading bare B<N> list (#1874)"; _vc_adv="joined bracketed"; }
    case "$cls" in
      object)     amb "the verb governs a non-block object (a possessive or a gap label), not this block"; continue ;;
      locator)    amb "locator reference: the block only LOCATES the thing corrected ('junto a'/'alongside [Block $n]'), it carries no claim of its own"; continue ;;
      assumption) amb "a reader-assumption correction ('the assumption behind [Block $n]'), not a claim the cited block makes"; continue ;;
      possessive) amb "possessive 'corrigendum of [Block $n]': a reference to that block's corrigendum, not a declaration to check; the clause cannot say which block corrects which"; continue ;;
      list)       amb "joined-list reference: the correction clause follows the whole list, so only its FIRST ref is checked and this later one is not guessed"; continue ;;
    esac
    _vc_own="$(blockprefix "$f")"
    _vc_qp=""
    if [ -n "$qual" ]; then
      _vc_qp="$(resolve_slug "$qual")"
      # A SOFT qualifier (a backticked token after in/of/en/de with no `focus` word: probably a file name) or a LEAD one (a
      # backticked token right before the ref: probably a code identifier, #1874 item 7) that names no focus falls back to the
      # strict unqualified lookup (#1868 review); only a HARD one is a typed ambiguity.
      if [ -z "$_vc_qp" ] && { [ "$qkind" = soft ] || [ "$qkind" = lead ]; }; then _vc_soft="$qual"; qual=""; fi
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
          *) if [ "$cls" = bare ] || [ "$cls" = mixed ]; then amb "$_vc_rd, number ambiguous across ${numcnt[$n]} other prefixes (advisory)"; continue; fi
             echo "   WARN   B$c declares a correction of [Block $n] but no block-$n file exists in its prefix '$_vc_own' and the number is ambiguous across ${numcnt[$n]} other prefixes; NOT checked"
             unchecked=$((unchecked+1)); continue ;;
        esac
      fi
      if [ -z "$tgt" ]; then
        if [ "$cls" = bare ] || [ "$cls" = mixed ]; then amb "$_vc_rd, no block-$n file exists on disk (advisory)"; continue; fi
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
    if grep -qiE "\bb0*$c\b|\bblock[[:space:]]*0*$c\b|\bbloque[[:space:]]*0*$c\b" < <(LC_ALL=C grep -iE "${_vc_backlink_pre}${_vc_backlink_re})" "$tgt" 2>/dev/null); then
      : # reciprocated
    elif LC_ALL=C grep -qiE "${_vc_noun_re}${c}${_vc_noun_tail}" "$tgt" 2>/dev/null; then
      : # reciprocated by the corrigendum NOUN shape (#1874 item 1)
    elif [ "$cls" = bare ] || [ "$cls" = mixed ]; then
      amb "$_vc_rd with no reciprocal backlink in $(basename "$tgt") (advisory: a ${_vc_adv} ref is checked, never refused)"
    else
      echo "   FAIL   B$c corrects [Block $n] but $(basename "$tgt") has no reciprocal backlink to B$c (accepted: 'corrected in'/'corregido en'/'refined in'/corrigendum/erratum/'CORRECCIÓN — [Block $c]' naming it) (§14) [correcting: $(basename "$f")]${_vc_soft:+ — hint: the backticked token \`$_vc_soft\` named no focus (no block prefix, no FOCUSES.md row), so the own prefix was searched; add a FOCUSES.md row for it, or write the word \`focus\` next to it (of the \`$_vc_soft\` focus) to resolve it}"
      rc=1
    fi
  done
done

[ "$unbound" -eq 0 ] || echo "   note   $unbound correction verb(s) governed no bracketed [Block N] ref in their own clause (unbound, or a word that merely contains the verb) and were NOT checked (#1790)"
[ "$negated" -eq 0 ] || echo "   note   $negated correction verb(s) were negated ('corrects nothing in B21', 'no corrige') and declare nothing (#1874): $negnames"
[ "$skipped" -eq 0 ] || echo "   note   $skipped correction verb(s) in a non-assertive form (passive 'se corrige', conditional, or past tense) were skipped, not treated as declarations (#1835): $skipnames"
if [ "$rc" -eq 0 ]; then
  _vc_partial=$((unchecked+ambiguous+negated))
  if [ "$_vc_partial" -eq 0 ]; then echo "   ok     every declared correction has its reciprocal 'corrected in BN' backlink."
  else echo "   ok-partial $_vc_partial declared correction(s) NOT checked (ambiguous/missing target: $ambiguous AMBIG, $unchecked WARN; $negated negated) — see WARN/AMBIG above"; fi
fi
echo "== exit $rc =="
exit $rc

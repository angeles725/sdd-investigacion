#!/usr/bin/env bash
# census-target.sh — file-type histogram over ALL files in a research target.
# BOOTSTRAP mandatory step a2 (METHODOLOGY §6). Run BEFORE building the coverage matrix.
#
# WHY: a coverage matrix built from what you already noticed cannot surface what you never
# looked at. This failure is not laziness — it is structural: if you populate the backlog
# from files that already drew your attention, the invisible corpus (Access databases nobody
# opened, Visio diagrams nobody printed, compiled DDC programs nobody counted) never enters
# any gap. One three-second command surfaces all of it.
#
# Usage:  census-target.sh <target-path> [--threshold-count N] [--threshold-mb M] [--state <RESEARCH-STATE.md>]
# Defaults: N=5 (types with >= N files are starred), M=1 (OR >= M MB aggregate are starred)
# Output:   extension histogram, count + aggregate MB, sorted by count descending.
#           A type exceeding either threshold is marked * — it must be either CLAIMED by a
#           gap in the backlog or DISMISSED in RESEARCH-STATE '## Dismissed file types'.
# --state (kit #965): cross-check every starred type against the state file's '## Gap-backlog'
#           and '## Dismissed file types' sections. WARN-only (exit stays 0). One typed
#           'Audit cross-check:' line: OK | WARNING (names the unclosed types) | NO-STARRED |
#           INHERITED (declared inherited census, read only from the Dismissed section) |
#           DEGRADED (state absent, state not readable, or neither section present) | not run
#           (no --state). HTML comments and fenced blocks are ignored (template text claims
#           nothing; a '<!--' inside a closed backtick span on the same line is prose (backticks
#           pair per line), an unterminated comment is disclosed). The match is a LITERAL type
#           name as a standalone token (case-insensitive; 'notes.js' / 'x.js.map' claim nothing)
#           written in a deliberate form (kit #1986): with its leading dot in prose ('.js';
#           '.tar.gz' claims 'gz'); as a backtick span whose WHOLE content is a type token or a
#           list of them ('`.pdf`', '`.jpg/.png`', '`.jpg, .png`'; a '/' list needs every item
#           dotted; '`bin/sh`', '`java -jar`', '`js-yaml`', '`db/`' and '`db\`' claim nothing;
#           a multi-item list with a dotless item under 3 characters, '`R&D`' / '`x, y`', claims
#           nothing, while a single-token span '`c`' still does; backticks pair PER LINE, so a
#           span wrapped over two lines claims nothing — multi-line pairing is deliberately not
#           attempted, it would widen claims); or as the head of a Dismissed bullet (a dotted head
#           claims its last segment; a head without a dot claims only in list shape, '- jpg, png —
#           reason', and with >= 3 characters, so '- Lock files' claims nothing; a '/' head list
#           with a dotless item of 4+ characters is a path and claims nothing: '- vendor/js —
#           ...', while '- jpg/png' still claims). A bare prose word never claims.
#           '(no ext)' for extensionless files. A level-1 or level-2 heading ends a section
#           (ATX '# '/'## ' indented 0-3 spaces, or a setext title over '===' / '---' directly
#           below a non-blank paragraph line; a '---' after a blank line is a thematic break).
#           --state '' exits 2. A gap that
#           encompasses a type without naming it ("all images") is reported as a WARNING and
#           must be confirmed by hand — the instrument reports what it matched, not what a
#           human would read as covered.
# Exit:   0 = ok (information tool; the audit obligation is on the researcher)
#         2 = bad args
set -uo pipefail

TARGET=""
THRESH_COUNT=5
THRESH_MB=1
STATE=""

# Parse: first non-flag positional is TARGET; --threshold-count and --threshold-mb are optional.
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold-count) THRESH_COUNT="${2:-5}"; shift 2;;
    --threshold-mb)    THRESH_MB="${2:-1}";    shift 2;;
    --state)
      if [ $# -lt 2 ] || [ -z "$2" ]; then echo "census-target: --state needs a non-empty path" >&2; exit 2; fi
      STATE="$2"; shift 2;;
    -h|--help)
      echo "usage: census-target.sh <target-path> [--threshold-count N] [--threshold-mb M] [--state <RESEARCH-STATE.md>]" >&2
      exit 0;;
    -*)
      echo "census-target: unknown flag: $1" >&2; exit 2;;
    *)
      if [ -z "$TARGET" ]; then TARGET="$1"; else echo "census-target: unexpected extra arg: $1" >&2; exit 2; fi
      shift;;
  esac
done

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "usage: census-target.sh <target-path> [--threshold-count N] [--threshold-mb M] [--state <RESEARCH-STATE.md>]" >&2
  exit 2
fi

THRESH_MB_BYTES=$(( THRESH_MB * 1048576 ))

echo "== File-type census: ${TARGET} =="
echo "   Threshold: >= ${THRESH_COUNT} files OR >= ${THRESH_MB} MB aggregate → starred (*)"
echo "   Starred types must be CLAIMED by a backlog gap OR DISMISSED with a reason."
echo ""
printf "  %-16s  %8s  %10s  %s\n" "Extension" "Files" "Size MB" "Flag"
printf "  %-16s  %8s  %10s  %s\n" "---------" "-----" "-------" "----"

# Collect size+path for every non-git file, then aggregate by extension.
# find -printf '%s %p\n' yields bytes then full path with zero subprocesses —
# one scan vs. one stat(1) per file. Path may contain spaces; awk reconstructs
# it as substr($0, length($1) + 2). The sort prefix keeps output stable.
# Stderr is captured so unreadable subtrees surface as a WARNING instead of
# silent undercounts — the structural failure this tool was built to prevent.
_ferr=$(mktemp)
_hist=$(find "$TARGET" -type f -not -path '*/.git/*' -printf '%s %p\n' 2>"$_ferr" \
  | awk -v tc="$THRESH_COUNT" -v tm="$THRESH_MB_BYTES" '
  {
    sz = $1
    # path = everything after the size field and one space
    path = substr($0, length($1) + 2)
    # extract basename (last path component)
    n = split(path, a, "/"); base = a[n]
    # extract extension: last .xxx where . is NOT the first character of basename
    # (so .dotfiles have no extension)
    if (match(base, /\.[^.]+$/) && RSTART > 1) {
      ext = tolower(substr(base, RSTART + 1))
    } else {
      ext = "(no ext)"
    }
    cnt[ext]++
    bytes[ext] += sz
  }
  END {
    for (e in cnt) {
      mb = bytes[e] / 1048576.0
      flag = (cnt[e] >= tc + 0 || bytes[e] >= tm + 0) ? "*" : ""
      # sort key: zero-padded count (descending after sort -rn)
      printf "%010d\t%-16s  %8d  %10.1f  %s\n", cnt[e], e, cnt[e], mb, flag
    }
  }' \
  | sort -rn \
  | sed 's/^[0-9]*\t/  /')
[ -n "$_hist" ] && printf '%s\n' "$_hist"
_unreadable=$(wc -l < "$_ferr")
rm -f "$_ferr"
if [ "$_unreadable" -gt 0 ]; then
  # Route to stdout so the warning travels with any captured output (e.g. `> census.txt` or
  # a paste into RESEARCH-STATE). An undercount invisible only on stderr is indistinguishable
  # from a clean census once the report is archived — the exact failure this tool was built
  # to prevent, re-entering one level up. Placement here (after the histogram, before the
  # audit-obligation block) keeps the caveat next to the numbers it qualifies.
  printf 'WARNING: %d path(s) could not be traversed (permission denied); counts above may undercount the corpus.\n' "$_unreadable"
fi

echo ""
echo "== Audit obligation for starred types (*) =="
echo "   Each starred type must appear in one of:"
echo "   1. A pending or covered gap in RESEARCH-STATE '## Gap-backlog' that explicitly"
echo "      names or encompasses this file type."
echo "   2. RESEARCH-STATE '## Dismissed file types' section:"
echo "      - .<ext> — <N> files · <M> MB — dismissed: <reason>"
echo "   A starred type in neither is an unclosed audit hole."

# --- Audit cross-check (kit #965) -------------------------------------------------------------
# Starred rows end in '*'; the extension is every field before the trailing count/size/flag
# triple ('(no ext)' spans two fields).
echo ""
if [ -z "$STATE" ]; then
  echo "Audit cross-check: not run (pass --state <RESEARCH-STATE.md> to cross-check starred types against the backlog and Dismissed file types)"
  exit 0
fi
if [ ! -e "$STATE" ]; then
  echo "Audit cross-check: DEGRADED — state file absent (${STATE}); starred types were NOT cross-checked"
  exit 0
fi
if [ ! -f "$STATE" ] || [ ! -r "$STATE" ]; then
  echo "Audit cross-check: DEGRADED — state file not readable (${STATE}; a directory or no read permission); starred types were NOT cross-checked"
  exit 0
fi
_stars=$(printf '%s\n' "$_hist" | awk 'NF >= 4 && $NF == "*" { e = ""; for (i = 1; i <= NF - 3; i++) e = e (i > 1 ? " " : "") $i; print e }')
# Live text = the state file minus HTML comments (single- and multi-line; template text lives
# there) and fenced blocks (examples). A heading inside either is therefore not a section. A
# '<!--' inside a CLOSED backtick span on the SAME line is prose (inline code), not a comment
# opener (backticks pair per line); an unpaired backtick is not a span, so it can never hide a
# real comment (a leaked template comment would be a false closure). A comment still open at EOF
# is reported out-of-band through a flag file, never through the text stream.
_ucouldnot=no
_uflag=$(mktemp) || { _uflag=/dev/null; _ucouldnot=yes; }
_live=$(awk -v uflag="$_uflag" '
  { line = $0; out = ""
    while (length(line) > 0) {
      if (inc) { i = index(line, "-->"); if (i == 0) line = ""; else { line = substr(line, i + 3); inc = 0 } }
      else {
        i = index(line, "<!--"); b = index(line, "`")
        if (b > 0 && (i == 0 || b < i)) {
          c = index(substr(line, b + 1), "`")
          if (c == 0) { out = out substr(line, 1, b); line = substr(line, b + 1) }
          else { out = out substr(line, 1, b + c); line = substr(line, b + c + 1) }
        } else if (i == 0) { out = out line; line = "" }
        else { out = out substr(line, 1, i - 1); line = substr(line, i + 4); inc = 1 }
      }
    }
    if (out ~ /^[[:space:]]*(```|~~~)/) { fence = !fence; next }
    if (!fence) print out
  }
  END { if (inc) print "unterminated" > uflag }' "$STATE")
_unterminated=no
[ -s "$_uflag" ] && _unterminated=yes
[ "$_uflag" = /dev/null ] || rm -f "$_uflag"
# Heading normalisation (kit #2007): a 1-3-space-indented ATX heading ('  ## Notes') and a setext
# heading ('Title' over '====' = level 1, over '----' = level 2) end/strip a section exactly like a
# column-0 '# ' / '## ' line, so they are rewritten to that canonical form here and every consumer
# below stays unchanged. A setext underline needs a non-blank paragraph line directly above it (a
# '---' after a blank line is a thematic break, not a heading) that is not already a heading, a
# list item or a block quote (CommonMark: those start another block); only the line directly above
# is the title (no multi-line paragraph titles). An empty '#' / '##' line is a heading too.
_live=$(awk '
  { L[NR] = $0 }
  END {
    for (n = 1; n <= NR; n++) {
      s = L[n]
      if (s ~ /^ ? ? ?##?([[:space:]]|$)/) { sub(/^ +/, "", s); if (s ~ /^##?$/) s = s " "; L[n] = s; H[n] = 1; continue }
      if (n > 1 && s ~ /^ ? ? ?(=+|-+)[[:space:]]*$/ && L[n - 1] !~ /^[[:space:]]*$/ && !H[n - 1] && !D[n - 1] \
          && L[n - 1] !~ /^ ? ? ?([-*+]|[0-9]+[.)])([[:space:]]|$)/ && L[n - 1] !~ /^ ? ? ?>/) {  # SENTINEL-SETEXT
        t = L[n - 1]; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
        L[n - 1] = ((s ~ /^ ? ? ?=/) ? "# " : "## ") t; H[n - 1] = 1; D[n] = 1
      }
    }
    for (n = 1; n <= NR; n++) if (!D[n]) print L[n]
  }' <<<"$_live")
# Claim text = the two sections that can close the obligation (any other section is out of scope).
# A level-1 or level-2 heading ends a section; '###' and deeper stay inside it (indented and setext
# headings were normalised to this column-0 form above, kit #2007).
_claims=$(awk '/^#[[:space:]]/ || /^##[[:space:]]/ { p = ($0 ~ /^##[[:space:]]+(Gap-backlog|Dismissed file types)/) } p' <<<"$_live")
_dismissed=$(awk '/^#[[:space:]]/ || /^##[[:space:]]/ { p = ($0 ~ /^##[[:space:]]+Dismissed file types/) } p' <<<"$_live")
_has_backlog=no; grep -qE '^##[[:space:]]+Gap-backlog' <<<"$_live" && _has_backlog=yes
_has_dismissed=no; grep -qE '^##[[:space:]]+Dismissed file types' <<<"$_live" && _has_dismissed=yes
if [ "$_has_backlog" = no ] && [ "$_has_dismissed" = no ]; then
  echo "Audit cross-check: DEGRADED — state has neither a '## Gap-backlog' nor a '## Dismissed file types' section outside comments and fenced blocks (${STATE}); no claim could be read"
  [ "$_unterminated" = yes ] && echo "   note: state has an unterminated HTML comment ('<!--' with no '-->'); every line after it was ignored"
  [ "$_ucouldnot" = yes ] && echo "   note: unterminated-comment check: could not verify (no temp file)"
  exit 0
fi
if [ -z "$_stars" ]; then
  echo "Audit cross-check: NO-STARRED — no type met the thresholds; nothing to cross-check"
  exit 0
fi
_total=$(printf '%s\n' "$_stars" | wc -l)
if grep -qiE '^[[:space:]]*-[[:space:]]*none[[:space:]]+(—|--)[[:space:]]+census inherited' <<<"$_dismissed"; then
  echo "Audit cross-check: INHERITED — Dismissed file types declares a census inherited from the parent corpus; ${_total} starred type(s) not cross-checked here"
  exit 0
fi
# A type is CLAIMED only by a deliberate form (kit #1986): (1) its leading dot in live prose
# ('.js'; a compound '.tar.gz' claims its LAST segment 'gz', never 'tar'), (2) a backtick span
# whose WHOLE trimmed content is a type token or a list of them ('.pdf', 'pdf', '.jpg, .png',
# '.jpg/.png' (a slash list needs every item dotted), '.tar.gz'; spans pair per line), or (3) the head of a '## Dismissed file types'
# bullet. A bare prose word never claims ("XML parser" does not close .xml). Prose tokens are
# standalone: not preceded by an alphanumeric, '_', '.', '/' or '-' (so 'notes.js', 'a/js' and
# 'non-js' claim nothing), not followed by an alphanumeric or '_' or by '.'+alphanumeric (so
# 'x.js.map' claims nothing, a sentence-final '.js.' does).
_lead='(^|[^[:alnum:]_./-])'
_trail='([^[:alnum:]_.]|\.([^[:alnum:]_]|$)|$)'
# _claimed = exact lowercase type names claimed by spans and Dismissed heads, one per line.
_claimed=""
_tok_re='^(\.[[:alnum:]_]+(\.[[:alnum:]_]+)*|[[:alnum:]_]+)$'
_cand_re='^([^[:space:],/\&:]+)(.*)$'
# A dotted token claims its LAST segment ('.tar.gz' -> gz); a bare token claims itself.
_add_dotted() { local t="${1#.}"; _claimed="${_claimed}${t##*.}"$'\n'; }
_add_bare() { _claimed="${_claimed}${1}"$'\n'; }
# _parse_list <text>: split a leading list of type tokens ('a, b/c & d'). Sets _items (a token that
# is not a valid type token, or a separator not followed by a valid token, is recorded as '!' and
# ends the list; _seps holds the separator that preceded each item), _rest (text after the list,
# leading spaces removed) and _term=1 when the list is followed by EOL, an em dash, ':' , '--' or
# ' - '. Token delimiters: whitespace , / & : (an em dash is spaced first). A hyphenated, dotless
# compound ('pdf.js', 'tar.gz') or path-touching token ('db\') is invalid.
_parse_list() {
  local rest="${1//—/ — }" item sep=""
  _items=(); _seps=(); _term=0
  while :; do
    rest="${rest#"${rest%%[![:space:]*\`~]*}"}"
    if [[ "$rest" =~ $_cand_re ]]; then
      item="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    else
      [ -n "$sep" ] && _items+=("!")
      break
    fi
    while [[ "$item" == *[\*\`~] ]]; do item="${item%?}"; done
    if ! [[ "$item" =~ $_tok_re ]]; then _items+=("!"); break; fi
    _items+=("$item"); _seps+=("$sep"); sep=""
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$rest" in
      [,/\&]*) sep="${rest:0:1}"; rest="${rest:1}"; continue;;
    esac
    break
  done
  rest="${rest#"${rest%%[![:space:]]*}"}"
  _rest="$rest"
  case "$rest" in ""|—*|:*|--*|"- "*|-) _term=1;; esac
}
# Spans: the whole trimmed content must be a clean list (no '!' token, nothing left over).
while IFS= read -r _sp; do
  [ -n "$_sp" ] || continue
  _parse_list "$_sp"
  [ -z "$_rest" ] || continue
  [ "${#_items[@]}" -gt 0 ] || continue
  [[ " ${_items[*]} " == *" ! "* ]] && continue  # SENTINEL-SPAN-BANG
  # A '/'-joined list in a span ('src/js', 'bin/sh') is a path unless every item is dotted
  # ('.jpg/.png'); ',' and '&' lists are not restricted.
  _slash_ok=1
  if [[ "${_seps[*]}" == */* ]]; then
    for _it in "${_items[@]}"; do [[ "$_it" == .* ]] || _slash_ok=0; done
  fi
  [ "$_slash_ok" = 1 ] || continue
  # A multi-item list ('R&D', 'x, y') refuses wholly when a bare (dotless) item is under 3
  # characters (kit #2007); a single-token span ('c', 'js') is exact and still claims.
  _short_ok=1
  if [ "${#_items[@]}" -gt 1 ]; then
    for _it in "${_items[@]}"; do [[ "$_it" == .* || "$_it" == "!" ]] || [ "${#_it}" -ge 3 ] || _short_ok=0; done  # SENTINEL-SPAN-SHORT
  fi
  [ "$_short_ok" = 1 ] || continue
  for _it in "${_items[@]}"; do
    if [[ "$_it" == .* ]]; then _add_dotted "$_it"; else _add_bare "$_it"; fi
  done
done < <(grep -o '`[^`]*`' <<<"$_claims" | tr -d '`')
# Dismissed heads: a DOTTED head token claims its last segment; a head token WITHOUT a leading
# dot claims only in list shape (followed directly by , / & and another token, or by an em dash,
# ':' , ' - ', EOL) and only with >= 3 characters ('- Lock files' and 'A handful of .so files'
# claim nothing).
while IFS= read -r _hl; do
  _hl=$(sed -nE 's/^[[:space:]]*[-*+][[:space:]]+(.*)$/\1/p' <<<"$_hl")
  [ -n "$_hl" ] || continue
  _parse_list "$_hl"
  [[ " ${_items[*]} " == *" ! "* ]] && continue  # SENTINEL-HEAD-BANG
  # A '/' list whose bare (dotless) item has 4+ characters is a path ('vendor/js'): the whole list
  # claims nothing (kit #2007); 'jpg/png' and 'bbb/ccc' (<= 3 characters) still claim.
  _hpath=0
  if [[ "${_seps[*]}" == */* ]]; then
    for _it in "${_items[@]}"; do [[ "$_it" == .* ]] || [ "${#_it}" -lt 4 ] || _hpath=1; done  # SENTINEL-HEAD-PATH
  fi
  [ "$_hpath" = 0 ] || continue
  _n=${#_items[@]}
  for ((_i = 0; _i < _n; _i++)); do
    _it="${_items[_i]}"
    [ "$_it" = "!" ] && break
    if [[ "$_it" == .* ]]; then
      _add_dotted "$_it"
    elif [ "${#_it}" -ge 3 ] && { [ "$_i" -lt $((_n - 1)) ] || [ "$_term" = 1 ]; }; then
      _add_bare "$_it"
    fi
  done
done <<<"$_dismissed"
_claimed=$(tr 'A-Z' 'a-z' <<<"$_claimed")
_holes=""; _nholes=0
while IFS= read -r _e; do
  [ -n "$_e" ] || continue
  if [ "$_e" = "(no ext)" ]; then
    grep -qiF -- "(no ext)" <<<"$_claims" && continue
  else
    # Escape regex metacharacters in the extension.
    _re=$(printf '%s' "$_e" | sed 's/[][\.*^$+?(){}|/-]/\\&/g')
    _seg='(\.[[:alnum:]_]+)*'
    grep -qiE -- "${_lead}${_seg}\.${_re}${_trail}" <<<"$_claims" && continue
    grep -qixF -- "$_e" <<<"$_claimed" && continue
  fi
  _nholes=$((_nholes + 1))
  if [ "$_e" = "(no ext)" ]; then _holes="${_holes} (no ext)"; else _holes="${_holes} .${_e}"; fi
done <<< "$_stars"
if [ "$_nholes" -gt 0 ]; then
  echo "Audit cross-check: WARNING: ${_nholes} of ${_total} starred type(s) named in neither Gap-backlog nor Dismissed file types:${_holes}"
  echo "   (literal-name match only: a gap that encompasses a type without naming it must be confirmed by hand)"
else
  echo "Audit cross-check: OK — all ${_total} starred type(s) are named in Gap-backlog or Dismissed file types (by literal name; a type named in a gap that does not cover it still reads OK)"
fi
[ "$_has_dismissed" = no ] && echo "   note: state has no '## Dismissed file types' section"
[ "$_unterminated" = yes ] && echo "   note: state has an unterminated HTML comment ('<!--' with no '-->'); every line after it was ignored, so a claim there was NOT read"
[ "$_ucouldnot" = yes ] && echo "   note: unterminated-comment check: could not verify (no temp file)"
exit 0

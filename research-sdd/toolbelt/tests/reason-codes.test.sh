#!/usr/bin/env bash
# reason-codes.test.sh — coverage test for research-sdd/toolbelt/reason-codes.v1.md (kit issue #1704, slice 1).
#
# The registry is a closed table: one row per `degraded:` class emitted today, plus the three typed
# input classes, each row naming exactly one continuation. This suite extracts the emitted `degraded:`
# tokens from the five scanned scripts and proves the registry and the emitters agree:
#
#   - an emitted token that is not a registry code            -> FAIL (unlisted code)
#   - a registry degraded row that no scanned script emits    -> FAIL (stale row)
#   - an emitter that the row does not list                   -> FAIL (emitter mismatch)
#   - a listed emitter that never emits that code             -> FAIL (stale emitter; kit issue #1725 item 1)
#   - a non-comment line with `degraded: ` that is not a single-line echo/printf (continued line,
#     heredoc, variable assignment, helper, trailing-comment or quoted-hash mention) -> FAIL (unclassifiable; the extractor cannot read it, so a
#     clean result would be a silent zero; kit issue #1725 item 2)
#   - a row with an empty / placeholder continuation          -> FAIL
#   - malformed row, duplicate code, bad class, missing required input row -> FAIL
#   - registry or script absent, unreadable, or ZERO emit lines extracted -> typed DEGRADED, exit 2
#     (could-not-look is not clean: a zero that cannot prove it looked is the CLAUDE.md section 7 defect)
#
# EXTRACTION RULE (the same text is in reason-codes.v1.md, "How a code is derived"). For every
# non-comment line containing an `echo` or `printf` word AND the literal `degraded: `:
#   1. start at the first `degraded: `
#   2. replace shell expansions (${...}, $(...) without nested parentheses, $name, and the single-character
#      parameters $0-$9 $? $@ $# $* $! $$) and %s / %d with <v>, then collapse runs of <v>
#   3. cut at the first " — " (em dash), literal \n, or closing double quote
#   4. strip trailing whitespace and trailing <v>
# Comment lines, grep patterns (no echo/printf) and variable assignments are never emit lines.
#
# Usage: reason-codes.test.sh [--prove-teeth]
#        reason-codes.test.sh --check-only REGISTRY SCRIPT_DIR   (internal: the degraded checker alone, exit 0/1/2)
#        reason-codes.test.sh --check-input REGISTRY TOOLBELT_DIR (internal: the input-class scan alone, exit 0/1/2;
#          kit issue #1704 slice 2 — the scan, its recognised forms and its waivers are declared in reason-codes.v1.md)
# Exit: 0 all held · 1 any failure · 2 typed DEGRADED (could not look).
set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"

SELF="${BASH_SOURCE[0]}"
HERE="$(cd "$(dirname "$SELF")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
REGISTRY="$HERE/../reason-codes.v1.md"
TOOLBELT="$HERE/.."

SCRIPTS=(research-sdd-status.sh reconcile-issues.sh stage-retro-issues.sh research-sdd-init.sh migrate-backlogs.sh)
REQUIRED_INPUT=(absent-input empty-input unclassifiable)

# The extraction rule as an awk program (kept in one place; teeth mutate individual lines of it).
EXTRACT_AWK='
/^[[:space:]]*#/ {next}                                                    # TOOTH-COMMENT
/(^|[^[:alnum:]_])(echo|printf)[[:space:]]/ && index($0, "degraded: ") {
  s = substr($0, index($0, "degraded: "))
  gsub(/\$\{[^}]*\}/, "<v>", s)
  gsub(/\$\([^)]*\)/, "<v>", s)                                           # TOOTH-CMDSUB
  gsub(/\$[A-Za-z_][A-Za-z0-9_]*/, "<v>", s)                               # TOOTH-VARSUB
  gsub(/\$[0-9?@#*!$]/, "<v>", s)                                          # TOOTH-SPECIALSUB
  gsub(/%[sd]/, "<v>", s)
  i = index(s, " — "); if (i) s = substr(s, 1, i - 1)                      # TOOTH-EMDASH
  i = index(s, "\\n"); if (i) s = substr(s, 1, i - 1)
  i = index(s, "\""); if (i) s = substr(s, 1, i - 1)
  while (gsub(/<v><v>/, "<v>", s));
  while (sub(/([[:space:]]+|<v>)$/, "", s));
  print s
}'

# Lines the extractor cannot classify: non-comment lines carrying `degraded: ` that are not a single-line
# echo/printf. ONLY a line that starts with a comment is excluded: a ` #` before the token (even inside a
# quoted string, e.g. "see #2 degraded: x") is NOT a comment boundary here. Output: LINENO:text.
UNCLASS_AWK='
/^[[:space:]]*#/ {next}
{
  p = index($0, "degraded: "); if (!p) next
  if ($0 ~ /(^|[^[:alnum:]_])(echo|printf)[[:space:]]/) next
  print NR ":" $0
}'

# Registry rows: lines whose first cell is a backticked code. Header/separator/prose tables have no
# backticked first cell and are ignored. Output: code US class US emitters US continuation (US = \037),
# or MALFORMED US <line> when the row is not exactly five cells.
ROWS_AWK='
function trim(x) { sub(/^[ \t]+/, "", x); sub(/[ \t]+$/, "", x); return x }
/^\| `/ {
  if (NF != 7) { print "MALFORMED\037" $0; next }
  c = trim($2); sub(/^`/, "", c); sub(/`$/, "", c)
  print c "\037" trim($3) "\037" trim($4) "\037" trim($6)
}'

nfind=0
finding() { printf 'FINDING: %s\n' "$*"; nfind=$((nfind + 1)); }

# rc_check REGISTRY SCRIPT_DIR — prints FINDING:/DEGRADED: lines; rc 0 clean · 1 findings · 2 degraded.
rc_check() {
  local reg="$1" dir="$2" rows s path toks tok req found idx i n
  local -a codes=() classes=() emits=() used=()
  local c cl em ct lc pairs=';' uc e
  nfind=0

  if [ ! -f "$reg" ] || [ ! -r "$reg" ]; then
    printf 'DEGRADED: registry absent or unreadable: %s\n' "$reg"; return 2
  fi
  rows="$(awk -F'|' "$ROWS_AWK" "$reg")" || { printf 'DEGRADED: awk failed reading registry %s\n' "$reg"; return 2; }
  if [ -z "$rows" ]; then                                                  # TOOTH-ZEROROWS
    printf 'DEGRADED: registry %s has zero parsable rows\n' "$reg"; return 2
  fi

  n=0
  while IFS=$'\037' read -r c cl em ct; do
    if [ "$c" = "MALFORMED" ]; then
      finding "malformed registry row (need exactly five cells): $cl"; continue
    fi
    if [ -z "$c" ]; then finding "registry row with an empty code"; continue; fi
    for ((i = 0; i < ${#codes[@]}; i++)); do
      if [ "${codes[$i]}" = "$c" ]; then finding "duplicate code: $c"; fi        # TOOTH-DUP
    done
    codes[n]="$c"; classes[n]="$cl"; emits[n]="$em"; n=$((n + 1))
    case "$cl" in
      degraded) case "$c" in "degraded: "*) ;; *) finding "degraded-class code does not start with 'degraded: ': $c" ;; esac ;;
      input) ;;
      *) finding "unknown class '$cl' for code: $c" ;;                      # TOOTH-CLASS
    esac
    if [ -z "$ct" ]; then finding "empty continuation for code: $c"; fi       # TOOTH-EMPTYCONT
    lc="$(printf '%s' "$ct" | tr '[:upper:]' '[:lower:]')"
    case "$lc" in
      -|n/a|tbd|todo|none) finding "placeholder continuation '$ct' for code: $c" ;;   # TOOTH-PLACEHOLDER
    esac
    if [ -z "$em" ]; then finding "empty emitters for code: $c"; fi
  done <<<"$rows"

  for req in "${REQUIRED_INPUT[@]}"; do
    found=0
    for ((i = 0; i < n; i++)); do
      if [ "${codes[$i]}" = "$req" ] && [ "${classes[$i]}" = "input" ]; then found=1; fi
    done
    if [ "$found" -eq 0 ]; then finding "required input-class row missing: $req"; fi   # TOOTH-REQINPUT
  done

  for s in "${SCRIPTS[@]}"; do
    path="$dir/$s"
    if [ ! -f "$path" ] || [ ! -r "$path" ]; then
      printf 'DEGRADED: scanned script absent or unreadable: %s\n' "$path"; return 2
    fi
    toks="$(awk "$EXTRACT_AWK" "$path")" || { printf 'DEGRADED: awk failed reading %s\n' "$path"; return 2; }
    if [ -z "$toks" ]; then                                                 # TOOTH-ZEROEXTRACT
      printf 'DEGRADED: extracted zero degraded emit lines from %s (could not look)\n' "$s"; return 2
    fi
    uc="$(awk "$UNCLASS_AWK" "$path")" || { printf 'DEGRADED: awk failed reading %s\n' "$path"; return 2; }
    if [ -n "$uc" ]; then
      while IFS= read -r e; do
        finding "unclassifiable degraded: line in $s:${e%%:*} (not a single-line echo/printf): ${e#*:}"   # TOOTH-UNCLASS
      done <<<"$uc"
    fi
    while IFS= read -r tok; do
      idx=-1
      for ((i = 0; i < n; i++)); do
        if [ "${codes[$i]}" = "$tok" ]; then idx=$i; fi
      done
      if [ "$idx" -lt 0 ]; then
        finding "unlisted code emitted by $s: $tok"                           # TOOTH-UNLISTED
        continue
      fi
      used[idx]=1
      pairs="$pairs$idx:$s;"
      em="$(printf '%s' "${emits[$idx]}" | tr -d ' ')"
      case ",$em," in
        *",$s,"*) ;;
        *) finding "emitter mismatch: $s emits '$tok' but the row lists '${emits[$idx]}'" ;;   # TOOTH-EMITTER
      esac
    done <<<"$toks"
  done

  for ((i = 0; i < n; i++)); do
    if [ "${classes[$i]}" = "degraded" ] && [ -z "${used[$i]:-}" ]; then
      finding "stale row: degraded code never emitted by a scanned script: ${codes[$i]}"   # TOOTH-STALE
    fi
  done

  # Reverse direction (kit issue #1725 item 1): every emitter a degraded row lists must emit that code.
  for ((i = 0; i < n; i++)); do
    [ "${classes[$i]}" = "degraded" ] || continue
    [ -n "${used[$i]:-}" ] || continue   # a never-emitted row is already reported as stale
    for e in $(printf '%s' "${emits[$i]}" | tr ',' ' '); do
      case "$pairs" in
        *";$i:$e;"*) ;;
        *) finding "stale emitter: row lists $e but $e never emits '${codes[$i]}'" ;;   # TOOTH-STALEEMIT
      esac
    done
  done

  [ "$nfind" -eq 0 ]
}

# --- input-class scan (kit issue #1704, slice 2) -------------------------------------------------
# The vocabulary is closed: these four tokens are the typed input states (CLAUDE.md section 7). A new token
# needs the scanner AND the registry updated together; an input-class registry row outside this list is
# reported "not scannable" so a row can never be added that nothing could ever verify.
IC_TOKENS=(absent-input empty-input unclassifiable no-match)

# Prose mentions that look like an emission but are not one. Each waiver is `file|substring|count|reason` and
# silences exactly `count` occurrences on lines of `file` containing `substring`. Fewer matches (stale) or more
# (a new real emission now hiding behind the substring) are both findings, so the list cannot become a blanket
# ignore and cannot swallow a later emission. Line numbers are not used: they drift with every edit.
IC_WAIVERS=(
  'verify-state.sh|document before closing as absent-input|1|advice text inside a WARN line, not a typed state'
  'verify-sources.sh|empty-input digests|2|names the empty-input DIGEST check (a hash of empty input), a different concept'
  'verify-block.sh|empty-input digests|2|names the empty-input DIGEST check (a hash of empty input), a different concept'
  'stage-retro-issues.sh|unclassifiable tracker|6|scrub-refusal prose naming the tracker issue, not the state'
  'stage-retro-issues.sh|unclassifiable item set|1|body text of the tracker issue, not a state emission'
  'verify-registry.sh|unclassifiable-blocks WARN|1|first mention of the same message whose noun phrase is recognised as an emit-marker later in this file'
)

# Classifier: one record per occurrence of a token on a non-comment line, tab separated:
#   FILE LINENO TOKEN CLASS TEXT
# A token is a word-bounded occurrence (a hyphen or alphanumeric neighbour makes it a different word, so
# unclassifiable-items / -row / -blocks are NOT occurrences). `\t` / `\n` escapes are blanked first so
# `%d\tunclassifiable` is seen. Each line is also MASKED with a small quote-state machine (single quotes,
# double quotes with backslash escapes, a ` #` outside both starts a comment): quoted characters become Q and the
# comment tail becomes C, so "is this outside quotes" questions are answered on the mask. CLASS, first match wins:
#   counter       TOKEN= , $TOKEN , ${TOKEN , or inside $(( .. )) arithmetic: a variable, not a state
#   comment       the token sits in a trailing comment (outside BOTH quote kinds)
#   emit-jq       a jq state literal: then "TOKEN" / else "TOKEN"
#   consumer      the token is the argument of a matcher:
#                   - an UNQUOTED grep/egrep/fgrep or case command (command position) earlier on the line
#                   - ==, != or =~ immediately before it (shell [[ ]] / jq tests)
#                   - a single = before it, only when an unquoted [ or [[ opens earlier on the line
#                   - a case-pattern line (starts with *, the token before the closing paren)
#                   - an awk pattern line (starts with /, the token before the closing slash, then { or end)
#   emit-echo     the line is an echo/printf
#   emit-assign   an assignment: x=TOKEN, x="TOKEN", jq .f = "TOKEN"
#   emit-marker   a parenthesised marker `(TOKEN` in a string on any other line (helper calls)
#   UNCLASSIFIED  none of the above: the scanner cannot read it
IC_AWK='
BEGIN {
  re = "(^|[^A-Za-z0-9_-])(absent-input|empty-input|unclassifiable|no-match)([^A-Za-z0-9_-]|$)"
  q_assign = "=[ \t]*[\"\047]?$"
  q_eq = "(==|!=|=~)[ \t]*[\"\047]?$"
  q_brk = "[^=!<>][ \t]=[ \t]*[\"\047]?$"
  re_br = "(^|[^[:alnum:]_])\\[\\[?[ \t]"
  cmdre = "(^|[;&|({!]|(^|[[:space:]])(if|then|elif|while|until|do)[[:space:]])[[:space:]]*"
  re_grep = cmdre "(grep|egrep|fgrep)[[:space:]]"
  re_case = cmdre "case[[:space:]]"
}
# lastseg: the part of a masked prefix after its last unquoted command separator (; && || | then do else, or the
# ) that ends a case pattern), i.e. the simple command the token belongs to.
function lastseg(p,   r) {
  r = p
  gsub(/.*(;|&&|\|\||\||[[:space:]](then|do|else)[[:space:]]|\))/, "", r)
  return r
}
function mask(p,   i, n, ch, st, out, prev) {
  n = length(p); st = ""; out = ""; prev = " "
  for (i = 1; i <= n; i++) {
    ch = substr(p, i, 1)
    if (st == "s") {
      if (ch == "\047") { st = ""; out = out ch } else out = out "Q"
    } else if (st == "d") {
      if (ch == "\\") { out = out "Q"; if (i < n) { out = out "Q"; i++ } }
      else if (ch == "\"") { st = ""; out = out ch }
      else out = out "Q"
    } else {
      if (ch == "\\") { out = out ch; if (i < n) { out = out substr(p, i + 1, 1); i++ } }
      else if (ch == "\047") { st = "s"; out = out ch }   # TOOTH-IC-SQ
      else if (ch == "\"") { st = "d"; out = out ch }   # TOOTH-IC-DQ
      else if (ch == "#" && prev ~ /[ \t]/) { while (i <= n) { out = out "C"; i++ } break }   # TOOTH-IC-HASH
      else out = out ch
    }
    prev = ch
  }
  return out
}
/^[[:space:]]*#/ { next }
{
  line = $0; scan = line; gsub(/\\[tn]/, "  ", scan); s = scan; off = 0   # TOOTH-IC-ESCAPE
  mk = mask(scan)
  while (match(s, re)) {
    m = substr(s, RSTART, RLENGTH); rs = RSTART
    pre = ""; if (m !~ /^[a-z]/) { pre = substr(m, 1, 1); m = substr(m, 2) }
    post = ""; if (m ~ /[^a-z]$/) { post = substr(m, length(m)); m = substr(m, 1, length(m) - 1) }
    pl = (pre != "" ? 1 : 0)
    tokstart = off + rs + pl
    off += rs + pl + length(m) - 1
    s = substr(s, rs + pl + length(m))
    prefix = substr(scan, 1, tokstart - 1)
    mp = substr(mk, 1, tokstart - 1)
    sg = lastseg(mp)   # TOOTH-IC-SEG
    c = ""
    if (post == "=") c = "counter"   # TOOTH-IC-CTR-EQ
    if (c == "" && pre == "$") c = "counter"   # TOOTH-IC-CTR-DOLLAR
    if (c == "" && pre == "{") c = "counter"   # TOOTH-IC-CTR-BRACE
    if (c == "" && prefix ~ /\$\(\([^)]*$/) c = "counter"   # TOOTH-IC-CTR-ARITH
    if (c == "" && substr(mk, tokstart, 1) == "C") c = "comment"   # TOOTH-IC-COMMENT
    if (c == "" && pre == "\"" && prefix ~ /(then|else)[ \t]+"$/) c = "emit-jq"   # TOOTH-IC-JQ
    if (c == "" && sg ~ re_grep) c = "consumer"   # TOOTH-IC-CONS-GREP
    if (c == "" && sg ~ re_case) c = "consumer"   # TOOTH-IC-CONS-CASE
    if (c == "" && prefix ~ q_eq) c = "consumer"   # TOOTH-IC-CONS-EQ
    if (c == "" && prefix ~ q_brk && mp ~ re_br) c = "consumer"   # TOOTH-IC-CONS-BRK
    if (c == "" && prefix ~ /^[[:space:]]*\*/ && prefix !~ /\)/ && scan ~ /\)/) c = "consumer"   # TOOTH-IC-CONS-STAR
    if (c == "" && prefix ~ /^[[:space:]]*\// && prefix !~ /\{/ && scan ~ /\/[[:space:]]*(\{|$)/) c = "consumer"   # TOOTH-IC-CONS-SLASH
    if (c == "" && scan ~ /(^|[^[:alnum:]_])(echo|printf)[[:space:]]/) c = "emit-echo"
    if (c == "" && prefix ~ q_assign) c = "emit-assign"   # TOOTH-IC-ASSIGN
    if (c == "" && pre == "(") c = "emit-marker"   # TOOTH-IC-MARKER
    if (c == "") c = "UNCLASSIFIED"
    gsub(/\t/, " ", line)
    printf "%s\t%d\t%s\t%s\t%s\n", F, NR, m, c, line
  }
}'

IC_REPORT=''
# ic_check REGISTRY TOOLBELT_DIR — scans DIR/*.sh and DIR/lib/*.sh. rc 0 clean · 1 findings · 2 degraded.
# Sets IC_REPORT to the coverage declaration (what was traversed, how each occurrence was classified).
ic_check() {
  local reg="$1" dir="$2" rows p rel f ln tok cls txt w wf ws wr
  local c cl em ct i n nfiles=0 nocc=0 key lst row_i e
  local n_counter=0 n_comment=0 n_consumer=0 n_emit=0 n_waived=0 n_py=0
  local -a codes=() classes=() emits=() files=() usedw=() wv=()
  local pairs=';' all='' n_uncl=0
  nfind=0; IC_REPORT=''

  # Waivers: the built-in list, or (test hook) the lines of $RC_IC_WAIVERS_FILE when that variable is set.
  if [ -n "${RC_IC_WAIVERS_FILE:-}" ]; then
    if [ ! -r "$RC_IC_WAIVERS_FILE" ]; then printf 'DEGRADED: waiver file unreadable: %s\n' "$RC_IC_WAIVERS_FILE"; return 2; fi
    while IFS= read -r w || [ -n "$w" ]; do [ -n "$w" ] && wv+=("$w"); done < "$RC_IC_WAIVERS_FILE"
  else
    wv=("${IC_WAIVERS[@]}")
  fi

  if [ ! -f "$reg" ] || [ ! -r "$reg" ]; then
    printf 'DEGRADED: registry absent or unreadable: %s\n' "$reg"; return 2
  fi
  rows="$(awk -F'|' "$ROWS_AWK" "$reg")" || { printf 'DEGRADED: awk failed reading registry %s\n' "$reg"; return 2; }
  if [ -z "$rows" ]; then printf 'DEGRADED: registry %s has zero parsable rows\n' "$reg"; return 2; fi
  n=0
  while IFS=$'\037' read -r c cl em ct; do
    [ "$c" = "MALFORMED" ] && continue   # rc_check owns row-shape findings
    codes[n]="$c"; classes[n]="$cl"; emits[n]="$em"; n=$((n + 1))
  done <<<"$rows"

  if [ ! -d "$dir" ]; then printf 'DEGRADED: scan directory absent: %s\n' "$dir"; return 2; fi
  for p in "$dir"/*.sh "$dir"/lib/*.sh; do
    [ -f "$p" ] || continue
    if [ ! -r "$p" ]; then printf 'DEGRADED: scanned file unreadable: %s\n' "$p"; return 2; fi
    files+=("$p")
  done
  if [ "${#files[@]}" -eq 0 ]; then                                          # TOOTH-IC-ZEROFILES
    printf 'DEGRADED: no *.sh files found under %s or %s/lib (could not look)\n' "$dir" "$dir"; return 2
  fi
  for p in "${files[@]}"; do
    nfiles=$((nfiles + 1))
    rel="${p#"$dir"/}"
    f="$(awk -v F="$rel" "$IC_AWK" "$p")" || { printf 'DEGRADED: awk failed reading %s\n' "$p"; return 2; }
    if [ -n "$f" ]; then all="$all$f"$'\n'; fi
  done
  for p in "$dir"/*.py "$dir"/lib/*.py; do
    [ -f "$p" ] || continue
    grep -qE '(absent-input|empty-input|unclassifiable|no-match)' "$p"; i=$?
    if [ "$i" -gt 1 ]; then printf 'DEGRADED: grep failed reading %s\n' "$p"; return 2; fi
    if [ "$i" -eq 0 ]; then n_py=$((n_py + 1)); fi
  done
  if [ -z "$all" ]; then                                                     # TOOTH-IC-ZEROOCC
    printf 'DEGRADED: found zero input-state occurrences under %s (could not look)\n' "$dir"; return 2
  fi

  while IFS=$'\t' read -r f ln tok cls txt; do
    [ -n "$f" ] || continue
    nocc=$((nocc + 1))
    case "$cls" in
      counter) n_counter=$((n_counter + 1)); continue ;;
      comment) n_comment=$((n_comment + 1)); continue ;;
      consumer) n_consumer=$((n_consumer + 1)); continue ;;
    esac
    wr=''
    for ((i = 0; i < ${#wv[@]}; i++)); do
      w="${wv[$i]}"; wf="${w%%|*}"; ws="${w#*|}"; ws="${ws%%|*}"
      if [ "$wf" = "$f" ] && [[ "$txt" == *"$ws"* ]]; then wr=1; usedw[i]=$(( ${usedw[$i]:-0} + 1 )); break; fi
    done
    if [ -n "$wr" ]; then n_waived=$((n_waived + 1)); continue; fi
    if [ "$cls" = "UNCLASSIFIED" ]; then
      n_uncl=$((n_uncl + 1))
      finding "unclassifiable input-state occurrence in $f:$ln ($tok), not a recognised emit or consumer form: $txt"   # TOOTH-IC-UNCLASS
      continue
    fi
    n_emit=$((n_emit + 1))
    case "$pairs" in *";$tok:$f;"*) ;; *) pairs="$pairs$tok:$f;" ;; esac
  done <<<"$all"

  for ((i = 0; i < ${#wv[@]}; i++)); do
    w="${wv[$i]}"; ws="${w#*|}"; ws="${ws#*|}"; ws="${ws%%|*}"   # the count field
    wr="${usedw[$i]:-0}"
    if [ "$wr" -eq 0 ]; then finding "stale waiver (matches no occurrence): $w"; fi   # TOOTH-IC-STALEWAIVER
    if [ "$wr" -ne 0 ] && [ "$wr" -ne "$ws" ]; then finding "waiver matched $wr occurrence(s), expected $ws (a new emission may be hiding behind it): $w"; fi   # TOOTH-IC-WAIVERCOUNT
  done

  # registry input rows the scanner could never verify
  for ((i = 0; i < n; i++)); do
    [ "${classes[$i]}" = "input" ] || continue
    key=0
    for tok in "${IC_TOKENS[@]}"; do [ "$tok" = "${codes[$i]}" ] && key=1; done
    if [ "$key" -eq 0 ]; then finding "input-class code not scannable (not in the scanner vocabulary): ${codes[$i]}"; fi
  done

  for tok in "${IC_TOKENS[@]}"; do
    row_i=-1
    for ((i = 0; i < n; i++)); do
      if [ "${codes[$i]}" = "$tok" ] && [ "${classes[$i]}" = "input" ]; then row_i=$i; fi
    done
    lst="$(printf '%s' "$pairs" | tr ';' '\n' | awk -F: -v t="$tok" '$1 == t {print $2}')"
    if [ "$row_i" -lt 0 ]; then
      if [ -n "$lst" ]; then finding "unlisted input-class code emitted: $tok (by $(printf '%s' "$lst" | tr '\n' ' '))"; fi   # TOOTH-IC-UNLISTED
      continue
    fi
    if [ -z "$lst" ]; then finding "stale row: input code never emitted by a scanned script: $tok"; continue; fi   # TOOTH-IC-STALEROW
    em="$(printf '%s' "${emits[$row_i]}" | tr -d ' ')"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case ",$em," in
        *",$f,"*) ;;
        *) finding "emitter mismatch: $f emits '$tok' but the row lists '${emits[$row_i]}'" ;;   # TOOTH-IC-EMITTER
      esac
    done <<<"$lst"
    for e in $(printf '%s' "$em" | tr ',' ' '); do
      case $'\n'"$lst"$'\n' in
        *$'\n'"$e"$'\n'*) ;;
        *) finding "stale emitter: row lists $e but $e never emits '$tok'" ;;   # TOOTH-IC-STALEEMIT
      esac
    done
  done

  IC_REPORT="scanned $nfiles shell files (*.sh and lib/*.sh); $nocc token occurrences: $n_emit emit, $n_consumer consumer, $n_counter counter, $n_comment trailing-comment, $n_waived waived, $n_uncl unclassified; $n_py python file(s) mention a token and are out of scope (not shell)"
  printf 'COVERAGE: %s\n' "$IC_REPORT"
  [ "$nfind" -eq 0 ]
}

if [ "${1:-}" = "--check-only" ]; then
  rc_check "${2:?registry}" "${3:?script dir}"
  exit $?
fi
if [ "${1:-}" = "--check-input" ]; then
  ic_check "${2:?registry}" "${3:?toolbelt dir}"
  exit $?
fi

pass=0; fail=0
tmp=''
trap 'rm -rf "$tmp"' EXIT
tmp="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
echo "== reason-codes.test.sh =="

# --- fixtures -----------------------------------------------------------------------------------
# edit FILE SED_EXPR — in-place edit without GNU-only sed -i.
edit() { sed "$2" "$1" > "$1.new" && mv "$1.new" "$1"; }

# mkfix NAME — a good registry + five scanned scripts under $tmp/NAME. Every script ends WITHOUT a
# trailing newline (last-line edge) and the registry's last row has none either.
mkfix() {
  local d="$tmp/$1"
  mkdir -p "$d/scripts"
  printf '%s\n' '# comment line mentioning degraded: nothing' \
    'echo "degraded: remote-visibility: gh not found — cannot verify"' \
    'echo "degraded: remote-visibility: $r url empty or unreadable — unverified"' \
    '[ -n "$x" ] || echo "degraded: jq not found on PATH — x"' > "$d/scripts/research-sdd-status.sh"
  # last line carries no newline
  printf '%s' 'echo "degraded: remote-visibility: gh not found — again"' >> "$d/scripts/research-sdd-status.sh"
  printf '%s\n' 'printf '"'"'degraded: --issues-cache file not readable: %s\n'"'"' "$c" >&2' > "$d/scripts/reconcile-issues.sh"
  printf '%s' 'echo "degraded: gh not found on PATH — install gh" >&2' >> "$d/scripts/reconcile-issues.sh"
  printf '%s' 'echo "degraded: gh not found on PATH — install gh" >&2' > "$d/scripts/stage-retro-issues.sh"
  printf '%s' 'echo "degraded: jq failed on $f — refusing"' > "$d/scripts/research-sdd-init.sh"
  printf '%s\n' 'echo "degraded: migrate-backlogs: mktemp failed" >&2' \
    'echo "degraded: migrate-backlogs: cannot read $f — proposal not computed" >&2' > "$d/scripts/migrate-backlogs.sh"
  printf '%s' 'echo "degraded: migrate-backlogs: mktemp failed" >&2' >> "$d/scripts/migrate-backlogs.sh"
  {
    printf '%s\n' '# fixture registry' '' \
      '| code | class | emitters | meaning | continuation |' \
      '|---|---|---|---|---|' \
      '| `degraded: remote-visibility: gh not found` | degraded | research-sdd-status.sh | m1 | install gh |' \
      '| `degraded: remote-visibility: <v> url empty or unreadable` | degraded | research-sdd-status.sh | m2 | fix the url |' \
      '| `degraded: jq not found on PATH` | degraded | research-sdd-status.sh | m3 | install jq |' \
      '| `degraded: --issues-cache file not readable:` | degraded | reconcile-issues.sh | m4 | pass a readable file |' \
      '| `degraded: gh not found on PATH` | degraded | reconcile-issues.sh, stage-retro-issues.sh | m5 | install gh |' \
      '| `degraded: jq failed on` | degraded | research-sdd-init.sh | m6 | fix settings.json |' \
      '| `degraded: migrate-backlogs: mktemp failed` | degraded | migrate-backlogs.sh | m10 | free TMPDIR space |' \
      '| `degraded: migrate-backlogs: cannot read` | degraded | migrate-backlogs.sh | m11 | fix the permissions |' \
      '| `absent-input` | input | many | m7 | fix the path |' \
      '| `empty-input` | input | many | m8 | confirm emptiness |'
    printf '%s' '| `unclassifiable` | input | many | m9 | inspect by hand |'
  } > "$d/reg.md"
}

# expect LABEL WANT_RC REG DIR [GREP_RE] — run the checker, require the exact rc and (optionally) a line.
expect() {
  local label="$1" want="$2" reg="$3" dir="$4" re="${5:-}" out rc
  out="$(rc_check "$reg" "$dir")"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    no "$label (rc=$rc want=$want)"; printf '%s\n' "$out" | sed 's/^/        /'; return 1
  fi
  if [ -n "$re" ] && ! grep -Eq -- "$re" <<<"$out"; then
    no "$label (rc ok, output lacks /$re/)"; printf '%s\n' "$out" | sed 's/^/        /'; return 1
  fi
  ok "$label"
}

# --- 1. the real registry against the real scripts ---------------------------------------------
out="$(rc_check "$REGISTRY" "$TOOLBELT")"; rc=$?
if [ "$rc" -eq 2 ]; then
  printf '%s\n' "$out"
  echo "DEGRADED: the registry or a scanned script could not be read — nothing was verified" >&2
  exit 2
fi
if [ "$rc" -eq 0 ]; then
  ok "real registry covers every emitted degraded: token and every row has a continuation"
else
  no "real registry vs real scripts"; printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- 1b. input-class scan: the real registry against the real toolbelt (kit issue #1704, slice 2) ----
out="$(ic_check "$REGISTRY" "$TOOLBELT")"; rc=$?
if [ "$rc" -eq 2 ]; then
  printf '%s\n' "$out"
  echo "DEGRADED: the input-class scan could not look — nothing was verified" >&2
  exit 2
fi
if [ "$rc" -eq 0 ]; then
  ok "real registry input rows match the scanned input-state emitters in both directions"
else
  no "real registry input rows vs real toolbelt"; printf '%s\n' "$out" | sed 's/^/        /'
fi
printf '  INFO  input-class coverage: %s\n' "$(printf '%s\n' "$out" | sed -n 's/^COVERAGE: //p')"

# --- 2. extraction rule on a literal fixture ---------------------------------------------------
cat > "$tmp/extract.sh" <<'EOF'
echo "degraded: a b $x c — tail"
printf 'degraded: p q: %s\n' "$z"
echo "degraded: r${_em:+ — }${_em}" >&2
# echo "degraded: commented"
x=1 # not an emit degraded: foo
echo "degraded: sub $1 rc=$? at $(date +%s) end"
grep -qE '^degraded:' file
echo "NOTE: degraded: iconv bad — z"
EOF
want="$(printf '%s\n' 'degraded: a b <v> c' 'degraded: p q:' 'degraded: r' 'degraded: sub <v> rc=<v> at <v> end' 'degraded: iconv bad')"
got="$(awk "$EXTRACT_AWK" "$tmp/extract.sh")"
if [ "$got" = "$want" ]; then ok "extraction rule: placeholders, em-dash/\\n/quote cuts, comment and non-emit lines skipped"
else no "extraction rule"; printf '        got:\n%s\n' "$got" | sed 's/^/        /'; fi

# --- 3. fixtures: good, then each defect --------------------------------------------------------
mkfix good
expect "fixture good registry is clean" 0 "$tmp/good/reg.md" "$tmp/good/scripts"

# expansions beyond ${..}/$name: $(..), $1, $? all normalise to <v> (kit issue #1725 item 3)
mkfix good_sub
printf '\n%s\n%s' 'echo "degraded: cmd $(date +%s) end"' 'echo "degraded: pos $1 rc=$? end"' >> "$tmp/good_sub/scripts/research-sdd-init.sh"
edit "$tmp/good_sub/reg.md" 's/^| `absent-input`/| `degraded: cmd <v> end` | degraded | research-sdd-init.sh | s1 | go |\
| `degraded: pos <v> rc=<v> end` | degraded | research-sdd-init.sh | s2 | go |\
| `absent-input`/'
expect "fixture with \$(..), \$1, \$? expansions is clean" 0 "$tmp/good_sub/reg.md" "$tmp/good_sub/scripts"

# unlisted code: first line, last line (no trailing newline), single-line script
mkfix unl_first
{ printf '%s\n' 'echo "degraded: brand new first"'; cat "$tmp/unl_first/scripts/research-sdd-status.sh"; } > "$tmp/unl_first/s" \
  && mv "$tmp/unl_first/s" "$tmp/unl_first/scripts/research-sdd-status.sh"
expect "unlisted code on the FIRST line fails" 1 "$tmp/unl_first/reg.md" "$tmp/unl_first/scripts" 'unlisted code emitted by research-sdd-status.sh: degraded: brand new first'
mkfix unl_last
printf '\n%s' 'echo "degraded: brand new last"' >> "$tmp/unl_last/scripts/research-sdd-init.sh"
expect "unlisted code on the LAST line (no trailing newline) fails" 1 "$tmp/unl_last/reg.md" "$tmp/unl_last/scripts" 'unlisted code emitted by research-sdd-init.sh: degraded: brand new last'
mkfix unl_single
printf '%s' 'echo "degraded: only unknown one"' > "$tmp/unl_single/scripts/stage-retro-issues.sh"
expect "unlisted code in a single-line script fails" 1 "$tmp/unl_single/reg.md" "$tmp/unl_single/scripts" 'unlisted code emitted by stage-retro-issues.sh: degraded: only unknown one'

# migrate-backlogs.sh is a scanned script (kit issue #1704 slice 3): the same guards apply to it
mkfix unl_mb
printf '\n%s' 'echo "degraded: migrate-backlogs: brand new reason" >&2' >> "$tmp/unl_mb/scripts/migrate-backlogs.sh"
expect "unlisted migrate-backlogs code fails" 1 "$tmp/unl_mb/reg.md" "$tmp/unl_mb/scripts" 'unlisted code emitted by migrate-backlogs.sh: degraded: migrate-backlogs: brand new reason'
# a registry with no migrate-backlogs rows and a script that emits one: only the SCRIPTS membership catches it
mkfix mb_scanned
grep -v 'migrate-backlogs' "$tmp/mb_scanned/reg.md" > "$tmp/mb_scanned/r" && mv "$tmp/mb_scanned/r" "$tmp/mb_scanned/reg.md"
printf '%s' 'echo "degraded: migrate-backlogs: only reason" >&2' > "$tmp/mb_scanned/scripts/migrate-backlogs.sh"
expect "a script missing from the scanned list would hide its codes: scanned, so unlisted fails" 1 "$tmp/mb_scanned/reg.md" "$tmp/mb_scanned/scripts" 'unlisted code emitted by migrate-backlogs.sh'
mkfix stale_mb
edit "$tmp/stale_mb/reg.md" 's/^| `absent-input`/| `degraded: migrate-backlogs: ghost reason` | degraded | migrate-backlogs.sh | g | go |\
| `absent-input`/'
expect "registered migrate-backlogs code that is never emitted fails (stale row)" 1 "$tmp/stale_mb/reg.md" "$tmp/stale_mb/scripts" 'stale row: degraded code never emitted by a scanned script: degraded: migrate-backlogs: ghost reason'
mkfix mb_emitter
printf '\n%s' 'echo "degraded: migrate-backlogs: mktemp failed" >&2' >> "$tmp/mb_emitter/scripts/reconcile-issues.sh"
edit "$tmp/mb_emitter/reg.md" 's/| migrate-backlogs.sh | m10 |/| reconcile-issues.sh | m10 |/'
expect "migrate-backlogs code whose row lists another emitter fails" 1 "$tmp/mb_emitter/reg.md" "$tmp/mb_emitter/scripts" 'emitter mismatch: migrate-backlogs.sh emits'
mkfix mb_absent
rm -f "$tmp/mb_absent/scripts/migrate-backlogs.sh"
expect "migrate-backlogs.sh absent -> DEGRADED rc 2 (not a clean pass)" 2 "$tmp/mb_absent/reg.md" "$tmp/mb_absent/scripts" 'DEGRADED: scanned script absent or unreadable: .*migrate-backlogs.sh'
mkfix mb_zero
printf '%s\n' '# degraded: only in a comment' 'echo "no typed state here"' > "$tmp/mb_zero/scripts/migrate-backlogs.sh"
expect "migrate-backlogs.sh with zero extracted emit lines -> DEGRADED rc 2" 2 "$tmp/mb_zero/reg.md" "$tmp/mb_zero/scripts" 'DEGRADED: extracted zero degraded emit lines from migrate-backlogs.sh'

# empty continuation: first row, middle row, last row, single-row registry
mkfix cont_first
edit "$tmp/cont_first/reg.md" 's/| install gh |$/| |/'
expect "empty continuation in the FIRST row fails" 1 "$tmp/cont_first/reg.md" "$tmp/cont_first/scripts" 'empty continuation for code: degraded: remote-visibility: gh not found'
mkfix cont_mid
edit "$tmp/cont_mid/reg.md" 's/| m5 | install gh |$/| m5 |  |/'
expect "empty continuation in a MIDDLE row fails" 1 "$tmp/cont_mid/reg.md" "$tmp/cont_mid/scripts" 'empty continuation for code: degraded: gh not found on PATH'
mkfix cont_last
edit "$tmp/cont_last/reg.md" 's/| inspect by hand |$/| |/'
expect "empty continuation in the LAST row (no trailing newline) fails" 1 "$tmp/cont_last/reg.md" "$tmp/cont_last/scripts" 'empty continuation for code: unclassifiable'
mkfix cont_single
printf '%s' '| `degraded: jq failed on` | degraded | research-sdd-init.sh | m | |' > "$tmp/cont_single/reg.md"
expect "empty continuation in a SINGLE-row registry fails" 1 "$tmp/cont_single/reg.md" "$tmp/cont_single/scripts" 'empty continuation for code: degraded: jq failed on'
mkfix cont_ph
edit "$tmp/cont_ph/reg.md" 's/| fix the path |$/| n\/a |/'
expect "placeholder continuation (n/a) fails" 1 "$tmp/cont_ph/reg.md" "$tmp/cont_ph/scripts" "placeholder continuation 'n/a'"

# stale row, emitter mismatch, duplicate, class, malformed, required input
mkfix stale
edit "$tmp/stale/reg.md" 's/^| `absent-input`/| `degraded: ghost code` | degraded | research-sdd-init.sh | g | go |\
| `absent-input`/'
expect "stale degraded row (never emitted) fails" 1 "$tmp/stale/reg.md" "$tmp/stale/scripts" 'stale row: .*ghost code'
mkfix emitter
edit "$tmp/emitter/reg.md" 's/| reconcile-issues.sh, stage-retro-issues.sh |/| reconcile-issues.sh |/'
expect "emitter missing from the row's emitters fails" 1 "$tmp/emitter/reg.md" "$tmp/emitter/scripts" 'emitter mismatch: stage-retro-issues.sh'
mkfix dup
edit "$tmp/dup/reg.md" 's/^| `absent-input`/| `absent-input` | input | many | d | go |\
| `absent-input`/'
expect "duplicate code fails" 1 "$tmp/dup/reg.md" "$tmp/dup/scripts" 'duplicate code: absent-input'
mkfix badclass
edit "$tmp/badclass/reg.md" 's/^| `absent-input`/| `weird` | mystery | many | w | go |\
| `absent-input`/'
expect "unknown class fails" 1 "$tmp/badclass/reg.md" "$tmp/badclass/scripts" "unknown class 'mystery'"
mkfix malformed
edit "$tmp/malformed/reg.md" 's/| m8 | confirm emptiness |/| confirm emptiness |/'
expect "malformed row (four cells) fails" 1 "$tmp/malformed/reg.md" "$tmp/malformed/scripts" 'malformed registry row'
mkfix reqinput
edit "$tmp/reqinput/reg.md" '/`empty-input`/d'
expect "missing required input-class row fails" 1 "$tmp/reqinput/reg.md" "$tmp/reqinput/scripts" 'required input-class row missing: empty-input'

# comment lines are not emit lines
mkfix commented
printf '\n%s' '# echo "degraded: ghost in a comment"' >> "$tmp/commented/scripts/reconcile-issues.sh"
expect "a commented-out emit line is ignored" 0 "$tmp/commented/reg.md" "$tmp/commented/scripts"

# stale emitter (reverse direction): a row lists a scanned script that never emits the code
mkfix stale_emit
edit "$tmp/stale_emit/reg.md" 's/| research-sdd-init.sh | m6 |/| research-sdd-init.sh, reconcile-issues.sh | m6 |/'
expect "a listed emitter that never emits the code fails (stale emitter)" 1 "$tmp/stale_emit/reg.md" "$tmp/stale_emit/scripts" "stale emitter: row lists reconcile-issues.sh but reconcile-issues.sh never emits 'degraded: jq failed on'"

# unclassifiable emit forms: continued echo, heredoc, assignment-then-echo (each must be reported, never silent)
mkfix unc_cont
printf '\n%s\n%s' 'echo \' '  "degraded: split across lines"' >> "$tmp/unc_cont/scripts/reconcile-issues.sh"
expect "echo continued onto the next line is reported unclassifiable" 1 "$tmp/unc_cont/reg.md" "$tmp/unc_cont/scripts" 'unclassifiable degraded: line in reconcile-issues.sh:[0-9]+'
mkfix unc_here
printf '\n%s\n%s\n%s' 'cat <<EOF' 'degraded: from a heredoc' 'EOF' >> "$tmp/unc_here/scripts/stage-retro-issues.sh"
expect "heredoc body carrying degraded: is reported unclassifiable" 1 "$tmp/unc_here/reg.md" "$tmp/unc_here/scripts" 'unclassifiable degraded: line in stage-retro-issues.sh:[0-9]+'
mkfix unc_assign
printf '\n%s' 'msg="degraded: via variable"' >> "$tmp/unc_assign/scripts/research-sdd-init.sh"
expect "assignment carrying degraded: is reported unclassifiable" 1 "$tmp/unc_assign/reg.md" "$tmp/unc_assign/scripts" 'unclassifiable degraded: line in research-sdd-init.sh:[0-9]+'
mkfix unc_trailing
printf '\n%s' 'x=1 # trailing note degraded: not an emit' >> "$tmp/unc_trailing/scripts/research-sdd-init.sh"
expect "a trailing-comment mention is reported (only whole-line comments are excluded)" 1 "$tmp/unc_trailing/reg.md" "$tmp/unc_trailing/scripts" 'unclassifiable degraded: line in research-sdd-init.sh:[0-9]+'
mkfix unc_hash
printf '\n%s' 'msg="see #2 degraded: via quoted hash"' >> "$tmp/unc_hash/scripts/research-sdd-init.sh"
expect "a quoted ' #' before degraded: is reported unclassifiable (not read as a comment)" 1 "$tmp/unc_hash/reg.md" "$tmp/unc_hash/scripts" 'unclassifiable degraded: line in research-sdd-init.sh:[0-9]+'

# --- 3b. input-class scan fixtures ------------------------------------------------------------------
# mkifix NAME — a good registry (reg.md) + a two-file toolbelt (tb/a.sh, tb/lib/b.sh) covering every recognised
# form: echo, printf with a \t escape, a jq state literal, a parenthesised marker, plus the non-emit classes
# (counter, trailing comment, case matcher). The last line of each script has no trailing newline.
mkifix() {
  local d="$tmp/$1"
  mkdir -p "$d/tb/lib"
  cat > "$d/tb/a.sh" <<'FIXEOF'
# comment: echo "absent-input: never emitted from a comment"
echo "absent-input: $x not found" >&2
printf 'subject: empty-input (0 units)\n'
unclassifiable=0; n=$((unclassifiable + 1))   # trailing note about absent-input
[ "$unclassifiable" -gt 0 ] || :
x="${unclassifiable}"
grep -q 'no-match' "$f"
case "$o" in *unclassifiable:*) : ;; esac
jq -e '.state == "no-match"' "$f" >/dev/null
[ "$s" = "unclassifiable" ] || :
*no-match:*) : ;;
/^INFO: no-match/ { next }
st=empty-input
jq '.state = "empty-input"' "$f"
echo "path: $p"
FIXEOF
  printf '%s' 'echo "x" # no trailing newline' >> "$d/tb/a.sh"
  printf '%s\n' "jq -n '(if \$a then \"ok\" else \"no-match\" end)'" \
    'emit C1 n/a "no rows (empty-input)"' > "$d/tb/lib/b.sh"
  printf '%s' "printf '%d\\tunclassifiable\\n' \"\$n\"" >> "$d/tb/lib/b.sh"
  : > "$d/waivers.txt"
  {
    printf '%s\n' '# fixture registry' '' \
      '| code | class | emitters | meaning | continuation |' \
      '|---|---|---|---|---|' \
      '| `degraded: x` | degraded | a.sh | m0 | go |' \
      '| `absent-input` | input | a.sh | m1 | fix the path |' \
      '| `empty-input` | input | a.sh, lib/b.sh | m2 | confirm emptiness |' \
      '| `unclassifiable` | input | lib/b.sh | m3 | inspect by hand |'
    printf '%s' '| `no-match` | input | lib/b.sh | m4 | widen the filter |'
  } > "$d/reg.md"
}

# expect_ic LABEL WANT_RC FIXTURE [GREP_RE] — run the input-class scan with the fixture's own waiver file.
expect_ic() {
  local label="$1" want="$2" fx="$3" re="${4:-}" out rc
  out="$(RC_IC_WAIVERS_FILE="$tmp/$fx/waivers.txt" ic_check "$tmp/$fx/reg.md" "$tmp/$fx/tb")"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    no "$label (rc=$rc want=$want)"; printf '%s\n' "$out" | sed 's/^/        /'; return 1
  fi
  if [ -n "$re" ] && ! grep -Eq -- "$re" <<<"$out"; then
    no "$label (rc ok, output lacks /$re/)"; printf '%s\n' "$out" | sed 's/^/        /'; return 1
  fi
  ok "$label"
}

mkifix i_good
expect_ic "input scan: good fixture is clean (all forms recognised, non-emit classes skipped)" 0 i_good

mkifix i_unlisted
edit "$tmp/i_unlisted/reg.md" '/`no-match`/d'
expect_ic "input scan: emitted code with no registry row fails (unlisted)" 1 i_unlisted 'unlisted input-class code emitted: no-match'

mkifix i_staleemit
edit "$tmp/i_staleemit/reg.md" 's/| lib\/b.sh | m4 |/| lib\/b.sh, a.sh | m4 |/'
expect_ic "input scan: a listed emitter that never emits the code fails (stale emitter)" 1 i_staleemit "stale emitter: row lists a.sh but a.sh never emits 'no-match'"

mkifix i_emitter
edit "$tmp/i_emitter/reg.md" 's/| a.sh | m1 |/| lib\/b.sh | m1 |/'
expect_ic "input scan: an emitter missing from the row fails (emitter mismatch)" 1 i_emitter "emitter mismatch: a.sh emits 'absent-input'"

# single-defect twins of the two fixtures above (the originals carry several findings at once, which a
# mutation of one guard cannot isolate)
mkifix i_emitter1
edit "$tmp/i_emitter1/reg.md" 's/| a.sh, lib\/b.sh | m2 |/| lib\/b.sh | m2 |/'
expect_ic "input scan: exactly one emitter missing from a row fails (emitter mismatch, isolated)" 1 i_emitter1 "emitter mismatch: a.sh emits 'empty-input'"
mkifix i_stalerow1
printf '%s\n' "jq -n '(if \$a then \"ok\" else \"x\" end)'" 'emit C1 n/a "no rows (empty-input)"' > "$tmp/i_stalerow1/tb/lib/b.sh"
printf '%s' "printf '%d\\tunclassifiable\\n' \"\$n\"" >> "$tmp/i_stalerow1/tb/lib/b.sh"
expect_ic "input scan: a row nothing emits fails (stale row, isolated)" 1 i_stalerow1 'stale row: input code never emitted by a scanned script: no-match'

mkifix i_notscan
printf '\n%s' '| `weird-input` | input | a.sh | w | go |' >> "$tmp/i_notscan/reg.md"
expect_ic "input scan: an input row outside the scanner vocabulary fails (not scannable)" 1 i_notscan 'not scannable.*weird-input'
mkifix i_norow_emit
printf '%s\n' 'echo "ok"' > "$tmp/i_norow_emit/tb/lib/b.sh"
expect_ic "input scan: a registry row nothing emits fails (stale row)" 1 i_norow_emit 'stale row: input code never emitted by a scanned script: no-match'

mkifix i_uncl
printf '\n%s' 'msg="the absent-input case"' >> "$tmp/i_uncl/tb/a.sh"
expect_ic "input scan: an occurrence in no recognised form is reported, never silent" 1 i_uncl 'unclassifiable input-state occurrence in a.sh:[0-9]+ \(absent-input\)'

mkifix i_waived
printf '\n%s' 'msg="the absent-input case"' >> "$tmp/i_waived/tb/a.sh"
printf '%s\n' 'a.sh|the absent-input case|1|fixture prose' > "$tmp/i_waived/waivers.txt"
expect_ic "input scan: a waiver with the right count silences its prose occurrence" 0 i_waived
mkifix i_stalewaiver
printf '%s\n' 'a.sh|matches nothing at all|1|fixture' > "$tmp/i_stalewaiver/waivers.txt"
expect_ic "input scan: a waiver that matches nothing fails (stale waiver)" 1 i_stalewaiver 'stale waiver'
# a second, genuine emission that happens to contain the waived substring must not be swallowed
mkifix i_waivercount
printf '\n%s\n%s' 'msg="the absent-input case"' 'echo "unclassifiable: the absent-input case"' >> "$tmp/i_waivercount/tb/a.sh"
printf '%s\n' 'a.sh|the absent-input case|1|fixture prose' > "$tmp/i_waivercount/waivers.txt"
expect_ic "input scan: a waiver matching more occurrences than its count fails (cannot swallow a new emission)" 1 i_waivercount 'waiver matched [0-9]+ occurrence\(s\), expected 1'

# hazards: lines that LOOK like consumers/comments/counters but are emissions. a.sh is not a listed emitter of
# `unclassifiable` or `no-match`, so each line must surface as an emitter mismatch.
# haz NAME LINE TOKEN
haz() {
  mkifix "$1"
  printf '\n%s' "$2" >> "$tmp/$1/tb/a.sh"
  expect_ic "input scan: emission not mistaken for a non-emit — $2" 1 "$1" "emitter mismatch: a.sh emits '$3'"
}
haz h_eqmsg   'echo "state=no-match"' no-match
haz h_grepmsg "printf 'no-match: grep found 0 rows\\n'" no-match
haz h_casemsg 'echo "unclassifiable: in this case x"' unclassifiable
haz h_jqassign "jq '.state = \"no-match\"' \"\$f\"" no-match
haz h_shassign 'st=no-match' no-match
haz h_slash "/usr/bin/printf 'no-match: x\\n'" no-match
haz h_star '*) echo "no-match: x" ;;' no-match
haz h_sqhash "echo 'item #3 unclassifiable'" unclassifiable
haz h_dqhash 'echo "item #3 unclassifiable"' unclassifiable
# a grep/case earlier on the line does not make a later command's token a consumer
haz h_seg_or 'grep -q pat "$f" || echo "no-match: $f"' no-match
haz h_seg_then 'if grep -q x "$f"; then echo "no-match"; fi' no-match
haz h_seg_case 'case "$x" in "") echo "unclassifiable: $p" ;; esac' unclassifiable

mkifix i_counter
printf '\n%s' 'echo "n=$no_match_count unclassifiable=$n unclassifiable-items: 0 unclassifiable-row: 1"' >> "$tmp/i_counter/tb/a.sh"
expect_ic "input scan: counters and hyphen-extended compounds are not occurrences" 0 i_counter

# list edges: a new emitter on the FIRST line of the first file and on the LAST line (no newline) of the last file
mkifix i_first
{ printf '%s\n' 'echo "unclassifiable: first line"'; cat "$tmp/i_first/tb/a.sh"; } > "$tmp/i_first/s" && mv "$tmp/i_first/s" "$tmp/i_first/tb/a.sh"
expect_ic "input scan: an emit on the FIRST line of a file is seen" 1 i_first "emitter mismatch: a.sh emits 'unclassifiable'"
mkifix i_last
printf '\n%s' 'echo "no-match: last line"' >> "$tmp/i_last/tb/lib/b.sh"
expect_ic "input scan: an emit on the LAST line (no trailing newline) is still scanned" 0 i_last

mkifix i_zero
rm -f "$tmp/i_zero/tb/a.sh" "$tmp/i_zero/tb/lib/b.sh"
expect_ic "input scan: zero shell files -> DEGRADED rc 2" 2 i_zero 'DEGRADED: no \*\.sh files'
mkifix i_zeroocc
printf '%s\n' 'echo "nothing typed here"' > "$tmp/i_zeroocc/tb/a.sh"; printf '%s\n' 'true' > "$tmp/i_zeroocc/tb/lib/b.sh"
expect_ic "input scan: files but zero occurrences -> DEGRADED rc 2" 2 i_zeroocc 'DEGRADED: found zero input-state occurrences'
mkifix i_nodir
rm -rf "$tmp/i_nodir/tb"
expect_ic "input scan: absent scan directory -> DEGRADED rc 2" 2 i_nodir 'DEGRADED: scan directory absent'

# --- 4. could-not-look is typed DEGRADED (rc 2), never clean ------------------------------------
mkfix d_noreg
expect "registry absent -> DEGRADED rc 2" 2 "$tmp/d_noreg/missing.md" "$tmp/d_noreg/scripts" 'DEGRADED: registry absent'
mkfix d_noscript
rm -f "$tmp/d_noscript/scripts/stage-retro-issues.sh"
expect "scanned script absent -> DEGRADED rc 2" 2 "$tmp/d_noscript/reg.md" "$tmp/d_noscript/scripts" 'DEGRADED: scanned script absent'
mkfix d_zero
printf '%s\n' '# degraded: only in a comment' 'echo "no typed state here"' > "$tmp/d_zero/scripts/reconcile-issues.sh"
expect "zero extracted emit lines -> DEGRADED rc 2" 2 "$tmp/d_zero/reg.md" "$tmp/d_zero/scripts" 'DEGRADED: extracted zero degraded emit lines from reconcile-issues.sh'
mkfix d_norows
printf '%s\n' '# registry with prose only' '| code | class |' > "$tmp/d_norows/reg.md"
expect "registry with zero parsable rows -> DEGRADED rc 2" 2 "$tmp/d_norows/reg.md" "$tmp/d_norows/scripts" 'DEGRADED: registry .* zero parsable rows'
mkfix d_empty
: > "$tmp/d_empty/scripts/research-sdd-init.sh"
expect "empty scanned script -> DEGRADED rc 2" 2 "$tmp/d_empty/reg.md" "$tmp/d_empty/scripts" 'extracted zero'

# --- 5. teeth: mutate the CHECKER (a copy of this suite) and require each defect to go unnoticed ----
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2
  mkdir -p "$tmp/mut"
  CRASH="$(mutant_crash_re bash py)" || exit 2
  # tooth NAME FIXTURE GOOD_RC BAD_RC SED_EXPR — the checker (--check-only) on FIXTURE must exit GOOD_RC
  # as written and BAD_RC once SED_EXPR has disabled the guarded line. A refused build counts once.
  tooth() {
    local name="$1" fx="$2" good="$3" bad="$4" expr="$5" m="$tmp/mut/$1.sh" line
    local mode="${TOOTH_MODE:---check-only}" sub="${TOOTH_SUB:-scripts}"
    mutant_chain_or_count fail "$name" "$SELF" "$m" "$expr" || return 1
    if line="$(mutant_tooth "teeth $name" "$good" "$bad" "$m" --orig "$SELF" --bad-lacks "$CRASH" \
        -- bash @SUT@ "$mode" "$tmp/$fx/reg.md" "$tmp/$fx/$sub")"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
    fi
    printf '%s\n' "$line"
  }
  tooth unlisted     unl_first  1 0 '/# TOOTH-UNLISTED/s/finding /: /'
  tooth emptycont    cont_first 1 0 '/# TOOTH-EMPTYCONT/s/finding /: /'
  tooth placeholder  cont_ph    1 0 '/# TOOTH-PLACEHOLDER/s/finding /: /'
  tooth stale        stale      1 0 '/# TOOTH-STALE/s/finding /: /'
  tooth emitter      emitter    1 0 '/# TOOTH-EMITTER/s/finding /: /'
  tooth duplicate    dup        1 0 '/# TOOTH-DUP/s/finding /: /'
  tooth badclass     badclass   1 0 '/# TOOTH-CLASS/s/finding /: /'
  tooth reqinput     reqinput   1 0 '/# TOOTH-REQINPUT/s/finding /: /'
  tooth staleemit    stale_emit 1 0 '/# TOOTH-STALEEMIT/s/finding /: /'
  tooth unclass      unc_cont   1 0 '/# TOOTH-UNCLASS/s/finding /: /'
  tooth unclass-hash unc_hash   1 0 '/^  p = index(\$0, "degraded: "); if (!p) next/a\
  c = index($0, " #"); if (c \&\& c < p) next'
  tooth mb-unlisted   unl_mb     1 0 '/# TOOTH-UNLISTED/s/finding /: /'
  tooth mb-stale      stale_mb   1 0 '/# TOOTH-STALE/s/finding /: /'
  tooth mb-scanned    mb_scanned    1 0 '/^SCRIPTS=(/s/ migrate-backlogs.sh)/)/'
  tooth mb-emitter    mb_emitter 1 0 '/# TOOTH-EMITTER/s/finding /: /'
  tooth zeroextract  d_zero     2 1 '/# TOOTH-ZEROEXTRACT/s/\[ -z "\$toks" \]/false/'
  tooth zerorows     d_norows   2 1 '/# TOOTH-ZEROROWS/s/\[ -z "\$rows" \]/false/'
  tooth comment-skip commented  0 1 '/# TOOTH-COMMENT/d'
  tooth var-subst    good       0 1 '/# TOOTH-VARSUB/d'
  tooth cmdsub       good_sub   0 1 '/# TOOTH-CMDSUB/d'
  tooth specialsub   good_sub   0 1 '/# TOOTH-SPECIALSUB/d'
  tooth emdash-cut   good       0 1 '/# TOOTH-EMDASH/d'
  # input-class scan teeth: the same helper, pointed at --check-input with the fixture's own (empty) waiver file
  ictooth() { RC_IC_WAIVERS_FILE="$tmp/$2/waivers.txt" TOOTH_MODE=--check-input TOOTH_SUB=tb tooth "$@"; }
  ictooth ic-unlisted    i_unlisted    1 0 '/# TOOTH-IC-UNLISTED/s/finding /: /'
  ictooth ic-staleemit   i_staleemit   1 0 '/# TOOTH-IC-STALEEMIT/s/finding /: /'
  ictooth ic-emitter     i_emitter1    1 0 '/# TOOTH-IC-EMITTER/s/finding /: /'
  ictooth ic-stalerow    i_stalerow1   1 0 '/# TOOTH-IC-STALEROW/s/finding /: /'
  ictooth ic-unclass     i_uncl        1 0 '/# TOOTH-IC-UNCLASS/s/finding /: /'
  ictooth ic-stalewaiver i_stalewaiver 1 0 '/# TOOTH-IC-STALEWAIVER/s/finding /: /'
  # ic-zerofiles mutates TWO guards on purpose: with only the zero-files guard off, the scan still reaches the
  # zero-occurrences guard and exits 2 for the same input, so the mutant would be indistinguishable. Disabling
  # both lets the empty scan fall through to the row checks (stale rows), which is the observable difference.
  ictooth ic-zerofiles  i_zero        2 1 '/# TOOTH-IC-ZEROFILES/s/-eq 0/-eq -1/;/# TOOTH-IC-ZEROOCC/s/\[ -z "\$all" \]/false/'
  ictooth ic-zeroocc     i_zeroocc     2 1 '/# TOOTH-IC-ZEROOCC/s/\[ -z "\$all" \]/false/'
  ictooth ic-waivercount i_waivercount 1 0 '/# TOOTH-IC-WAIVERCOUNT/s/finding /: /'
  # one tooth per counter alternative: each fixture line below is caught by exactly that alternative
  ictooth ic-ctr-eq      i_good        0 1 '/# TOOTH-IC-CTR-EQ/s/post == "="/post == "ZZ"/'
  ictooth ic-ctr-dollar  i_good        0 1 '/# TOOTH-IC-CTR-DOLLAR/s/pre == "\$"/pre == "ZZ"/'
  ictooth ic-ctr-brace   i_good        0 1 '/# TOOTH-IC-CTR-BRACE/s/pre == "{"/pre == "ZZ"/'
  ictooth ic-ctr-arith   i_good        0 1 '/# TOOTH-IC-CTR-ARITH/s/prefix ~ \//prefix ~ \/ZZ/'
  ictooth ic-comment     i_good        0 1 '/# TOOTH-IC-COMMENT/s/== "C"/== "ZZ"/'
  ictooth ic-hash        i_good        0 1 '/# TOOTH-IC-HASH/s/ch == "#"/ch == "ZZ"/'
  # one tooth per consumer alternative (positive: the line must stay a non-emit)
  ictooth ic-cons-grep   i_good        0 1 '/# TOOTH-IC-CONS-GREP/s/sg ~ re_grep/mp ~ "ZZ"/'
  ictooth ic-cons-case   i_good        0 1 '/# TOOTH-IC-CONS-CASE/s/sg ~ re_case/mp ~ "ZZ"/'
  ictooth ic-cons-eq     i_good        0 1 '/# TOOTH-IC-CONS-EQ/s/prefix ~ q_eq/prefix ~ "ZZ"/'
  ictooth ic-cons-brk    i_good        0 1 '/# TOOTH-IC-CONS-BRK/s/prefix ~ q_brk/prefix ~ "ZZ"/'
  ictooth ic-cons-star   i_good        0 1 '/# TOOTH-IC-CONS-STAR/s/prefix ~ \/^\[\[:space:\]\]\*\\\*\//prefix ~ \/ZZ\//'
  ictooth ic-cons-slash  i_good        0 1 '/# TOOTH-IC-CONS-SLASH/s/prefix ~ \/^\[\[:space:\]\]\*\\\/\//prefix ~ \/ZZ\//'
  ictooth ic-assign      i_good        0 1 '/# TOOTH-IC-ASSIGN/s/prefix ~ q_assign/prefix ~ "ZZ"/'
  # negative: the over-broad consumer/comment rules this scanner used to have, reintroduced one at a time,
  # must make the matching hazard fixture go clean (rc 1 -> 0), proving the hazard fixtures bite
  ictooth ic-haz-grep    h_grepmsg     1 0 '/# TOOTH-IC-CONS-GREP/s|sg ~ re_grep|scan ~ /grep[[:space:]]/|'
  ictooth ic-haz-case    h_casemsg     1 0 '/# TOOTH-IC-CONS-CASE/s|sg ~ re_case|scan ~ /case[[:space:]]/|'
  ictooth ic-haz-eq      h_eqmsg       1 0 '/# TOOTH-IC-CONS-EQ/s|prefix ~ q_eq|prefix ~ q_assign|'
  ictooth ic-haz-shassign h_shassign   1 0 '/# TOOTH-IC-CONS-EQ/s|prefix ~ q_eq|prefix ~ q_assign|'
  ictooth ic-haz-jqassign h_jqassign   1 0 '/# TOOTH-IC-CONS-BRK/s/ && mp ~ re_br/ \&\& 1/'
  ictooth ic-haz-slash   h_slash       1 0 '/# TOOTH-IC-CONS-SLASH/s/(\\{|\$)/(.|$)/'
  ictooth ic-haz-star    h_star        1 0 '/# TOOTH-IC-CONS-STAR/s/prefix !~ \/\\)\//1/'
  ictooth ic-haz-sqhash  h_sqhash      1 0 '/# TOOTH-IC-SQ/s/st = "s"/st = ""/'
  ictooth ic-haz-dqhash  h_dqhash      1 0 '/# TOOTH-IC-DQ/s/st = "d"/st = ""/'
  ictooth ic-haz-seg-or   h_seg_or     1 0 '/# TOOTH-IC-SEG/s/lastseg(mp)/mp/'
  ictooth ic-haz-seg-then h_seg_then   1 0 '/# TOOTH-IC-SEG/s/lastseg(mp)/mp/'
  ictooth ic-haz-seg-case h_seg_case   1 0 '/# TOOTH-IC-SEG/s/lastseg(mp)/mp/'
  ictooth ic-jq          i_good        0 1 '/# TOOTH-IC-JQ/s/(then|else)/(thenX|elseX)/'
  ictooth ic-escape      i_good        0 1 '/# TOOTH-IC-ESCAPE/s/\[tn\]/[zz]/'
  ictooth ic-marker     i_good        0 1 '/# TOOTH-IC-MARKER/s/pre == "("/pre == "Z"/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

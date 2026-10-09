#!/usr/bin/env bash
# lib-resolution-lint.test.sh — keeps $0-based directory resolution out of every toolbelt/install script (kit issue #1675).
#
# The defect: `dirname "$0"` is `.` whenever bash finds the script in PATH or the cwd (`bash name.sh`: $0 has no
# slash), so `lib/*.sh` (or a sibling script) is taken from the CALLER'S cwd — a planted lib/ in an untrusted
# target/corpus executes. Through a symlink in another directory lib/ is not found at all. The one shared idiom
# (documented in research-sdd/toolbelt/tool-registry.md, "Script self-directory") resolves from ${BASH_SOURCE[0]},
# follows symlinks and `cd -P`s; this suite rejects any $0-derived directory in the corpus below.
#
# Modes
#   (default)                  scanner fixtures + mutation-free checks + the REAL tree + the behavioural planted-lib
#                              fixture (this suite is the gate); add --prove-teeth for the mutation controls
#   --scan FILE...             lint exactly FILE... and print the report
#   --scan-tree RESEARCH_DIR   lint the declared corpus under RESEARCH_DIR and print the report
#   Exit (--scan, --scan-tree): 0 no violations · 1 violations · 2 operational failure (absent corpus, zero files,
#   unreadable file, no code lines seen) — a zero is never a silent pass (CLAUDE.md §7).
#
# Corpus (declared): research-sdd/toolbelt/*.sh · research-sdd/toolbelt/lib/*.sh · research-sdd/install/*.sh.
# EXCLUDED (declared, reported by --scan-tree, never gated):
#   - toolbelt/tests/ and install/tests/ — test suites are launched by path from run-all.sh / a developer and
#     only locate their own fixtures; 190+ of them use `dirname "$0"` and none is a PATH-resolved entry point.
#   - templates/*.sh — hook templates COPIED into a target repo and run by git / Claude Code by path, not kit entry points;
#     two of them DO derive a directory from `dirname "$0"` (hook-prepush-vendor-leak.sh runs a sibling scanner through it,
#     hook-sessionstart.sh climbs from it). Known residual, not covered here; fixing a template is a separate work unit.
#     --scan-tree prints how many templates exist and which still carry a $0-derived directory.
#
# Exemption is EXPLICIT: a trailing shell comment `# lib-resolution-ok: <reason of >= 3 words>` on the logical line
# (the last physical line of a backslash continuation) marks a DELIBERATE mention (pattern literals in a scanner).
# The `#` must start a comment OUTSIDE quotes; a marker inside a string, without a reason or with fewer than 3 words
# does not exempt. Each exempt site is printed (`exempt FILE:LINE:FORM: text`). No path-based blanket exemption exists.
#
# Exit (default mode): 0 all held · 1 regression · 2 harness error

set -uo pipefail
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
HERE="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
SELF="$HERE/lib-resolution-lint.test.sh"
# shellcheck disable=SC2034 # read by lib/mutant.sh (mutant_tooth) as the original each mutant is compared with
SUT="$SELF"
FIX="$HERE/fixtures/lib-resolution"
TB="$(cd -P -- "$HERE/.." && pwd -P)"

lrl_forms() {
  cat <<'EOF'
forms recognised (in code lines only: comment-only lines skipped, backslash continuations joined first; the $0 may be
followed by a quote, space, ; ) ` | & or the end of the line, so `dirname $0` and $(dirname $0|...) are seen):
  F1  dirname [--] "$0" | $0 | "${0}" | ${0}                    (also inside $(cd "$(dirname "$0")/.." ...))
  F2  ${0%/*} | ${0%%/*} | any ${0%...} suffix strip | any ${0/...} pattern substitution (e.g. ${0/%\/*})
  F3  readlink | realpath with $0 / ${0} among its arguments
  F4  alias: V="$0" | V=$0 | V="${0}" (also after local/export/readonly/declare, with or without flags such as -r or --), then dirname [--] "$V" | ${V%...} | readlink/realpath "$V" later in the file
forms NOT recognised (known limits): ${BASH_SOURCE[0]:-$0} defaults, $0 smuggled through eval/xargs/sh -c, an alias
  passed through a function argument, `$0` read by `sed ... "$0"` (display only), usage/message uses of $0 and
  ${0##*/} / basename "$0" (display only), awk's $0
exempt: a trailing `# lib-resolution-ok: <reason of >= 3 words>` comment (the # outside quotes) on the logical line
comments: only a `#` outside '..' / ".." / $'..' quotes at the start of a word starts one (nested quotes inside $(...) only toggle)
  KNOWN LIMIT: quote state is per logical line, so a `#` on the continuation line of a multi-line string ("a<newline>  # x")
  reads as a comment and hides a following dirname "$0" on that line (pinned by a fixture in this suite)
excluded corpus (declared, not gated): toolbelt/tests/*.sh, install/tests/*.sh, templates/*.sh (see the header)
EOF
}

# Scanner. Output per violation: FILE:LINE:FORM: text ; summary lines at END.
LRL_AWK="$(cat <<'AWKEOF'
# First `#` that starts a shell comment: outside '..' / ".." quotes, not backslash-escaped, at the start of a word.
# Returns its 1-based index, or 0 when the line has no comment. Nested quotes inside $(...) only toggle the state.
function comment_start(s,   i, n, c, q, p) {
  n = length(s); q = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == "$'") { if (c == "\\") i++; else if (c == "'") q = ""; continue }   # ANSI-C $'..' honours \'
    if (q == "'") { if (c == "'") q = ""; continue }
    if (c == "\\") { i++; continue }
    if (q == "\"") { if (c == "\"") q = ""; continue }
    if (c == "$" && substr(s, i + 1, 1) == "'") { q = "$'"; i++; continue }   # SENTINEL-LRL-ANSIC
    if (c == "'" || c == "\"") { q = c; continue }   # SENTINEL-LRL-QUOTE
    if (c == "#") { p = (i > 1) ? substr(s, i - 1, 1) : " "; if (p ~ /[ \t;&|()]/) return i }
  }
  return 0
}
function flush_logical(   code, line, v, k, hit, raw, fname, cs, cmt, rest, nw, w) {
  if (logical == "") return
  raw = logical; line = lstart; fname = lfile; logical = ""
  ncode++
  code = raw
  sub(/^[ \t]+/, "", code)
  cs = comment_start(code)
  cmt = ""
  if (cs == 1) { ncode--; return }          # comment-only line
  if (cs > 1) { cmt = substr(code, cs); code = substr(code, 1, cs - 1) }   # SENTINEL-LRL-COMMENT
  hit = ""
  if (code ~ /dirname[ \t]+(--[ \t]+)?["']?\$\{?0\}?(["' \t;)`|&]|$)/) hit = "F1"   # SENTINEL-LRL-F1
  else if (code ~ /\$\{0[%\/]/) hit = "F2"   # SENTINEL-LRL-F2
  else if (code ~ /(readlink|realpath)[^|;&)]*\$\{?0\}?(["' \t;)`|&]|$)/) hit = "F3"   # SENTINEL-LRL-F3
  else {
    for (k in alias) {
      if (code ~ ("dirname[ \t]+(--[ \t]+)?[\"']?\\$\\{?" k "\\}?([\"' \t;)`|&]|$)") \
          || code ~ ("\\$\\{" k "%") \
          || code ~ ("(readlink|realpath)[^|;&)]*\\$\\{?" k "\\}?([\"' \t;)`|&]|$)")) { hit = "F4"; break }
    }
  }
  # Exemption: a real trailing comment `# lib-resolution-ok: <reason of >= 3 words>`; it exempts only a line that would be a violation.
  if (cmt ~ /^#[ \t]*lib-resolution-ok:/) {
    rest = cmt; sub(/^#[ \t]*lib-resolution-ok:[ \t]*/, "", rest); sub(/[ \t]+$/, "", rest)
    nw = (rest == "") ? 0 : split(rest, w, /[ \t]+/)
    if (nw >= 3 && hit != "") { nexempt++; printf "exempt %s:%d:%s: %s\n", fname, line, hit, substr(raw, 1, 160); return }   # SENTINEL-LRL-MARKER
  }
  if (hit != "") { nviol++; printf "%s:%d:%s: %s\n", fname, line, hit, substr(raw, 1, 160); fv[hit]++ }
  # alias assignment AFTER the use check so `V="$0"; dirname "$V"` on one line is still seen next line
  if (match(code, /(^|[ \t;{(])(local[ \t]+|export[ \t]+|readonly[ \t]+|declare[ \t]+)?[A-Za-z_][A-Za-z_0-9]*=["']?\$\{?0\}?["']?([ \t;)]|$)/)) {    v = substr(code, RSTART, RLENGTH)
    sub(/^[ \t;{(]+/, "", v); sub(/^(local|export|readonly|declare)[ \t]+/, "", v); sub(/=.*$/, "", v)
    alias[v] = 1   # SENTINEL-LRL-ALIAS
  }
}
FNR == 1 { flush_logical(); delete alias; nfiles++ }
{
  if (cont) { sub(/^[ \t]+/, "", $0) } else { lstart = FNR; lfile = FILENAME }
  if ($0 ~ /\\$/) { s = $0; sub(/\\$/, " ", s); logical = logical s; cont = 1; next }   # SENTINEL-LRL-CONT
  logical = logical $0; cont = 0
  flush_logical()
}
END {
  flush_logical()
  printf "files scanned: %d\ncode lines: %d\n", nfiles + 0, ncode + 0
  printf "violations: %d\nexempt sites: %d\n", nviol + 0, nexempt + 0
  printf "by form: F1=%d F2=%d F3=%d F4=%d\n", fv["F1"], fv["F2"], fv["F3"], fv["F4"]
}
AWKEOF
)"

lrl_scan() {   # lrl_scan FILE... -> report on stdout, rc 0/1/2
  local f out rc
  [ "$#" -gt 0 ] || { echo "ERROR: no files to scan" >&2; return 2; }  # SENTINEL-LRL-ZERO-FILES
  for f in "$@"; do [ -r "$f" ] || { echo "ERROR: unreadable file: $f" >&2; return 2; }; done
  out="$(awk "$LRL_AWK" "$@")" || { echo "ERROR: awk failed" >&2; return 2; }
  printf '%s\n' "$out"
  grep -qE '^code lines: [1-9]' <<<"$out" || { echo "ERROR: no code lines seen in the scanned files" >&2; return 2; }  # SENTINEL-LRL-CODE-LINES
  grep -qE '^violations: 0$' <<<"$out" && rc=0 || rc=1
  return "$rc"
}

lrl_templates() {   # lrl_templates RESEARCH_DIR -> one report line about the declared-excluded templates/*.sh
  local t n=0 tf=() out names
  [ -d "$1/templates" ] || { echo "excluded templates/*.sh: directory absent (nothing to report)"; return 0; }
  for t in "$1"/templates/*.sh; do [ -e "$t" ] || continue; tf+=("$t"); n=$((n + 1)); done
  [ "$n" -gt 0 ] || { echo "excluded templates/*.sh: 0 files (nothing to report)"; return 0; }
  out="$(awk "$LRL_AWK" "${tf[@]}")" || { echo "excluded templates/*.sh: $n files, scan FAILED (not gated)"; return 0; }
  names="$(grep -E '^[^ ]+:[0-9]+:F[0-9]: ' <<<"$out" | sed -E 's#^(.*/)?([^/:]+):[0-9]+:F[0-9]: .*#\2#' | sort -u | tr '\n' ' ')"
  printf 'excluded templates/*.sh: %d files, %s with a $0-derived directory (declared residual, not gated): %s\n' \
    "$n" "$(grep -cE '^[^ ]+:[0-9]+:F[0-9]: ' <<<"$out")" "${names:-none}"
}

lrl_tree() {   # lrl_tree RESEARCH_DIR -> report with corpus counts
  local root="$1" d n files=() c
  [ -d "$root/toolbelt" ] || { echo "ERROR: absent corpus: $root/toolbelt" >&2; return 2; }
  for d in toolbelt toolbelt/lib install; do
    [ -d "$root/$d" ] || { echo "ERROR: absent corpus dir: $root/$d" >&2; return 2; }
    c=0
    for n in "$root/$d"/*.sh; do [ -e "$n" ] || continue; files+=("$n"); c=$((c + 1)); done
    printf 'corpus %s/*.sh: %d\n' "$d" "$c"
    [ "$c" -gt 0 ] || { echo "ERROR: empty corpus: $root/$d has no *.sh files" >&2; return 2; }
  done
  lrl_templates "$root"
  lrl_forms
  lrl_scan "${files[@]}"
}

# Completeness: every corpus script that carries the `_RSDD_SELF` idiom (grep -l '^_RSDD_SELF=') must be either listed in the
# behavioural fixture or declared in the exclusions file with a reason; a stale entry (not in the derived set) fails too.
lrl_complete() {   # lrl_complete RESEARCH_DIR LIST EXCL -> report, rc 0 complete / 1 gap / 2 operational failure
  local root="$1" list="$2" excl="$3" f rel rc l path reason nw bad=0 _ws
  local -a expa=() lsta=() exca=()
  [ -d "$root/toolbelt" ] || { echo "ERROR: absent corpus: $root/toolbelt" >&2; return 2; }
  [ -s "$list" ] || { echo "ERROR: planted-lib list absent or empty: $list" >&2; return 2; }
  [ -r "$excl" ] || { echo "ERROR: exclusions file unreadable: $excl" >&2; return 2; }
  for f in "$root"/toolbelt/*.sh "$root"/toolbelt/lib/*.sh "$root"/install/*.sh; do
    [ -e "$f" ] || continue
    grep -q '^_RSDD_SELF=' "$f"; rc=$?
    case "$rc" in 0) ;; 1) continue ;; *) echo "ERROR: grep failed on $f" >&2; return 2 ;; esac
    rel="${f#"$root"/}"; rel="${rel#toolbelt/}"; expa+=("$rel")
  done
  [ "${#expa[@]}" -gt 0 ] || { echo "ERROR: no _RSDD_SELF script found under $root (the derived set is empty)" >&2; return 2; }   # SENTINEL-LRL-ZEROEXP
  while IFS= read -r l; do case "$l" in ''|'#'*) continue ;; esac; lsta+=("$l"); done < "$list"
  while IFS= read -r l; do
    case "$l" in ''|'#'*) continue ;; esac
    path="${l%% | *}"; reason="${l#* | }"; [ "$path" != "$l" ] || reason=""
    read -ra _ws <<<"$reason"; nw="${#_ws[@]}"
    if [ "$nw" -lt 3 ]; then echo "invalid exclusion (reason needs >= 3 words): $l"; bad=$((bad + 1)); fi # SENTINEL-LRL-REASON
    exca+=("$path")
  done < "$excl"
  local missing stale both
  missing="$(comm -23 <(printf '%s\n' "${expa[@]}" | sort -u) <(printf '%s\n' "${lsta[@]:-}" "${exca[@]:-}" | sort -u))"   # SENTINEL-LRL-MISSING
  stale="$(comm -13 <(printf '%s\n' "${expa[@]}" | sort -u) <(printf '%s\n' "${lsta[@]:-}" "${exca[@]:-}" | sort -u) | grep -v '^$')"   # SENTINEL-LRL-STALE
  both="$(comm -12 <(printf '%s\n' "${lsta[@]:-}" | sort -u) <(printf '%s\n' "${exca[@]:-}" | sort -u) | grep -v '^$')"   # SENTINEL-LRL-BOTH
  printf 'completeness: derived %d (grep -l ^_RSDD_SELF=) · listed %d · excluded %d · missing %d · stale %d · listed-and-excluded %d · invalid %d\n' \
    "${#expa[@]}" "${#lsta[@]}" "${#exca[@]}" "$(grep -c . <<<"$missing")" "$(grep -c . <<<"$stale")" "$(grep -c . <<<"$both")" "$bad"
  [ -z "$missing" ] || printf 'missing (neither listed nor excluded): %s\n' "$(tr '\n' ' ' <<<"$missing")"
  [ -z "$stale" ] || printf 'stale (not in the derived set): %s\n' "$(tr '\n' ' ' <<<"$stale")"
  [ -z "$both" ] || printf 'listed AND excluded: %s\n' "$(tr '\n' ' ' <<<"$both")"
  [ -z "$missing" ] && [ -z "$stale" ] && [ -z "$both" ] && [ "$bad" -eq 0 ]
}

case "${1:-}" in
  --complete) shift; [ "$#" -eq 3 ] || { echo "usage: $0 --complete RESEARCH_DIR LIST EXCL" >&2; exit 2; }; lrl_complete "$1" "$2" "$3"; rc=$?; [ "$rc" -le 2 ] && exit "$rc"; exit 2 ;;
  --scan) shift; lrl_scan "$@"; exit $? ;;
  --scan-tree) shift; [ "$#" -eq 1 ] || { echo "usage: $0 --scan-tree RESEARCH_DIR" >&2; exit 2; }; lrl_tree "$1"; exit $? ;;
esac

pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass + 1)); }
no() { echo "  FAIL  $1"; fail=$((fail + 1)); }
TMP="$(mktemp -d)" || exit 2
MUT=""
trap 'rm -rf "$TMP" ${MUT:+"$MUT"}' EXIT

# ---- Scanner fixtures: each recognised form in first / middle / last position + the single-element case ----
check_scan() {   # check_scan LABEL EXPECTED_VIOLATIONS FILE
  local out
  out="$(bash "$SELF" --scan "$3" 2>&1)"
  if grep -qx "violations: $2" <<<"$out"; then ok "$1 → $2 violations"
  else no "$1: expected 'violations: $2', got: $(grep -E '^violations|ERROR' <<<"$out" | tr '\n' ';')"; fi
}
mkdir -p "$TMP/fx"
cat > "$TMP/fx/f1.sh" <<'EOF'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
echo middle
. "$(cd "$(dirname -- "$0")/.." && pwd)/lib/x.sh"
echo "$(dirname "${0}")" "$(dirname $0)"
EOF
check_scan "F1 dirname forms (first, dash-dash, braced+bare on one line: 3 lines)" 3 "$TMP/fx/f1.sh"
printf 'x=1\nK="$(cd -P "$(dirname "$0")/.." && pwd -P)"\n' > "$TMP/fx/f1-last.sh"
check_scan "F1 on the LAST line" 1 "$TMP/fx/f1-last.sh"
printf 'LIB="$(dirname "$0")/lib/a.sh"\n' > "$TMP/fx/f1-single.sh"
check_scan "F1 single-element file" 1 "$TMP/fx/f1-single.sh"
printf 'echo a\nd="${0%%/*}"\nd2="${0%%%%/*}"\necho z\n' > "$TMP/fx/f2.sh"
check_scan "F2 \${0%/*} and \${0%%/*}" 2 "$TMP/fx/f2.sh"
printf 'echo a\ns="$(readlink -f -- "$0")"\nt="$(realpath "$0")"\n' > "$TMP/fx/f3.sh"
check_scan "F3 readlink -f / realpath of \$0" 2 "$TMP/fx/f3.sh"
printf 'me="$0"\necho mid\nd="$(dirname -- "$me")"\ne="${me%%/*}"\nr="$(readlink -f "$me")"\n' > "$TMP/fx/f4.sh"
check_scan "F4 alias then dirname / suffix strip / readlink (3 uses)" 3 "$TMP/fx/f4.sh"
printf 'local me=$0\nd="$(dirname "$me")"\n' > "$TMP/fx/f4b.sh"
check_scan "F4 local alias, unquoted assignment" 1 "$TMP/fx/f4b.sh"
printf 'echo a\nd="$(cd "$(dirname \\\n   "$0")" && pwd)"\necho z\n' > "$TMP/fx/multi.sh"
check_scan "multi-line: backslash continuation between dirname and \$0" 1 "$TMP/fx/multi.sh"
cat > "$TMP/fx/clean.sh" <<'EOF'
#!/usr/bin/env bash
# dirname "$0" in a comment is not code
_rsdd_s="${BASH_SOURCE[0]}"
HERE="$(cd -P -- "$(dirname -- "$_rsdd_s")" && pwd -P)"
echo "usage: $0 [opts]" >&2
printf '%s\n' "${0##*/}" "$(basename "$0")"
awk '{ print $0 }' "$HERE/x"
sed -n '2,5p' "$0"
[ "${BASH_SOURCE[0]}" = "${0}" ] && echo main
other="$(dirname "$HERE")"
EOF
check_scan "clean file (BASH_SOURCE, usage/display uses of \$0, awk \$0, non-alias dirname)" 0 "$TMP/fx/clean.sh"
printf 'd="$(dirname "$0")"   # lib-resolution-ok: pattern literal, not a resolution\n' > "$TMP/fx/ex.sh"
out="$(bash "$SELF" --scan "$TMP/fx/ex.sh" 2>&1)"
if grep -qx 'violations: 0' <<<"$out" && grep -qx 'exempt sites: 1' <<<"$out"; then ok "marker with a reason exempts (counted)"; else no "marker with reason: $out"; fi
printf 'd="$(dirname "$0")"   # lib-resolution-ok:\n' > "$TMP/fx/ex2.sh"
check_scan "marker WITHOUT a reason does not exempt" 1 "$TMP/fx/ex2.sh"
printf 'd="$(dirname "$0")"   # lib-resolution-ok: two words\n' > "$TMP/fx/ex3.sh"
check_scan "marker with a 2-word reason does not exempt (>= 3 words)" 1 "$TMP/fx/ex3.sh"
printf 'echo "a # lib-resolution-ok: not a comment at all"; d="$(dirname "$0")"\n' > "$TMP/fx/ex4.sh"
check_scan "marker text INSIDE a string is not an exemption" 1 "$TMP/fx/ex4.sh"
out="$(bash "$SELF" --scan "$TMP/fx/ex.sh" 2>&1)"
if grep -qE '^exempt .*ex\.sh:1:F1: ' <<<"$out"; then ok "each exempt site is printed (exempt FILE:LINE:FORM)"; else no "exempt site not printed: $out"; fi
# W4: terminators beyond quote/space/;/) — backtick substitution, pipe, background/pipe-stderr.
printf 'a=`dirname "$0"`\nb=`dirname $0`\nc=$(dirname $0|head -1)\nd=$(dirname "$0"&)\n' > "$TMP/fx/term.sh"
check_scan "F1 terminators: backtick (quoted and bare), pipe, ampersand (4 lines)" 4 "$TMP/fx/term.sh"
printf 'a=`readlink -f $0`\nb=$(realpath $0|cat)\n' > "$TMP/fx/term3.sh"
check_scan "F3 terminators: backtick and pipe (2 lines)" 2 "$TMP/fx/term3.sh"
# S6: a `#` inside quotes is not a comment, so code after it is still scanned.
printf 'echo "x # y"; d="$(dirname "$0")"\n' > "$TMP/fx/s6.sh"
check_scan "a # inside a string does not hide the dirname after it" 1 "$TMP/fx/s6.sh"
printf 'echo "${#arr[@]}" "$#"; d="$(dirname "$0")"\n' > "$TMP/fx/s6b.sh"
check_scan "\${#x} and \$# are not comments" 1 "$TMP/fx/s6b.sh"
printf 'echo ok # dirname "$0" in a trailing comment\n' > "$TMP/fx/s6c.sh"
check_scan "a real trailing comment is still ignored" 0 "$TMP/fx/s6c.sh"
cat > "$TMP/fx/f2b.sh" <<'EOF'
d2=${0/%\/*}
echo mid
d3="${0/\/*/}"
EOF
check_scan "F2 pattern substitution on \$0 (\${0/%\\/*}, \${0/\\/*/}: 2 lines)" 2 "$TMP/fx/f2b.sh"
cat > "$TMP/fx/ansic.sh" <<'EOF'
x=$'it\'s # y'; d="$(dirname "$0")"
EOF
check_scan "\$'it\\'s # y' keeps the quote open, so the dirname after it is still scanned" 1 "$TMP/fx/ansic.sh"
printf 'msg="a\n  # x"; d=$(dirname "$0")\n' > "$TMP/fx/multiline-str.sh"
check_scan "KNOWN LIMIT (pinned): # on the continuation line of a multi-line string hides the dirname after it" 0 "$TMP/fx/multiline-str.sh"
# S7: alias declared with flags.
printf 'declare -r me="$0"\ntypeset -r m2=$0\nreadonly -- m3="$0"\nd="$(dirname "$me")"\ne="$(dirname "$m2")"\nf="$(dirname "$m3")"\n' > "$TMP/fx/f4c.sh"
check_scan "F4 alias via declare -r / typeset -r / readonly -- (3 uses)" 3 "$TMP/fx/f4c.sh"
printf '# only a comment\n\n' > "$TMP/fx/empty.sh"
out="$(bash "$SELF" --scan "$TMP/fx/empty.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'no code lines' <<<"$out"; then ok "a file with no code lines → exit 2, never a silent 0"; else no "no-code file: rc=$rc"; fi
out="$(bash "$SELF" --scan 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'no files to scan' <<<"$out"; then ok "no files → exit 2"; else no "no files: rc=$rc"; fi
out="$(bash "$SELF" --scan "$TMP/does-not-exist.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'unreadable' <<<"$out"; then ok "unreadable file → exit 2"; else no "unreadable: rc=$rc"; fi
mkdir -p "$TMP/root/toolbelt/lib" "$TMP/root/install"
out="$(bash "$SELF" --scan-tree "$TMP/root" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'empty corpus' <<<"$out"; then ok "corpus dir with no *.sh → exit 2"; else no "empty corpus: rc=$rc"; fi
out="$(bash "$SELF" --scan-tree "$TMP/nonexistent" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'absent corpus' <<<"$out"; then ok "absent corpus → exit 2"; else no "absent corpus: rc=$rc"; fi

# ---- REAL tree -------------------------------------------------------------
out="$(bash "$SELF" --scan-tree "$TB/.." 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'violations: 0' <<<"$out"; then ok "REAL TREE: 0 \$0-derived directories across the declared corpus"
else no "REAL TREE lint failed (rc=$rc): $(grep -E '^[^ ]+:[0-9]+:F[0-9]|ERROR' <<<"$out" | head -10 | tr '\n' ';')"; fi
for pat in '^corpus toolbelt/\*\.sh: [1-9]' '^corpus toolbelt/lib/\*\.sh: [1-9]' '^corpus install/\*\.sh: [1-9]' '^files scanned: [1-9]' '^forms recognised' '^forms NOT recognised' '^exempt sites: [0-9]'; do
  if grep -qE -- "$pat" <<<"$out"; then ok "report prints: $pat"; else no "report is missing: $pat"; fi
done

# ---- Behavioural: a planted lib/ in the CALLER's cwd is never sourced ---------
# For every toolbelt/install script that resolves a lib or a sibling: run `bash <name>` (found through PATH, so $0 has
# no slash) from a temp dir whose lib/ holds a sentinel under every real lib filename; the sentinel writes a marker.
mark="$TMP/marker"
planted="$TMP/planted"
mkdir -p "$planted/lib" "$TMP/home" "$TMP/rh"
for l in "$TB"/lib/*.sh; do printf ': > "$RSDD_LR_MARK"\n' > "$planted/lib/$(basename "$l")"; done
# planted_run SCRIPT_DIR NAME -> 0 ONLY when the script existed, actually ran (rc not 126/127/124) and the marker was NOT
# created. Sets PR_WHY (why it returned 1) and PR_REACHED (1 when the xtrace shows a lib source from outside the planted dir).
PR_TIMEOUT="${RSDD_LR_TIMEOUT:-30}"
TB_RE="$(printf '%s' "$TB" | sed 's/[][\.*^$+?(){}|]/\\&/g')"   # TB as a literal inside an ERE
planted_run() {
  local rc trace
  PR_WHY=""; PR_REACHED=0; rm -f "$mark" "$TMP/run.out"
  command -v "${RSDD_LR_TIMEOUT_BIN:-timeout}" >/dev/null 2>&1 || { PR_WHY="timeout not on PATH (DEGRADED: the behavioural run cannot be bounded)"; return 1; }   # SENTINEL-LRL-TIMEOUT
  [ -f "$1/$2" ] || { PR_WHY="script not found: $1/$2"; return 1; }   # SENTINEL-LRL-EXISTS
  ( cd "$planted" && RSDD_LR_MARK="$mark" HOME="$TMP/home" RESEARCH_HOME="$TMP/rh" PATH="$1:$PATH" \
      "${RSDD_LR_TIMEOUT_BIN:-timeout}" "$PR_TIMEOUT" bash -x "$2" </dev/null >"$TMP/run.out" 2>&1 )
  rc=$?
  case "$rc" in 124) PR_WHY="timed out after ${PR_TIMEOUT}s"; return 1 ;; 126|127) PR_WHY="could not run (rc $rc)"; return 1 ;; esac   # SENTINEL-LRL-RC
  [ ! -e "$mark" ] || { PR_WHY="planted lib executed"; return 1; }   # SENTINEL-LRL-PLANTED
  # Reached = the xtrace shows a source line whose path starts with the REAL "$TB/lib/" (not a ghost path, not the planted dir).
  # The trace is captured first: a `producer | grep -q` pipeline under pipefail can read SIGPIPE as failure (CLAUDE.md §7).
  trace="$(grep -E '^\++ (\.|source) ' "$TMP/run.out")"
  if grep -qE "^\\++ (\\.|source) $TB_RE/lib/" <<<"$trace"; then PR_REACHED=1; fi   # SENTINEL-LRL-REACHED
  return 0
}
# Synthetic scripts: planted_run must be able to FAIL (a vacuous pass is a silent zero) — and to tell "reached a lib" from "exited early".
planted_selfchecks() {
  local d="$TMP/pr" first="" l
  mkdir -p "$d/lib"
  for l in "$TB"/lib/*.sh; do first="$(basename "$l")"; break; done
  [ -n "$first" ] || { no "planted_run self-check: no real lib to model"; return; }
  printf 'echo real-lib\n' > "$d/lib/$first"
  printf 'exit 0\n' > "$d/early.sh"
  printf '. "%s/lib/%s"\n' "$TB" "$first" > "$d/real.sh"
  printf '. /nonexistent-dir/lib/x.sh\nexit 1\n' > "$d/ghost.sh"
  printf '. "$(dirname "$0")/lib/%s"\n' "$first" > "$d/bad.sh"
  printf 'exit 127\n' > "$d/e127.sh"
  printf 'sleep 5\n' > "$d/slow.sh"
  planted_run "$d" early.sh && [ "$PR_REACHED" -eq 0 ] && ok "planted_run: a script that exits early passes and is classed 'exited early'" || no "planted_run early exit: why=$PR_WHY reached=$PR_REACHED"
  planted_run "$d" real.sh && [ "$PR_REACHED" -eq 1 ] && ok "planted_run: a script sourcing its real lib passes and is classed 'reached a lib'" || no "planted_run real lib: why=$PR_WHY reached=$PR_REACHED"
  planted_run "$d" ghost.sh && [ "$PR_REACHED" -eq 0 ] && ok "planted_run: a FAILED source from a ghost lib/ path is not counted as 'reached a lib'" || no "planted_run ghost source: why=$PR_WHY reached=$PR_REACHED"
  if planted_run "$d" bad.sh; then no "planted_run rejects a script that executes the planted lib (it PASSED a \$0-based lib source)"
  elif [ "$PR_WHY" = "planted lib executed" ]; then ok "planted_run rejects a script that executes the planted lib ($PR_WHY)"
  else no "planted_run rejects a script that executes the planted lib (rejected for the WRONG reason: $PR_WHY)"; fi
  if planted_run "$d" missing.sh; then no "planted_run rejects a listed script that does not exist"; else ok "planted_run rejects a listed script that does not exist"; fi
  if planted_run "$d" e127.sh; then no "planted_run rejects a script that exits 127 (could not run)"; else ok "planted_run rejects a script that exits 127 (could not run)"; fi
  PR_TIMEOUT=1
  if planted_run "$d" slow.sh; then no "planted_run rejects a script that times out"; else ok "planted_run rejects a script that times out"; fi
  PR_TIMEOUT="${RSDD_LR_TIMEOUT:-30}"
}
if [ "${1:-}" = "--planted-selfcheck" ]; then planted_selfchecks; echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]; exit $?; fi
beh_list="$FIX/planted-lib-scripts.txt"
if [ ! -s "$beh_list" ]; then no "behavioural fixture list missing or empty: $beh_list"
else
  nrun=0; nbad=0; badnames=""; nreach=0; early=""
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    nrun=$((nrun + 1))
    dir="$TB"; case "$line" in install/*) dir="$TB/../install"; line="${line#install/}" ;; esac
    if planted_run "$dir" "$line"; then
      if [ "$PR_REACHED" -eq 1 ]; then nreach=$((nreach + 1)); else early="$early $line"; fi
    else nbad=$((nbad + 1)); badnames="$badnames $line($PR_WHY)"; fi
  done < "$beh_list"
  if [ "$nrun" -gt 0 ] && [ "$nbad" -eq 0 ]; then ok "planted lib/ in cwd was never sourced by any of $nrun scripts"
  else no "planted lib/ check failed ($nbad of $nrun scripts):$badnames"; fi
  echo "  INFO  planted-lib coverage: $nreach of $nrun scripts reached a real lib source (behavioural proof); $((nrun - nreach - nbad)) exited before sourcing (lint-only coverage):$early"
  if [ "$nreach" -gt 0 ]; then ok "at least one listed script reached a real lib source ($nreach) — the run is not vacuous"; else no "no listed script reached a real lib source: the behavioural run proved nothing"; fi
fi
planted_selfchecks
out="$(bash "$SELF" --complete "$TB/.." "$beh_list" "$FIX/planted-lib-exclusions.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "completeness: every _RSDD_SELF script is listed or declared excluded ($(grep -E '^completeness' <<<"$out"))"
else no "completeness (rc=$rc): $(tr '\n' ';' <<<"$out")"; fi
# Completeness fixtures: a gap, a stale entry, a reasonless exclusion, and the clean case.
cr="$TMP/cr"; mkdir -p "$cr/toolbelt/lib" "$cr/install"
printf '_RSDD_SELF=1\n' > "$cr/toolbelt/a.sh"; printf '_RSDD_SELF=1\n' > "$cr/toolbelt/b.sh"; printf 'echo x\n' > "$cr/toolbelt/lib/x.sh"
printf 'a.sh\nb.sh\n' > "$TMP/cr-all.txt"; printf 'a.sh\n' > "$TMP/cr-a.txt"; printf 'a.sh\nb.sh\nghost.sh\n' > "$TMP/cr-ghost.txt"
: > "$TMP/cr-none.txt"; printf 'b.sh | declared out for a reason\n' > "$TMP/cr-excl.txt"; printf 'b.sh | nope\n' > "$TMP/cr-excl-bad.txt"
out="$(bash "$SELF" --complete "$cr" "$TMP/cr-all.txt" "$TMP/cr-none.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'missing 0 · stale 0' <<<"$out"; then ok "completeness: listed set equals derived set → rc 0"; else no "completeness clean case rc=$rc: $out"; fi
out="$(bash "$SELF" --complete "$cr" "$TMP/cr-a.txt" "$TMP/cr-none.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'missing 1' <<<"$out" && grep -q 'missing (neither listed nor excluded): b.sh' <<<"$out"; then ok "completeness: an unlisted _RSDD_SELF script is reported missing → rc 1"; else no "completeness gap rc=$rc: $out"; fi
out="$(bash "$SELF" --complete "$cr" "$TMP/cr-ghost.txt" "$TMP/cr-none.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'stale 1' <<<"$out"; then ok "completeness: a listed script outside the derived set is reported stale → rc 1"; else no "completeness stale rc=$rc: $out"; fi
out="$(bash "$SELF" --complete "$cr" "$TMP/cr-a.txt" "$TMP/cr-excl.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "completeness: a declared exclusion with a reason closes the gap"; else no "completeness exclusion rc=$rc: $out"; fi
out="$(bash "$SELF" --complete "$cr" "$TMP/cr-a.txt" "$TMP/cr-excl-bad.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'invalid exclusion' <<<"$out"; then ok "completeness: an exclusion with a < 3-word reason is invalid → rc 1"; else no "completeness bad reason rc=$rc: $out"; fi
mkdir -p "$TMP/cr0/toolbelt"; printf 'echo x\n' > "$TMP/cr0/toolbelt/z.sh"
out="$(bash "$SELF" --complete "$TMP/cr0" "$TMP/cr-all.txt" "$TMP/cr-none.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'derived set is empty' <<<"$out"; then ok "completeness: an empty derived set → rc 2, never a silent pass"; else no "completeness empty rc=$rc: $out"; fi
# Symlink invocation: the real lib/ must be found (not the cwd's, not 'missing') through a symlink in another dir.
mkdir -p "$TMP/linkbin"
for name in sweep-retros.sh verify-registry.sh sweep-audits-hook.sh verify-state.sh; do
  ln -sf "$TB/$name" "$TMP/linkbin/$name"
  # planted_run: existence, timeout probe, rc 124/126/127, marker, and the reached-a-real-lib proof (path under "$TB/lib/").
  if planted_run "$TMP/linkbin" "$name" && [ "$PR_REACHED" -eq 1 ] \
     && ! grep -qE 'cannot find helper|failed to define|missing beside|No such file or directory' "$TMP/run.out"; then
    ok "symlink invocation of $name reached its real lib/ and ignored the cwd's"
  else no "symlink invocation of $name: why=${PR_WHY:-none} reached=$PR_REACHED marker=$([ -e "$mark" ] && echo yes || echo no) out=$(head -c 200 "$TMP/run.out" | tr '\n' ' ')"; fi
done
# A relative symlink (target relative to the link's directory) must resolve too.
mkdir -p "$TMP/rel/bin"
ln -sf "../tb/sweep-audits-hook.sh" "$TMP/rel/bin/sweep-audits-hook.sh"
ln -sfn "$TB" "$TMP/rel/tb"
if planted_run "$TMP/rel/bin" sweep-audits-hook.sh && [ "$PR_REACHED" -eq 1 ] && ! grep -qE 'missing beside|cannot find' "$TMP/run.out"; then
  ok "relative symlink resolves the real lib/ (marker absent, real lib sourced)"
else no "relative symlink: why=${PR_WHY:-none} reached=$PR_REACHED marker=$([ -e "$mark" ] && echo yes || echo no) out=$(head -c 200 "$TMP/run.out" | tr '\n' ' ')"; fi

# ---- Teeth (mutation proof) -------------------------------------------------
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
typeset -f mutant_chain >/dev/null 2>&1 && typeset -f mutant_tooth >/dev/null 2>&1 \
  || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_tooth ($HERE/lib/mutant.sh)" >&2; exit 2; }
mk_sed() {
  local out="$2"
  mkdir -p "$(dirname "$out")"
  mutant_chain "$1" "$SELF" "$out" "${@:3}" || { fail=$((fail + 1)); return 1; }
}
tooth() { if mutant_tooth "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }

if [ "${1:-}" = "--prove-teeth" ]; then
  MUT="$(mktemp -d)"
  M='lib-resolution-lint.test.sh'
  echo "-- teeth: each detector facet must be load-bearing --"

  # Tooth 1-3: each of the F1 / F2 / F3 detectors disabled in turn -> its form passes unseen.
  for spec in "F1:f1.sh:3" "F2:f2.sh:2" "F3:f3.sh:2"; do
    form="${spec%%:*}"; rest="${spec#*:}"; fxf="${rest%%:*}"; want="${rest#*:}"
    mk_sed "teeth $form" "$MUT/$form/$M" "/SENTINEL-LRL-$form\$/ s/hit = \"$form\"/hit = \"\"/" \
      && tooth "teeth $form: detector off -> its form is missed" 1 0 "$MUT/$form/$M" \
           --good-has "violations: $want" --bad-has 'violations: 0' -- bash @SUT@ --scan "$TMP/fx/$fxf"
  done

  # Tooth 4: alias tracking dropped -> V="$0" then dirname "$V" passes.
  mk_sed "teeth F4" "$MUT/f4/$M" '/SENTINEL-LRL-ALIAS$/ s/alias\[v\] = 1/v = v/' \
    && tooth "teeth F4: alias never recorded -> aliased dirname missed" 1 0 "$MUT/f4/$M" \
         --good-has 'violations: 3' --bad-has 'violations: 0' -- bash @SUT@ --scan "$TMP/fx/f4.sh"

  # Tooth 5: continuation joining dropped -> a dirname split across lines passes.
  mk_sed "teeth multiline" "$MUT/multi/$M" '/SENTINEL-LRL-CONT$/ s/if (\$0 ~ [^)]*)/if (0)/' \
    && tooth "teeth multiline: continuation not joined -> split dirname missed" 1 0 "$MUT/multi/$M" \
         --good-has 'violations: 1' --bad-has 'violations: 0' -- bash @SUT@ --scan "$TMP/fx/multi.sh"

  # Tooth 6: the reason requirement dropped -> a reasonless marker exempts.
  mk_sed "teeth marker-reason" "$MUT/marker/$M" '/SENTINEL-LRL-MARKER$/ s/nw >= 3/nw >= 0/' \
    && tooth "teeth marker-reason: reasonless marker exempts -> missed" 1 0 "$MUT/marker/$M" \
         --good-has 'violations: 1' --bad-has 'violations: 0' -- bash @SUT@ --scan "$TMP/fx/ex2.sh"

  # Tooth 7: the zero-files guard removed.
  mk_sed "teeth zero-files" "$MUT/zero/$M" '/^  \[ "\$#" -gt 0 \] || .*# SENTINEL-LRL-ZERO-FILES$/ s/.*/  :/' \
    && tooth "teeth zero-files: guard removed → the 'no files' message is gone" 2 2 "$MUT/zero/$M" \
         --good-has 'no files to scan' --bad-lacks 'no files to scan' -- bash -c 'bash "$0" --scan </dev/null' @SUT@

  # Tooth 8: the no-code-lines guard removed → a comment-only file reads as a clean pass.
  mk_sed "teeth code-lines" "$MUT/code/$M" '/^  grep -qE .\^code lines: .*# SENTINEL-LRL-CODE-LINES$/ s/.*/  :/' \
    && tooth "teeth code-lines: guard removed → a code-less file passes silently" 2 0 "$MUT/code/$M" \
         --good-has 'no code lines' --bad-has 'violations: 0' -- bash @SUT@ --scan "$TMP/fx/empty.sh"

  # Tooth 9: the behavioural check bites — the cwd-derived resolution is restored in a COPY of one script.
  mkdir -p "$MUT/beh/tb/lib"
  cp "$TB"/lib/*.sh "$MUT/beh/tb/lib/"
  sed -e 's#^_RSDD_SELF=.*#_RSDD_SELF="$(cd "$(dirname "$0")" \&\& pwd)"#' "$TB/sweep-audits-hook.sh" > "$MUT/beh/tb/sweep-audits-hook.sh"
  if grep -q 'dirname "\$0"' "$MUT/beh/tb/sweep-audits-hook.sh"; then
    if planted_run "$MUT/beh/tb" sweep-audits-hook.sh; then no "teeth behavioural: the \$0-based mutant did NOT execute the planted lib (the check has no teeth)"
    elif [ "$PR_WHY" = "planted lib executed" ]; then ok "teeth behavioural: a \$0-based mutant of a fixed script executes the planted lib → the behavioural check goes red"
    else no "teeth behavioural: the mutant was rejected for the WRONG reason: $PR_WHY"; fi
  else no "teeth behavioural: mutant could not be built (no \$_RSDD_SELF assignment found in sweep-audits-hook.sh)"; fi

  # Tooth 10-13: F1 terminator class, quote-aware comment, marker word count, alias recording with flags.
  mk_sed "teeth terminators" "$MUT/term/$M" '/SENTINEL-LRL-F1$/ s/ \\t;)`|&\]/ \\t;)]/' \
    && tooth "teeth terminators: backtick/pipe/ampersand class dropped from F1 -> backtick dirname missed" 1 1 "$MUT/term/$M" \
         --good-has 'violations: 4' --bad-lacks 'violations: 4' -- bash @SUT@ --scan "$TMP/fx/term.sh"
  mk_sed "teeth quote" "$MUT/quote/$M" '/SENTINEL-LRL-QUOTE$/ s/{ q = c; continue }/{ continue }/' \
    && tooth "teeth quote: quotes ignored -> a # inside a string hides the dirname after it" 1 0 "$MUT/quote/$M" \
         --good-has 'violations: 1' --bad-has 'violations: 0' -- bash @SUT@ --scan "$TMP/fx/s6.sh"
  tooth "teeth quote: quotes ignored -> a marker inside a string exempts" 1 0 "$MUT/quote/$M" \
         --good-has 'violations: 1' --bad-has 'violations: 0' -- bash @SUT@ --scan "$TMP/fx/ex4.sh"
  mk_sed "teeth marker-words" "$MUT/words/$M" '/SENTINEL-LRL-MARKER$/ s/nw >= 3/nw >= 1/' \
    && tooth "teeth marker-words: 3-word minimum dropped -> a 2-word marker exempts" 1 0 "$MUT/words/$M" \
         --good-has 'violations: 1' --bad-has 'violations: 0' -- bash @SUT@ --scan "$TMP/fx/ex3.sh"
  # (Same mutation as tooth F4: it proves the flagged declarations feed the SAME alias table; the scanner has no flag-specific code.)
  mk_sed "teeth alias-flags" "$MUT/aflags/$M" '/SENTINEL-LRL-ALIAS$/ s/alias\[v\] = 1/v = v/' \
    && tooth "teeth alias recording on flagged declarations (declare -r / typeset -r / readonly --): fixture f4c needs the alias table" 1 0 "$MUT/aflags/$M" \
         --good-has 'violations: 3' --bad-has 'violations: 0' -- bash @SUT@ --scan "$TMP/fx/f4c.sh"

  mk_sed "teeth ansic" "$MUT/ansic/$M" '/SENTINEL-LRL-ANSIC$/ s/{ q = "\$'"'"'"; i++; continue }/{ }/' \
    && tooth "teeth ansic: \$'..' quote state dropped -> the escaped quote inverts the state and hides the dirname" 1 0 "$MUT/ansic/$M" \
         --good-has 'violations: 1' --bad-has 'violations: 0' -- bash @SUT@ --scan "$TMP/fx/ansic.sh"
  mk_sed "teeth F2-subst" "$MUT/f2s/$M" '/SENTINEL-LRL-F2$/ s/\[%\\\/\]/[%]/' \
    && tooth "teeth F2-subst: pattern substitution dropped from F2 -> \${0/%\\/*} missed" 1 0 "$MUT/f2s/$M" \
         --good-has 'violations: 2' --bad-has 'violations: 0' -- bash @SUT@ --scan "$TMP/fx/f2b.sh"

  # Tooth: exclusion-reason rule, listed-and-excluded, reached counter.
  mk_sed "teeth reason" "$MUT/reason/$M" '/SENTINEL-LRL-REASON$/ s/-lt 3/-lt 0/' \
    && tooth "teeth reason: 3-word rule dropped -> a reasonless exclusion is accepted" 1 0 "$MUT/reason/$M" \
         --good-has 'invalid 1' --bad-has 'invalid 0' -- bash @SUT@ --complete "$cr" "$TMP/cr-a.txt" "$TMP/cr-excl-bad.txt"
  mk_sed "teeth both" "$MUT/both/$M" '/SENTINEL-LRL-BOTH$/ s/both="\$(.*)"/both=""/' \
    && tooth "teeth both: listed-and-excluded check removed -> a double entry passes" 1 0 "$MUT/both/$M" \
         --good-has 'listed-and-excluded 1' --bad-has 'listed-and-excluded 0' -- bash @SUT@ --complete "$cr" "$TMP/cr-all.txt" "$TMP/cr-excl.txt"
  mk_sed "teeth reached" "$MUT/reached/$M" '/SENTINEL-LRL-REACHED$/ s/\$TB_RE\/lib\//[^ ]*\/lib\//' \
    && tooth "teeth reached: real-prefix requirement dropped -> a failed ghost source counts as reached" 0 1 "$MUT/reached/$M" \
         --good-has 'PASS  planted_run: a FAILED source' --bad-has 'FAIL  planted_run ghost source' -- bash @SUT@ --planted-selfcheck

  # Tooth 14-18: planted_run is not vacuous — each guard removed lets its synthetic bad case through.
  mk_sed "teeth planted_run RC" "$MUT/prRC/$M" '/SENTINEL-LRL-RC$/ s/.*/  :/' \
    && tooth "teeth planted_run RC: rc check removed -> an exit-127 script passes" 0 1 "$MUT/prRC/$M" \
         --good-has 'PASS  planted_run rejects a script that exits 127' --bad-has 'FAIL  planted_run rejects a script that exits 127' -- bash @SUT@ --planted-selfcheck \
    && tooth "teeth planted_run RC: rc check removed -> a timed-out script passes" 0 1 "$MUT/prRC/$M" \
         --good-has 'PASS  planted_run rejects a script that times out' --bad-has 'FAIL  planted_run rejects a script that times out' -- bash @SUT@ --planted-selfcheck
  mk_sed "teeth planted_run PLANTED" "$MUT/prPL/$M" '/SENTINEL-LRL-PLANTED$/ s/\[ ! -e "\$mark" \] ||/true ||/' \
    && tooth "teeth planted_run PLANTED: marker check removed -> a script executing the planted lib passes" 0 1 "$MUT/prPL/$M" \
         --good-has 'PASS  planted_run rejects a script that executes the planted lib' --bad-has 'FAIL  planted_run rejects a script that executes the planted lib' -- bash @SUT@ --planted-selfcheck
  mk_sed "teeth planted_run EXISTS" "$MUT/prEX/$M" '/SENTINEL-LRL-EXISTS$/ s/\[ -f "\$1\/\$2" \] ||/true ||/' '/SENTINEL-LRL-RC$/ s/126|127) PR_WHY="could not run (rc \$rc)"; return 1 ;;//' \
    && tooth "teeth planted_run EXISTS: existence + rc-127 guards removed -> a missing script passes" 0 1 "$MUT/prEX/$M" \
         --good-has 'PASS  planted_run rejects a listed script that does not exist' --bad-has 'FAIL  planted_run rejects a listed script that does not exist' -- bash @SUT@ --planted-selfcheck
  mk_sed "teeth planted_run TIMEOUT" "$MUT/prTO/$M" '/SENTINEL-LRL-TIMEOUT$/ s/.*/  :/' \
    && tooth "teeth planted_run TIMEOUT: probe removed -> the typed DEGRADED reason is gone" 1 1 "$MUT/prTO/$M" \
         --good-has 'timeout not on PATH' --bad-lacks 'timeout not on PATH' -- env RSDD_LR_TIMEOUT_BIN=rsdd-no-such-timeout bash @SUT@ --planted-selfcheck

  # Tooth 18-19: completeness gate bites on a gap and on a stale entry.
  mk_sed "teeth missing" "$MUT/miss/$M" '/SENTINEL-LRL-MISSING$/ s/missing="\$(.*)"/missing=""/' \
    && tooth "teeth missing: gap detection removed -> an unlisted _RSDD_SELF script passes" 1 0 "$MUT/miss/$M" \
         --good-has 'missing 1' --bad-has 'missing 0' -- bash @SUT@ --complete "$cr" "$TMP/cr-a.txt" "$TMP/cr-none.txt"
  mk_sed "teeth stale" "$MUT/stale/$M" '/SENTINEL-LRL-STALE$/ s/stale="\$(.*)"/stale=""/' \
    && tooth "teeth stale: stale detection removed -> a ghost entry passes" 1 0 "$MUT/stale/$M" \
         --good-has 'stale 1' --bad-has 'stale 0' -- bash @SUT@ --complete "$cr" "$TMP/cr-ghost.txt" "$TMP/cr-none.txt"
  mk_sed "teeth zeroexp" "$MUT/zexp/$M" '/SENTINEL-LRL-ZEROEXP$/ s/.*/  :/' \
    && tooth "teeth zeroexp: empty-derived-set guard removed -> no message" 2 1 "$MUT/zexp/$M" \
         --good-has 'derived set is empty' --bad-lacks 'derived set is empty' -- bash @SUT@ --complete "$TMP/cr0" "$TMP/cr-all.txt" "$TMP/cr-none.txt"

  rm -rf "$MUT"; MUT=""
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

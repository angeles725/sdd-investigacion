#!/usr/bin/env bash
# summary-line-lint.test.sh — ONE shared structural lint: every kit test suite must be able to print the
# run-all summary line `== N passed · M failed ==` (kit issue #2169).
#
# Why: run-all.sh classifies a suite whose output has a summary-LIKE line that does not match
# `^== ([0-9]+) passed · ([0-9]+) failed ==$` as "malformed summary, exit 0" and FAILS it. A new suite that
# invents its own format passes standalone and only fails the full gate (three recurrences on 2026-10-11:
# `name: N passed, M failed`, `N passed, M failed, K skipped (ms)`, `RESULT: pass=N fail=M`).
#
# Modes
#   (default)                run the lint's own cases (fixtures + mutation controls with --prove-teeth) and
#                            lint the REAL tree: this suite is the gate.
#   --scan FILE...           lint exactly FILE... and print the report
#   --scan-tree RESEARCH_DIR lint the declared corpora under RESEARCH_DIR and print the report
#   Exit (--scan, --scan-tree): 0 no violations · 1 violations · 2 operational failure (absent corpus, empty
#   corpus, zero files, unreadable file, a file with no code lines) — a zero is never a silent pass (§7).
#
# What it checks (static, source level): a file passes when at least one NON-comment line contains an emitter
# of the exact summary shape (see sl_forms). It cannot prove the line is the LAST line printed or that it is
# reached at runtime; that is run-all.sh's job. Known limit: a line that merely GENERATES a fixture suite
# (e.g. printf 'echo "== 1 passed · 0 failed =="') also satisfies the lint, so a suite that only contains
# fixture text is not caught — the lint is a floor, not a proof.
#
# Exemption (explicit, never silent): a line `# summary-lint: dynamic <reason>` in the file marks a suite whose
# summary is produced by code the lint cannot see (e.g. a sourced harness). A marker without a reason does not
# exempt. Exempt files are counted and listed in the report.
#
# Exit (default mode): 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$HERE/$(basename "$0")"
# shellcheck disable=SC2034 # read by lib/mutant.sh (mutant_tooth) as the original each mutant is compared with
SUT="$SELF"
FIX="$HERE/fixtures/summary-line-lint"

# The shape run-all.sh accepts (summary_re: the WHOLE line is `== N passed · M failed ==`), as it appears in
# SOURCE text. The emitter must start at the opening of its string literal (a quote, a backtick or a literal \n,
# which also covers print(f"), each count is ONE source token ($v, ${v}, $((expr)), %d, %s, {v}, a number), the
# separator is U+00B7 / $MID / ${MID} / %s, spaces are single, and `==` must be followed by the closing quote
# or \n. A prefix, an indent, an inner double space or trailing text therefore does not match.
SL_Q="[\"'\`]"
SL_EDGE="(${SL_Q}|\\\\n)"
SL_CNT='(\$[A-Za-z_]+|\$\{[^}]+\}|\$\(\([^)]*\)\)|%[ds]|\{[a-z_]+\}|[0-9]+)'
SL_LIT="${SL_EDGE}== ${SL_CNT} passed · ${SL_CNT} failed ==${SL_EDGE}"   # SENTINEL-SL-LIT
SL_MID="${SL_EDGE}== ${SL_CNT} passed (\\\$MID|\\\$\\{MID\\}|%s) ${SL_CNT} failed ==${SL_EDGE}"   # SENTINEL-SL-MID
SL_MID_DEF="^[[:space:]]*MID=.*·"                                                  # SENTINEL-SL-MIDDEF
SL_MARK='^[[:space:]]*(#|//) summary-lint: dynamic [^ ]'
SL_COMMENT='^[[:space:]]*(#|//)'                                                   # SENTINEL-SL-COMMENT

sl_forms() {
  cat <<'EOF'
forms recognised (on a non-comment line, comment = leading # or //; the emitter starts right after an opening quote/backtick/\n
  and ends right before a closing quote/\n; single spaces; each <n> is ONE token: $v ${v} $((expr)) %d %s {v} or digits):
  == <n> passed · <n> failed ==          literal U+00B7 (bash echo/printf, python print(f"..."), JS console.log template)
  == <n> passed $MID <n> failed ==       also ${MID}; accepted only when the file assigns MID='·' on a code line
  == <n> passed %s <n> failed ==         printf with the separator as an argument; same MID-assignment requirement
  an explicit `# summary-lint: dynamic <reason>` marker (a reason is required) exempts a file whose summary is computed elsewhere
forms NOT recognised (known limits): a summary built from fragments over several lines, an emitter reached only through
  a sourced library without the marker, a fixture-generating line standing in for a real emitter, LAST-line position
  and runtime reachability (run-all.sh owns those); MID='·' is accepted ANYWHERE in the file's code lines, not proven to
  be the MID the emitter reads; block comments (/* */, : '...' heredocs) are scanned as code, so an emitter inside one counts
EOF
}

n_viol=0; n_exempt=0; n_scanned=0

# sl_scan_file FILE — classify one file; returns 0 ok/exempt/violation (counted), 2 operational failure.
sl_scan_file() {
  local f="$1" code rc n hit mark
  [ -f "$f" ] && [ -r "$f" ] || { echo "ERROR: unreadable or absent file: $f" >&2; return 2; }
  code="$(grep -vE -- "$SL_COMMENT" "$f")"; rc=$?
  if [ "$rc" -gt 1 ]; then echo "ERROR: grep failed (rc $rc) on $f" >&2; return 2; fi
  # SENTINEL-SL-CODE-LINES
  grep -qE '[^[:space:]]' <<<"$code" || { echo "ERROR: no code lines in $f (empty or comment-only: nothing was inspected)" >&2; return 2; }
  n_scanned=$((n_scanned+1))
  if grep -qE -- "$SL_LIT" <<<"$code"; then return 0; fi
  if grep -qE -- "$SL_MID" <<<"$code" && grep -qE -- "$SL_MID_DEF" <<<"$code"; then return 0; fi  # SENTINEL-SL-MIDCHECK
  mark="$(grep -E -- "$SL_MARK" "$f" | head -1)"
  if [ -n "$mark" ]; then   # SENTINEL-SL-EXEMPT
    n_exempt=$((n_exempt+1)); printf '  EXEMPT %s: %s\n' "$f" "${mark#*dynamic }"; return 0
  fi
  n_viol=$((n_viol+1))
  hit="$(grep -nE -- 'passed.*failed|pass=|fail=' <<<"$code" | head -1)"
  if grep -qE -- "$SL_MID" <<<"$code"; then
    printf '  VIOLATION %s: summary uses a $MID/%%s separator but the file never assigns MID='"'"'·'"'"' on a code line\n' "$f"
  elif [ -n "$hit" ]; then
    printf '  VIOLATION %s: no exact `== N passed · M failed ==` emitter; nearest summary-like line: %s\n' "$f" "${hit:0:110}"
  else
    printf '  VIOLATION %s: no `== N passed · M failed ==` emitter and no summary-like line at all\n' "$f"
  fi
  return 0
}

sl_report() {
  echo "files scanned: $n_scanned"
  sl_forms
  echo "violations: $n_viol"
  echo "exempt sites: $n_exempt"
}

sl_main() {
  local f
  [ "$#" -gt 0 ] || { echo "ERROR: no files to scan" >&2; return 2; }   # SENTINEL-SL-ZERO-FILES
  for f in "$@"; do sl_scan_file "$f" || return 2; done
  sl_report
  [ "$n_viol" -eq 0 ]
}

sl_tree() {
  local root="$1" c d n f g
  local -a files=() lines=()
  [ -d "$root" ] || { echo "ERROR: absent corpus root: $root" >&2; return 2; }   # SENTINEL-SL-ABSENT-ROOT
  # corpus declaration: <dir relative to the root>:<glob suffix>
  for c in toolbelt/tests:sh toolbelt/tests:mjs install/tests:sh install/tests:mjs; do
    d="$root/${c%%:*}"
    [ -d "$d" ] || { echo "ERROR: absent corpus directory: ${c%%:*}/ (expected $d)" >&2; return 2; }
    n=0
    for f in "$d"/*.test."${c##*:}"; do
      [ -f "$f" ] || continue
      files+=("$f"); n=$((n+1))
    done
    # An empty corpus is an error only for the *.sh corpora (the *.mjs ones may legitimately be empty, but
    # are still counted so a vanished corpus shows as 0 rather than disappearing from the report).
    if [ "$n" -eq 0 ] && [ "${c##*:}" = sh ]; then
      echo "ERROR: empty corpus (no *.test.sh files): ${c%%:*}/" >&2; return 2   # SENTINEL-SL-EMPTY-CORPUS
    fi
    lines+=("corpus ${c%%:*}/*.test.${c##*:}: $n file(s)")
  done
  printf '%s\n' "${lines[@]}"
  g=0
  sl_main "${files[@]}" | sed "s|$root/||"; g=${PIPESTATUS[0]}
  return "$g"
}

case "${1:-}" in
  --scan) shift; sl_main "$@"; exit $? ;;
  --scan-tree) shift; sl_tree "${1:-}"; exit $? ;;
esac

# ---------------------------------------------------------------------------------------------------------
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== summary-line-lint.test.sh =="

[ -f "$SELF" ] || { echo "FATAL: cannot locate $SELF" >&2; exit 2; }
[ -d "$FIX" ] || { echo "FATAL: fixture dir missing: $FIX" >&2; exit 2; }

# scan_case LABEL EXPECT_RC EXPECT_VIOLATIONS EXPECT_EXEMPT FILE...
# Runs the lint as a child process so a mutant copy of this suite can be dropped in for $SELF.
scan_case() {
  local label="$1" erc="$2" ev="$3" ee="$4"; shift 4
  local out rc gv ge
  out="$(bash "$SELF" --scan "$@" 2>&1)"; rc=$?
  gv="$(sed -n 's/^violations: //p' <<<"$out")"
  ge="$(sed -n 's/^exempt sites: //p' <<<"$out")"
  if [ "$rc" != "$erc" ]; then no "$label: exit $rc, expected $erc — $(head -c 300 <<<"$out" | tr '\n' ' ')"
  elif [ "$gv" != "$ev" ] || [ "$ge" != "$ee" ]; then no "$label: violations='$gv' exempt='$ge', expected $ev / $ee"
  else ok "$label"; fi
}

# --- compliant forms ---------------------------------------------------------------------------------------
for f in ok-token-forms ok-literal ok-mid ok-printf-mid ok-js ok-first-line ok-printf ok-no-trailing-newline ok-with-marker; do
  scan_case "compliant form passes: $f" 0 0 0 "$FIX/$f.txt"
done
scan_case "marker exempts a file with no emitter (reason present)" 0 0 1 "$FIX/exempt.txt"
# --- non-compliant forms -----------------------------------------------------------------------------------
for f in wrong-prefix wrong-indent wrong-inner-spaces wrong-trailing missing wrong-comma wrong-kv wrong-separator wrong-spacing wrong-no-equals comment-only mid-undefined mid-in-comment exempt-no-reason; do
  scan_case "non-compliant is flagged: $f" 1 1 0 "$FIX/$f.txt"
done
# Position edges (CLAUDE.md §7): the violation in FIRST, MIDDLE and LAST position of a list, and a lone file.
scan_case "list edge: violation first" 1 1 0 "$FIX/missing.txt" "$FIX/ok-literal.txt" "$FIX/ok-js.txt"
scan_case "list edge: violation middle" 1 1 0 "$FIX/ok-literal.txt" "$FIX/wrong-kv.txt" "$FIX/ok-js.txt"
scan_case "list edge: violation last" 1 1 0 "$FIX/ok-literal.txt" "$FIX/ok-js.txt" "$FIX/wrong-comma.txt"
scan_case "list edge: single non-compliant file" 1 1 0 "$FIX/wrong-kv.txt"
scan_case "list edge: every file non-compliant (3 reported)" 1 3 0 "$FIX/missing.txt" "$FIX/wrong-kv.txt" "$FIX/wrong-comma.txt"
# The report names the nearest summary-like line so the author sees what to change.
out="$(bash "$SELF" --scan "$FIX/wrong-comma.txt" 2>&1)"
if grep -q 'nearest summary-like line: .*passed, ' <<<"$out"; then ok "violation message quotes the offending line"; else no "violation message lacks the nearest line: $out"; fi

# --- anti-silent-zero: operational failures are rc 2, never a pass -----------------------------------------
out="$(bash "$SELF" --scan 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'no files to scan' <<<"$out"; then ok "zero files → exit 2 with a 'no files' message"
else no "zero files: exit $rc, output: $(head -c 200 <<<"$out")"; fi
out="$(bash "$SELF" --scan "$FIX/does-not-exist.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then ok "absent input file → exit 2"; else no "absent input file: exit $rc"; fi
out="$(bash "$SELF" --scan "$FIX/empty.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'no code lines' <<<"$out"; then ok "an empty file → exit 2, never a silent pass"
else no "empty file: exit $rc, output: $(head -c 200 <<<"$out")"; fi
out="$(bash "$SELF" --scan "$FIX/comments-only-file.txt" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'no code lines' <<<"$out"; then ok "a comment-only file → exit 2"
else no "comment-only file: exit $rc, output: $(head -c 200 <<<"$out")"; fi
out="$(bash "$SELF" --scan-tree "$FIX/no-such-root" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'absent corpus' <<<"$out"; then ok "absent corpus root → exit 2"
else no "absent corpus root: exit $rc, output: $(head -c 200 <<<"$out")"; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root/toolbelt/tests" "$TMP/root/install/tests"
out="$(bash "$SELF" --scan-tree "$TMP/root" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'empty corpus' <<<"$out"; then ok "a corpus dir with no *.test.sh files → exit 2"
else no "empty corpus dir: exit $rc, output: $(head -c 200 <<<"$out")"; fi
# One corpus empty while the other holds a compliant suite must still be exit 2 (the empty one may not hide).
for half in toolbelt install; do
  rm -rf "$TMP/half"; mkdir -p "$TMP/half/toolbelt/tests" "$TMP/half/install/tests"
  other=install; [ "$half" = install ] && other=toolbelt
  cp "$FIX/ok-literal.txt" "$TMP/half/$half/tests/a.test.sh"
  out="$(bash "$SELF" --scan-tree "$TMP/half" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && grep -q "empty corpus.*$other/tests" <<<"$out"; then ok "only $half/tests populated, $other/tests empty → exit 2"
  else no "only $half populated: exit $rc, output: $(head -c 200 <<<"$out")"; fi
done
cp "$FIX/ok-literal.txt" "$TMP/root/toolbelt/tests/a.test.sh"
cp "$FIX/missing.txt" "$TMP/root/install/tests/b.test.sh"
out="$(bash "$SELF" --scan-tree "$TMP/root" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'VIOLATION install/tests/b.test.sh' <<<"$out" && grep -q 'corpus install/tests/\*.test.mjs: 0' <<<"$out"; then
  ok "tree mode: violation named by corpus-relative path; empty .mjs corpus reported as 0, not hidden"
else no "tree mode: exit $rc, output: $(head -c 400 <<<"$out")"; fi

# --- the REAL tree -----------------------------------------------------------------------------------------
out="$(bash "$SELF" --scan-tree "$HERE/../.." 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^violations: 0$' <<<"$out"; then ok "REAL TREE: 0 violations across the declared corpora"
else no "REAL TREE lint failed (exit $rc): $(grep -E 'ERROR|VIOLATION' <<<"$out" | head -20 | tr '\n' ';')"; fi
for pat in '^corpus toolbelt/tests/\*\.test\.sh: [1-9]' '^corpus install/tests/\*\.test\.sh: [1-9]' '^files scanned: [1-9]' '^forms recognised' '^forms NOT recognised' '^exempt sites: [0-9]'; do
  if grep -qE -- "$pat" <<<"$out"; then ok "report prints: $pat"; else no "report is missing: $pat"; fi
done
printf '%s\n' "$out" | sed -n '/^corpus /p;/^files scanned/p;/^violations:/p;/^exempt sites:/,$p'

# ---- Teeth (mutation proof) -------------------------------------------------
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2
mk_sed() {
  local out="$2"
  mkdir -p "$(dirname "$out")"
  mutant_chain_or_count fail "$1" "$SELF" "$out" "${@:3}" || return 1
}
tooth() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

if [ "${1:-}" = "--prove-teeth" ]; then
  MUT="$(mktemp -d)"
  M='summary-line-lint.test.sh'
  echo "-- teeth: each detector facet must be load-bearing --"

  # Tooth 1: the literal pattern accepts any wording → `N passed, M failed` reads as compliant.
  mk_sed "teeth lit" "$MUT/lit/$M" "s/^SL_LIT=.*/SL_LIT='passed.*failed'/" \
    && tooth "teeth lit: loose pattern → a non-run-all format passes" 1 0 "$MUT/lit/$M" \
         --good-has 'violations: 1' --bad-has 'violations: 0' -- bash @SUT@ --scan "$FIX/wrong-comma.txt"

  # Tooth 2: comment filter dropped → an emitter that only lives in a comment counts.
  mk_sed "teeth comment" "$MUT/comment/$M" "s/^SL_COMMENT='[^']*'/SL_COMMENT='^\$a'/" \
    && tooth "teeth comment: comments scanned as code → commented-out emitter passes" 1 0 "$MUT/comment/$M" \
         --good-has 'violations: 1' --bad-has 'violations: 0' -- bash @SUT@ --scan "$FIX/comment-only.txt"

  # Tooth 3: MID-assignment requirement dropped → a $MID emitter with no definition passes.
  mk_sed "teeth midcheck" "$MUT/mid/$M" '/# SENTINEL-SL-MIDCHECK$/ s/ && grep -qE -- "\$SL_MID_DEF" <<<"\$code"//' \
    && tooth "teeth midcheck: MID definition not required → undefined \$MID passes" 1 0 "$MUT/mid/$M" \
         --good-has 'violations: 1' --bad-has 'violations: 0' -- bash @SUT@ --scan "$FIX/mid-undefined.txt"

  # Tooth 4: the exemption is applied without reading it → no-op check: marker ignored.
  mk_sed "teeth exempt" "$MUT/exempt/$M" '/# SENTINEL-SL-EXEMPT$/ s/if \[ -n "\$mark" \]/if false/' \
    && tooth "teeth exempt: marker ignored → a declared dynamic suite is reported as a violation" 0 1 "$MUT/exempt/$M" \
         --good-has 'exempt sites: 1' --bad-has 'violations: 1' --bad-lacks 'exempt sites: 1' -- bash @SUT@ --scan "$FIX/exempt.txt"

  # Tooth 5: zero-files guard removed.
  mk_sed "teeth zero-files" "$MUT/zero/$M" '/# SENTINEL-SL-ZERO-FILES$/ s/.*/  :/' \
    && tooth "teeth zero-files: guard removed → the 'no files' message is gone" 2 0 "$MUT/zero/$M" \
         --good-has 'no files to scan' --bad-lacks 'no files to scan' -- bash @SUT@ --scan

  # Tooth 6: no-code-lines guard removed → an empty file reads as a clean pass.
  mk_sed "teeth code-lines" "$MUT/code/$M" '/# SENTINEL-SL-CODE-LINES$/{n;s/.*/  :/}' \
    && tooth "teeth code-lines: guard removed → an empty file passes silently" 2 1 "$MUT/code/$M" \
         --good-has 'no code lines' --bad-lacks 'no code lines' -- bash @SUT@ --scan "$FIX/empty.txt"

  # Tooth 7: empty-corpus guard removed.
  mk_sed "teeth empty-corpus" "$MUT/empty/$M" '/# SENTINEL-SL-EMPTY-CORPUS$/ s/.*/      :/' \
    && tooth "teeth empty-corpus: guard removed → one empty corpus beside a compliant one passes silently" 2 0 "$MUT/empty/$M" \
         --good-has 'empty corpus' --bad-has 'violations: 0' --bad-lacks 'empty corpus' -- bash -c 'rm -rf "$1"; mkdir -p "$1/toolbelt/tests" "$1/install/tests"; cp "$2" "$1/install/tests/a.test.sh"; bash "$0" --scan-tree "$1"' @SUT@ "$TMP/half-teeth" "$FIX/ok-literal.txt"

  rm -rf "$MUT"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

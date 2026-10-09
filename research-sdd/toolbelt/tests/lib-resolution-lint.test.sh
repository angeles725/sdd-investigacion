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
# EXCLUDED: toolbelt/tests/ and install/tests/ — test suites are launched by path from run-all.sh / a developer and
# only locate their own fixtures; 190+ of them use `dirname "$0"` and none is a PATH-resolved entry point.
#
# Exemption is EXPLICIT: a `# lib-resolution-ok: <reason>` comment on the logical line (the last physical line of a
# backslash continuation) marks a DELIBERATE mention (pattern literals in a scanner). A marker without a reason
# does not exempt. No path-based blanket exemption exists.
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
forms recognised (in code lines only: comment-only lines skipped, backslash continuations joined first):
  F1  dirname [--] "$0" | $0 | "${0}" | ${0}                    (also inside $(cd "$(dirname "$0")/.." ...))
  F2  ${0%/*} | ${0%%/*} | any ${0%...} suffix strip
  F3  readlink | realpath with $0 / ${0} among its arguments
  F4  alias: V="$0" | V=$0 | V="${0}", then dirname [--] "$V" | ${V%...} | readlink/realpath "$V" later in the file
forms NOT recognised (known limits): ${BASH_SOURCE[0]:-$0} defaults, $0 smuggled through eval/xargs/sh -c, an alias
  passed through a function argument, `$0` read by `sed ... "$0"` (display only), usage/message uses of $0 and
  ${0##*/} / basename "$0" (display only), awk's $0
exempt: a trailing `# lib-resolution-ok: <reason>` on the logical line
EOF
}

# Scanner. Output per violation: FILE:LINE:FORM: text ; summary lines at END.
LRL_AWK="$(cat <<'AWKEOF'
function flush_logical(   code, line, v, k, hit, raw, fname) {
  if (logical == "") return
  raw = logical; line = lstart; fname = lfile; logical = ""
  ncode++
  if (match(raw, /# lib-resolution-ok:[ \t]+[^ \t]/)) { nexempt++; return }   # SENTINEL-LRL-MARKER
  code = raw
  sub(/^[ \t]+/, "", code)
  if (code ~ /^#/) { ncode--; return }
  sub(/[ \t]#[ \t].*$/, "", code)          # SENTINEL-LRL-COMMENT
  hit = ""
  if (code ~ /dirname[ \t]+(--[ \t]+)?["']?\$\{?0\}?(["' \t;)]|$)/) hit = "F1"   # SENTINEL-LRL-F1
  else if (code ~ /\$\{0%/) hit = "F2"   # SENTINEL-LRL-F2
  else if (code ~ /(readlink|realpath)[^|;&)]*\$\{?0\}?(["' \t;)]|$)/) hit = "F3"   # SENTINEL-LRL-F3
  else {
    for (k in alias) {
      if (code ~ ("dirname[ \t]+(--[ \t]+)?[\"']?\\$\\{?" k "\\}?([\"' \t;)]|$)") \
          || code ~ ("\\$\\{" k "%") \
          || code ~ ("(readlink|realpath)[^|;&)]*\\$\\{?" k "\\}?([\"' \t;)]|$)")) { hit = "F4"; break }
    }
  }
  if (hit != "") { nviol++; printf "%s:%d:%s: %s\n", fname, line, hit, substr(raw, 1, 160); fv[hit]++ }
  # alias assignment AFTER the use check so `V="$0"; dirname "$V"` on one line is still seen next line
  if (match(code, /(^|[ \t;{(])(local[ \t]+|export[ \t]+|readonly[ \t]+|declare[ \t]+)?[A-Za-z_][A-Za-z_0-9]*=["']?\$\{?0\}?["']?([ \t;)]|$)/)) {
    v = substr(code, RSTART, RLENGTH)
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
  lrl_forms
  lrl_scan "${files[@]}"
}

case "${1:-}" in
  --scan) shift; lrl_scan "$@"; exit $? ;;
  --scan-tree) shift; [ "$#" -eq 1 ] || { echo "usage: $0 --scan-tree RESEARCH_DIR" >&2; exit 2; }; lrl_tree "$1"; exit $? ;;
esac

pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass + 1)); }
no() { echo "  FAIL  $1"; fail=$((fail + 1)); }
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT

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
planted_run() {   # planted_run SCRIPT_DIR NAME -> 0 when the marker was NOT created
  rm -f "$mark"
  ( cd "$planted" && RSDD_LR_MARK="$mark" HOME="$TMP/home" RESEARCH_HOME="$TMP/rh" PATH="$1:$PATH" \
      timeout 30 bash "$2" </dev/null >"$TMP/run.out" 2>&1 )
  [ ! -e "$mark" ]
}
beh_list="$FIX/planted-lib-scripts.txt"
if [ ! -s "$beh_list" ]; then no "behavioural fixture list missing or empty: $beh_list"
else
  nrun=0; nbad=0; badnames=""
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    nrun=$((nrun + 1))
    dir="$TB"; case "$line" in install/*) dir="$TB/../install"; line="${line#install/}" ;; esac
    if ! planted_run "$dir" "$line"; then nbad=$((nbad + 1)); badnames="$badnames $line"; fi
  done < "$beh_list"
  if [ "$nrun" -gt 0 ] && [ "$nbad" -eq 0 ]; then ok "planted lib/ in cwd was never sourced by any of $nrun scripts"
  else no "planted lib/ executed ($nbad of $nrun scripts):$badnames"; fi
fi
# Symlink invocation: the real lib/ must be found (not the cwd's, not 'missing') through a symlink in another dir.
mkdir -p "$TMP/linkbin"
for name in sweep-retros.sh verify-registry.sh sweep-audits-hook.sh verify-state.sh; do
  ln -sf "$TB/$name" "$TMP/linkbin/$name"
  rm -f "$mark"
  ( cd "$planted" && RSDD_LR_MARK="$mark" HOME="$TMP/home" RESEARCH_HOME="$TMP/rh" PATH="$TMP/linkbin:$PATH" \
      timeout 30 bash "$name" </dev/null >"$TMP/link.out" 2>&1 )
  if [ ! -e "$mark" ] && ! grep -qE 'cannot find helper|failed to define|missing beside|No such file or directory' "$TMP/link.out"; then
    ok "symlink invocation of $name finds its real lib/ and ignores the cwd's"
  else no "symlink invocation of $name: marker=$([ -e "$mark" ] && echo yes || echo no) out=$(head -c 200 "$TMP/link.out" | tr '\n' ' ')"; fi
done
# A relative symlink (target relative to the link's directory) must resolve too.
mkdir -p "$TMP/rel/bin"
ln -sf "../tb/sweep-audits-hook.sh" "$TMP/rel/bin/sweep-audits-hook.sh"
ln -sfn "$TB" "$TMP/rel/tb"
( cd "$planted" && RSDD_LR_MARK="$mark" HOME="$TMP/home" RESEARCH_HOME="$TMP/rh" PATH="$TMP/rel/bin:$PATH" \
    timeout 30 bash sweep-audits-hook.sh </dev/null >"$TMP/rel.out" 2>&1 )
if ! grep -qE 'missing beside|cannot find' "$TMP/rel.out"; then ok "relative symlink resolves the real lib/"; else no "relative symlink: $(head -c 200 "$TMP/rel.out")"; fi

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
  mk_sed "teeth marker-reason" "$MUT/marker/$M" '/SENTINEL-LRL-MARKER$/ s/:\[ \\t\]+\[^ \\t\]\//:\//' \
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
    else ok "teeth behavioural: a \$0-based mutant of a fixed script executes the planted lib → the behavioural check goes red"; fi
  else no "teeth behavioural: mutant could not be built (no \$_RSDD_SELF assignment found in sweep-audits-hook.sh)"; fi

  rm -rf "$MUT"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

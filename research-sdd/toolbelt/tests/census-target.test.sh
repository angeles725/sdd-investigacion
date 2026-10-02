#!/usr/bin/env bash
# census-target.test.sh — characterization harness for census-target.sh (METHODOLOGY §6,
# BOOTSTRAP step a2). The census is a pure information tool: it walks all files under a dir,
# groups by extension, and stars (*) any type that meets the audit threshold (>=N files or
# >=M MB). This suite pins: (a) exit codes, (b) that starred types appear for threshold-
# crossing inputs, (c) that sub-threshold types are NOT starred, (d) case-insensitive
# extension folding. The mutation tooth inverts the threshold comparison so every type is
# starred regardless of count, then asserts a sub-threshold type is STILL not starred after
# the flag is set — proving the guard is load-bearing.
#
# Usage: census-target.test.sh                (run the suite)
#        census-target.test.sh --prove-teeth  (run suite + mutation tooth)
# Exit: 0 = every assertion held · 1 = regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../census-target.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"
# MUT holds every mutant, OUTSIDE the live tree (kit #943/#1299: a mutant written beside the SUT
# lands in the tracked tree).  The two skip-accounting mutants are mutants of THIS test file, which
# finds the SUT as "$HERE/../census-target.sh"; they therefore live in a mirrored layout —
# "$MUT/tests/<mutant>" next to a verbatim copy "$MUT/census-target.sh" — so $SUT stays reachable.
MUT="$(mktemp -d)"; mkdir -p "$MUT/tests"
trap 'rm -rf "$TMP" "$MUT"' EXIT
pass=0; fail=0; skipped=0
ok()   { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no()   { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
skip() { printf '  SKIP  %-60s %s\n' "$1" "${2:-}"; skipped=$((skipped+1)); }

# _IS_ROOT: always derived from id -u for ordinary invocations.
# A lone environment variable cannot influence this.
# The --prove-teeth block forces the root path only via TWO combined signals:
#   (1) the explicit internal argument --_teeth-probe-root
#   (2) the namespaced env marker _CENSUS_TEETH_PROBE="census-target.test.sh"
# Neither signal alone is sufficient.  Coverage is a function of the machine,
# not of what happens to be in the environment.
_IS_ROOT=0
[ "$(id -u)" = 0 ] && _IS_ROOT=1
if [ "${1:-}" = "--_teeth-probe-root" ] \
   && [ "${_CENSUS_TEETH_PROBE:-}" = "census-target.test.sh" ]; then
  _IS_ROOT=1
fi

run()  { bash "$SUT" "$@" 2>&1; }
code() { bash "$SUT" "$@" >/dev/null 2>&1; echo $?; }

# --- mutation-control helpers (kit issues #943, #1299) -------------------------------------------
# Mutants are built by lib/mutant.sh, which REFUSES an empty, byte-identical, syntax-broken or
# live-tree mutant; each control then asserts the GOOD verdict on the original AND the SPECIFIC BAD
# verdict on the mutant.
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
# mk_sed LABEL OUT EXPR...  build OUT from $MK_ORIG (default $SUT), one sed stage per EXPR; every
# stage must change the original on its own (a dead stage hides behind a live one otherwise).
mk_sed() {
  local label="$1" out="$2" e rc err; shift 2
  local orig="${MK_ORIG:-$SUT}"; local -a args=()
  for e in "$@"; do
    if sed -e "$e" "$orig" | cmp -s - "$orig"; then
      no "$label: sed stage matches nothing in the original (silent no-op)" "[$e]"; return 1
    fi
    args+=(-e "$e")
  done
  err="$(mutant_sed "$orig" "$out" "${args[@]}" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || { no "$label: mutant refused by lib/mutant.sh (rc=$rc)" "$err"; return 1; }
}
# mk_verify LABEL OUT  same refusals for a mutant built another way (bash string surgery).
mk_verify() {
  local label="$1" out="$2" rc err
  err="$(mutant_verify "${MK_ORIG:-$SUT}" "$out" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || { no "$label: mutant refused by lib/mutant.sh (rc=$rc)" "$err"; return 1; }
}
# tooth LABEL GOOD_RC BAD_RC MUTANT [--good-has RE] [--good-lacks RE] [--bad-has RE] [--bad-lacks RE] -- ARGV...
# Runs ARGV on the original ('@SUT@' → $SUT) then on the mutant; PASS only when the original exits
# GOOD_RC with the good-side output conditions AND the mutant exits exactly BAD_RC with the bad-side
# output conditions: a crashing or syntax-broken mutant cannot read as teeth.
tooth() {
  local label="$1" grc="$2" brc="$3" mut="$4" ghas="" glack="" bhas="" black="" a gout mout grc_a mrc_a why=""; shift 4
  while [ "${1:-}" != -- ]; do
    case "${1:-}" in
      --good-has) ghas="$2" ;; --good-lacks) glack="$2" ;; --bad-has) bhas="$2" ;; --bad-lacks) black="$2" ;;
      *) no "$label: tooth() bad option '${1:-}'"; return 1 ;;
    esac; shift 2
  done; shift
  local -a gc=() mc=()
  for a in "$@"; do gc+=("${a//@SUT@/"$SUT"}"); mc+=("${a//@SUT@/"$mut"}"); done
  gout="$("${gc[@]}" 2>&1)"; grc_a=$?
  mout="$("${mc[@]}" 2>&1)"; mrc_a=$?
  [ "$grc_a" = "$grc" ] || why="original rc=$grc_a (want $grc)"
  if [ -n "$ghas" ] && ! grep -qE -- "$ghas" <<<"$gout"; then why="$why; original output lacks /$ghas/"; fi
  if [ -n "$glack" ] && grep -qE -- "$glack" <<<"$gout"; then why="$why; original output matches /$glack/"; fi
  [ "$mrc_a" = "$brc" ] || why="$why; mutant rc=$mrc_a (want $brc)"
  if [ -n "$bhas" ] && ! grep -qE -- "$bhas" <<<"$mout"; then why="$why; mutant output lacks /$bhas/"; fi
  if [ -n "$black" ] && grep -qE -- "$black" <<<"$mout"; then why="$why; mutant output still matches /$black/"; fi
  if [ -z "$why" ]; then ok "$label" "[original rc=$grc → mutant rc=$brc]"
  else no "$label — THEATER" "$why"; fi
}

echo "== census-target.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# 1 — no arg → exit 2 (bad args).
[ "$(code)" = 2 ] && ok "no arg → exit 2" || no "no arg: got $(code) (want 2)"

# 2 — non-directory arg → exit 2.
[ "$(code "$TMP/does-not-exist")" = 2 ] \
  && ok "non-directory arg → exit 2" \
  || no "non-dir: got $(code "$TMP/does-not-exist") (want 2)"

# 3 — empty directory → exit 0.
d="$TMP/empty"; mkdir -p "$d"
[ "$(code "$d")" = 0 ] && ok "empty dir → exit 0" || no "empty dir: exit $(code "$d") (want 0)"

# 4 — valid dir → exit 0.
d="$TMP/valid"; mkdir -p "$d"
printf 'x\n' > "$d/a.txt"
[ "$(code "$d")" = 0 ] && ok "valid dir with files → exit 0" || no "valid: exit $(code "$d") (want 0)"

# 5 — STARRED for threshold-crossing count (>=5 files of same extension).
# Create 5 .pdf files. Default threshold is count=5, so exactly 5 should be starred.
d="$TMP/threshold-count"; mkdir -p "$d"
for i in 1 2 3 4 5; do printf 'x\n' > "$d/doc${i}.pdf"; done
out="$(run "$d")"
if grep -qE 'pdf.*\*' <<<"$out"; then
  ok "5 .pdf files → pdf starred (*) at threshold count=5" "(found '*' on pdf line)"
else
  no "5 .pdf files → pdf should be starred" "$(echo "$out" | grep -i pdf || echo '(pdf line absent)')"
fi

# 6 — NOT starred below threshold (4 files < default count=5).
d="$TMP/below-count"; mkdir -p "$d"
for i in 1 2 3 4; do printf 'x\n' > "$d/doc${i}.pdf"; done
out="$(run "$d")"
if ! grep -qE 'pdf.*\*' <<<"$out"; then
  ok "4 .pdf files → pdf NOT starred (below threshold)" "(no '*' on pdf line)"
else
  no "4 .pdf files → pdf should NOT be starred" "$(echo "$out" | grep -i pdf | head -1)"
fi

# 7 — STARRED for custom threshold-count override (--threshold-count 3).
d="$TMP/custom-count"; mkdir -p "$d"
for i in 1 2 3; do printf 'x\n' > "$d/report${i}.docx"; done
out="$(run "$d" --threshold-count 3)"
if grep -qE 'docx.*\*' <<<"$out"; then
  ok "--threshold-count 3: 3 .docx files → starred" "(threshold override honored)"
else
  no "--threshold-count 3: 3 .docx files should be starred" "$(echo "$out" | grep -i docx || echo '(docx line absent)')"
fi

# 8 — NOT starred when count=3 with threshold=4.
d="$TMP/under-custom"; mkdir -p "$d"
for i in 1 2 3; do printf 'x\n' > "$d/report${i}.docx"; done
out="$(run "$d" --threshold-count 4)"
if ! grep -qE 'docx.*\*' <<<"$out"; then
  ok "--threshold-count 4: 3 .docx files → NOT starred (below custom threshold)" "(no '*' on docx)"
else
  no "--threshold-count 4: 3 .docx files should NOT be starred" "$(echo "$out" | grep -i docx | head -1)"
fi

# 9 — Case-insensitive extension folding: .PDF and .pdf counted together.
d="$TMP/case-fold"; mkdir -p "$d"
for i in 1 2 3; do printf 'x\n' > "$d/doc${i}.PDF"; done
for i in 4 5;   do printf 'x\n' > "$d/doc${i}.pdf"; done
out="$(run "$d")"
# 5 files total under the 'pdf' key → must be starred; only ONE pdf line (not PDF + pdf).
pdf_lines="$(echo "$out" | grep -iE '^\s+pdf\s' | wc -l | tr -d ' ')"
if grep -qE 'pdf.*\*' <<<"$out" && [ "$pdf_lines" = "1" ]; then
  ok "case-fold: .PDF + .pdf merged → single pdf line, starred" "(${pdf_lines} pdf line(s))"
else
  no "case-fold: expected 1 starred pdf line" "pdf_lines=$pdf_lines; out=$(echo "$out" | grep -iE 'pdf' | head -2 | tr '\n' '|')"
fi

# 10 — Files WITHOUT extension reported as '(no ext)'.
d="$TMP/no-ext"; mkdir -p "$d"
printf 'x\n' > "$d/Makefile"
printf 'x\n' > "$d/README"
out="$(run "$d")"
if grep -q '(no ext)' <<<"$out"; then
  ok "files without extension → '(no ext)' group" "(no-ext line present)"
else
  no "files without extension: expected '(no ext)' group" "$(echo "$out" | head -5 | tr '\n' '|')"
fi

# 11 — .git directory excluded: git objects must NOT inflate the '(no ext)' count.
# census-target.sh prints a histogram (count/ext/MB) — it NEVER prints filenames.
# Asserting that the filename 'abc123' is absent was pure theater; the real guard is the
# -not -path '*/.git/*' find flag. With the exclusion active, the only no-extension file
# (the .git object) is skipped → '(no ext)' row must be ABSENT. If the exclusion is
# removed the object IS counted and '(no ext)' appears. The prove-teeth tooth confirms this.
d="$TMP/with-git"; mkdir -p "$d/.git/objects"
printf 'x\n' > "$d/.git/objects/abc123"  # no-extension file inside .git — must be excluded
printf 'x\n' > "$d/real.txt"              # .txt extension — appears in histogram, not (no ext)
out="$(run "$d")"
if ! grep -qF '(no ext)' <<<"$out"; then
  ok "11 .git/ excluded: '(no ext)' row absent (only no-ext file is the .git object)" \
     "(git exclusion works)"
else
  no "11 .git/ not excluded: '(no ext)' row present — git object counted in histogram" \
     "$(echo "$out" | grep '(no ext)')"
fi

# ---------------------------------------------------------------------------
# 12 — STARRED via MB threshold: 1 file exactly 1MB (= THRESH_MB_BYTES), count=1 < threshold=5.
# The MB arm must fire independently of the count arm.
d="$TMP/threshold-mb"; mkdir -p "$d"
dd if=/dev/zero of="$d/archive.iso" bs=1048576 count=1 2>/dev/null
out="$(run "$d")"
if grep -qE 'iso[[:space:]].*\*' <<<"$out"; then
  ok "12 1 file exactly 1MB → iso starred (*) via MB threshold arm" "(count=1 < 5; MB arm fires)"
else
  no "12 1 file 1MB → iso should be starred via MB arm" \
     "$(echo "$out" | grep -i iso || echo '(iso line absent)')"
fi

# 13 — NOT starred below both thresholds: 1 tiny file (count < 5, bytes << 1MB).
d="$TMP/below-both"; mkdir -p "$d"
printf 'hello\n' > "$d/tiny.iso"
out="$(run "$d")"
if ! grep -qE 'iso[[:space:]].*\*' <<<"$out"; then
  ok "13 1 tiny file → iso NOT starred (below both count and MB thresholds)" "(no '*' on iso)"
else
  no "13 1 tiny file → iso should NOT be starred" \
     "$(echo "$out" | grep -i iso | head -1)"
fi

# 14 — MB boundary: exactly 1MB − 1 byte (1048575 bytes) must NOT be starred via MB arm
# (count=1 < threshold=5, bytes strictly below THRESH_MB_BYTES=1048576).
d="$TMP/below-mb-boundary"; mkdir -p "$d"
dd if=/dev/zero of="$d/almost.bin" bs=1048575 count=1 2>/dev/null
out="$(run "$d")"
if ! grep -qE 'bin[[:space:]].*\*' <<<"$out"; then
  ok "14 1048575 bytes (1MB − 1 B) → NOT starred (strictly below 1MB threshold)" "(boundary below)"
else
  no "14 1048575 bytes: should NOT be starred (below 1MB)" \
     "$(echo "$out" | grep -i bin | head -1)"
fi

# 15 — Custom --threshold-mb 2: file of exactly 2MB → starred; below 2MB → not starred.
d="$TMP/custom-mb"; mkdir -p "$d"
dd if=/dev/zero of="$d/big.bin" bs=1048576 count=2 2>/dev/null   # 2MB exactly
out="$(run "$d" --threshold-mb 2)"
if grep -qE 'bin[[:space:]].*\*' <<<"$out"; then
  ok "15 --threshold-mb 2: exactly 2MB → starred at custom MB threshold" "(MB override honored)"
else
  no "15 --threshold-mb 2: 2MB file should be starred" \
     "$(echo "$out" | grep -i bin | head -1)"
fi

# 16 — UNREADABLE DIRECTORY must be REPORTED, never silently skipped.
# This is the tool's own founding failure re-entering through the back door: the census exists
# because 681 Access databases were never surfaced, and a `find … 2>/dev/null` cannot tell
# "nothing there" from "could not look". These corpora live on WSL2 /mnt paths with Windows
# ACLs, so unreadable subtrees are the normal case, not the exotic one. The census must print a
# WARNING naming how many paths it could not traverse, so an undercount is visible rather than
# indistinguishable from a clean census.
# Skipped under root, where chmod 000 does not deny traversal.
d="$TMP/unreadable"; mkdir -p "$d/open" "$d/locked"
printf 'x\n' > "$d/open/visible.txt"
printf 'x\n' > "$d/locked/hidden.mdb"
if [ "$_IS_ROOT" = 1 ]; then
  skip "16 unreadable dir warning — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory)"
else
  chmod 000 "$d/locked"
  out="$(run "$d")"; rcu=$?
  chmod 0755 "$d/locked" 2>/dev/null
  if [ "$rcu" = 0 ] && grep -qiE 'WARNING.*(unreadable|could not|permission)' <<<"$out"; then
    ok "16 unreadable subtree → WARNING printed, exit stays 0 (undercount is visible, not silent)"
  else
    no "16 unreadable subtree: exit=$rcu (want 0) / warning=$(grep -ciE 'WARNING.*(unreadable|could not|permission)' <<<"$out") :: $(echo "$out" | tr '\n' '|')"
  fi
fi

# 17 — Paths containing SPACES must be attributed to the right extension and size.
# Pins the size/path parsing contract independently of how sizes are collected, so a switch
# away from the per-file `stat` subprocess cannot silently corrupt the histogram.
d="$TMP/spacey"; mkdir -p "$d/a folder with spaces"
dd if=/dev/zero of="$d/a folder with spaces/big report.iso" bs=1048576 count=1 2>/dev/null
out="$(run "$d")"
if grep -qE 'iso[[:space:]]+1[[:space:]]+1\.0' <<<"$out" && grep -qE 'iso[[:space:]].*\*' <<<"$out"; then
  ok "17 path with spaces → 1 iso file at 1.0 MB, starred (size/path parsing intact)"
else
  no "17 spaces in path: expected 1 iso @ 1.0 MB starred" "$(echo "$out" | grep -i iso || echo '(iso line absent)')"
fi

# 18 — UNREADABLE DIRECTORY WARNING must appear on STDOUT, not only stderr.
# A researcher who runs `census-target.sh <target> > census.txt` or pastes the captured
# output into RESEARCH-STATE loses the WARNING if it only goes to stderr — the undercount
# becomes invisible at exactly the moment the census is archived and trusted. The fix must
# route the WARNING through stdout so it travels with the report body.
# Skipped under root, where chmod 000 does not deny traversal.
if [ "$_IS_ROOT" = 1 ]; then
  skip "18 WARNING on stdout — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory)"
else
  d="$TMP/unreadable-stdout"; mkdir -p "$d/open" "$d/locked"
  printf 'x\n' > "$d/open/visible.txt"
  printf 'x\n' > "$d/locked/hidden.mdb"
  chmod 000 "$d/locked"
  out="$(bash "$SUT" "$d" 2>/dev/null)"; rco=$?
  chmod 0755 "$d/locked" 2>/dev/null
  if [ "$rco" = 0 ] && grep -qiE 'WARNING.*(unreadable|could not|permission)' <<<"$out"; then
    ok "18 unreadable subtree → WARNING appears on STDOUT (travels with captured report, not orphaned on stderr)"
  else
    no "18 WARNING must appear on stdout (not only stderr): exit=$rco / stdout=$(echo "$out" | tr '\n' '|')"
  fi
fi

# ---------------------------------------------------------------------------
# TEETH: mutate the awk threshold comparison to make EVERY type starred, then assert a
# sub-threshold type (1 file, well below count=5) is STILL not starred on the original SUT.
# The mutant (flag=1 always) MUST star the sub-threshold type — proving the comparison
# in the SUT is the load-bearing guard, not decoration.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: force flag=1 in awk; sub-threshold type must be starred in mutant but not in SUT --"
  d="$TMP/teeth-dir"; mkdir -p "$d"
  printf 'x\n' > "$d/onlyone.xyz"   # 1 file — well below threshold=5

  # Original: exit 0 and the 1-file type is NOT starred. Mutant (flag always "*"): exit 0 and it IS.
  mutant="$MUT/census-target.MUTANT.sh"
  # Swap the conditional expression in the awk to always set flag="*"
  mk_sed "teeth" "$mutant" 's/flag = (cnt\[e\] >= tc + 0 || bytes\[e\] >= tm + 0) ? "\*" : ""/flag = "*"/' \
    && tooth "teeth: mutant (flag=1 always) stars the sub-threshold type; SUT does not (guard is load-bearing)" 0 0 "$mutant" \
         --good-lacks 'xyz.*\*' --bad-has 'xyz.*\*' -- bash @SUT@ "$d"

  # ---------------------------------------------------------------------------
  # SKIP-ACCOUNTING TEETH
  # Cases 16 and 18 emit skip() (not ok()) when chmod 000 does not deny
  # traversal, because the fixture cannot produce the locked-directory
  # condition under test.  The teeth prove:
  #   (a) the skip sites emit SKIP lines, not PASS lines;
  #   (b) the pass counter is untouched by each skip call;
  #   (c) re-routing either site back through ok() turns the control RED.
  #
  # Forcing mechanism: TWO combined signals are required — the explicit
  # internal argument --_teeth-probe-root AND the namespaced env marker
  # _CENSUS_TEETH_PROBE="census-target.test.sh".  A lone env variable
  # (_IS_ROOT=1 or any single marker) cannot trigger forcing.
  #
  # Root-only branch coverage: neither skip site can be entered in this run
  # (we are not root), so the accounting comes from the forced probe
  # sub-invocations below.  What remains unverified: that an actual root
  # process produces the same accounting — unobservable without being root.
  # The probe sub-invocation is the closest verifiable proxy.
  echo "-- skip-accounting: cases 16 and 18 must land in skipped, not pass --"

  # cnt_occ: count non-overlapping literal occurrences of needle in file.
  # Self-proved below with 0/1/2-on-one-line cases before any use.
  cnt_occ() {
    awk -v n="$1" \
      'BEGIN{c=0}{s=$0;while((p=index(s,n))>0){c++;s=substr(s,p+length(n))}}END{print c}' \
      "$2"
  }
  printf 'no match\n'                              > "$TMP/cnt-proof-skip.txt"
  _cp0="$(cnt_occ "SKIPX16" "$TMP/cnt-proof-skip.txt")"
  printf 'SKIPX16 once\n'                          > "$TMP/cnt-proof-skip.txt"
  _cp1="$(cnt_occ "SKIPX16" "$TMP/cnt-proof-skip.txt")"
  printf 'SKIPX16 and SKIPX16 same line\n'         > "$TMP/cnt-proof-skip.txt"
  _cp2="$(cnt_occ "SKIPX16" "$TMP/cnt-proof-skip.txt")"
  [ "$_cp0" = 0 ] && [ "$_cp1" = 1 ] && [ "$_cp2" = 2 ] \
    && ok "cnt_occ (skip teeth): 0/1/2 same-line → 0/1/2 (self-proof)" \
    || no "cnt_occ (skip teeth): proof failed (0=$_cp0 1=$_cp1 2=$_cp2)"

  # Anchor cardinality: each skip site must appear exactly once in this file.
  # Two techniques prevent self-reference:
  #   (1) Split-variable construction: _a16+_bskip form the anchor at runtime;
  #       neither half alone is the full anchor, so neither assignment line
  #       contains it, and the cnt_occ call stores "${_a16}${_bskip}" as text
  #       (unexpanded) — not the literal concatenation.
  #   (2) Backreference sed: mutation lines use \( \) before the quote, inserting
  #       a backslash that changes the byte sequence at that position so cnt_occ
  #       cannot match those lines against the anchor.
  #   Result: the anchor appears exactly once in the file — at the actual call.
  _self="$HERE/census-target.test.sh"
  _a16='skip "16 unreadable dir warning'
  _a18='skip "18 WARNING on stdout'
  _bskip=' — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory'

  _anc16="$(cnt_occ "${_a16}${_bskip}" "$_self")"
  if [ "$_anc16" = 1 ]; then
    ok "anchor-16: skip site for case 16 occurs exactly once in test file"
  else
    no "anchor-16: occurs $_anc16 time(s) in test file (expected 1); mutation will target wrong site"
  fi

  _anc18="$(cnt_occ "${_a18}${_bskip}" "$_self")"
  if [ "$_anc18" = 1 ]; then
    ok "anchor-18: skip site for case 18 occurs exactly once in test file"
  else
    no "anchor-18: occurs $_anc18 time(s) in test file (expected 1); mutation will target wrong site"
  fi

  # Non-root baseline: fresh sub-invocation so _norm_pass is not polluted by
  # teeth passes in this run's $pass counter.  Extract the full triple
  # (passed, skipped, failed) so all isolation controls can compare it.
  _norm_out="$(bash "$_self" 2>&1)"
  _norm_pass="$(printf '%s\n' "$_norm_out" | awk '/^== [0-9]+ passed/{print $2}')"
  _norm_skip_cnt="$(printf '%s\n' "$_norm_out" | grep -cE '^  SKIP  ')"
  _norm_fail="$(printf '%s\n' "$_norm_out" | awk '/^== [0-9]+ passed/{print $5}')"

  # Env-isolation control: _IS_ROOT=1 in an ordinary invocation must not
  # change the coverage triple.  The comparison is triple-to-triple, not
  # triple-to-zero: on a root machine id -u legitimately produces non-zero
  # skips in the baseline, and demanding _env_skip=0 would false-fail there
  # while reporting "coverage changed" over an unchanged result.
  echo "-- env-isolation: _IS_ROOT=1 alone must not change coverage triple --"
  _env_out="$(_IS_ROOT=1 bash "$_self" 2>&1)"
  _env_pass="$(printf '%s\n' "$_env_out" | awk '/^== [0-9]+ passed/{print $2}')"
  _env_skip="$(printf '%s\n' "$_env_out" | grep -cE '^  SKIP  ')"
  _env_fail="$(printf '%s\n' "$_env_out" | awk '/^== [0-9]+ passed/{print $5}')"
  if [ -n "$_norm_pass" ] \
     && [ "$_env_pass" = "$_norm_pass" ] \
     && [ "$_env_skip" = "$_norm_skip_cnt" ] \
     && [ "$_env_fail" = "$_norm_fail" ]; then
    ok "env-isolation: _IS_ROOT=1 in env → pass=$_env_pass skip=$_env_skip fail=$_env_fail (triple unchanged; baseline=$_norm_pass/$_norm_skip_cnt/$_norm_fail)"
  else
    no "env-isolation: _IS_ROOT=1 changed coverage — pass=${_env_pass:-?}/${_norm_pass:-?} skip=$_env_skip/${_norm_skip_cnt:-?} fail=${_env_fail:-?}/${_norm_fail:-?}"
  fi

  # Arg-alone control: --_teeth-probe-root WITHOUT _CENSUS_TEETH_PROBE must
  # not activate forcing.  This tests the argument half of the two-signal
  # requirement in isolation — a control that can catch someone dropping the
  # marker check while the env-isolation control stays green.
  echo "-- arg-alone: --_teeth-probe-root without _CENSUS_TEETH_PROBE must not activate forcing --"
  _argonly_out="$(bash "$_self" --_teeth-probe-root 2>&1)"
  _argonly_pass="$(printf '%s\n' "$_argonly_out" | awk '/^== [0-9]+ passed/{print $2}')"
  _argonly_skip="$(printf '%s\n' "$_argonly_out" | grep -cE '^  SKIP  ')"
  _argonly_fail="$(printf '%s\n' "$_argonly_out" | awk '/^== [0-9]+ passed/{print $5}')"
  if [ -n "$_norm_pass" ] \
     && [ "$_argonly_pass" = "$_norm_pass" ] \
     && [ "$_argonly_skip" = "$_norm_skip_cnt" ] \
     && [ "$_argonly_fail" = "$_norm_fail" ]; then
    ok "arg-alone: --_teeth-probe-root alone → pass=$_argonly_pass skip=$_argonly_skip fail=$_argonly_fail (triple unchanged; baseline=$_norm_pass/$_norm_skip_cnt/$_norm_fail)"
  else
    no "arg-alone: --_teeth-probe-root alone changed coverage — pass=${_argonly_pass:-?}/${_norm_pass:-?} skip=$_argonly_skip/${_norm_skip_cnt:-?} fail=${_argonly_fail:-?}/${_norm_fail:-?}"
  fi

  # Forced-probe sub-invocation: both signals combined (arg + namespaced marker)
  # → cases 16 and 18 take the skip branch.  No --prove-teeth: prevents recursion.
  _root_out="$(_CENSUS_TEETH_PROBE="census-target.test.sh" bash "$_self" --_teeth-probe-root 2>&1)"

  # Case 16 accounting (measured separately from case 18).
  _skip16="$(printf '%s\n' "$_root_out" | grep -cE '^  SKIP  16 ')"
  _pass16="$(printf '%s\n' "$_root_out" | grep -cE '^  PASS  16 ')"
  if [ "$_skip16" = 1 ] && [ "$_pass16" = 0 ]; then
    ok "skip-acct-16 (GREEN): forced-probe → SKIP line present (1), PASS line absent (0)"
  else
    no "skip-acct-16 (GREEN): skip=$_skip16 (want 1) pass=$_pass16 (want 0)"
  fi

  # Case 18 accounting (measured separately; not inferred from case 16 result).
  _skip18="$(printf '%s\n' "$_root_out" | grep -cE '^  SKIP  18 ')"
  _pass18="$(printf '%s\n' "$_root_out" | grep -cE '^  PASS  18 ')"
  if [ "$_skip18" = 1 ] && [ "$_pass18" = 0 ]; then
    ok "skip-acct-18 (GREEN): forced-probe → SKIP line present (1), PASS line absent (0)"
  else
    no "skip-acct-18 (GREEN): skip=$_skip18 (want 1) pass=$_pass18 (want 0)"
  fi

  # Summary pass count: the probe converts to SKIP only the sites the baseline
  # did not already skip, so the expected PASS delta is derived from observed
  # skip counts, not fixed at 2 — non-root baseline runs 16 and 18 as PASS so
  # delta is 2; under root both are already skipped so delta is 0.  fail must be 0.
  # Summary format: "== N passed · M failed ==" — $2=N, $4=·, $5=M.
  _root_pass="$(printf '%s\n' "$_root_out" | awk '/^== [0-9]+ passed/{print $2}')"
  _root_fail="$(printf '%s\n' "$_root_out" | awk '/^== [0-9]+ passed/{print $5}')"
  _probe_skip_cnt="$(printf '%s\n' "$_root_out" | grep -cE '^  SKIP  ')"
  _exp_delta=$(( _probe_skip_cnt - _norm_skip_cnt ))
  if [ -n "$_root_pass" ] && [ -n "$_norm_pass" ] \
     && [ "$_root_pass" = $((_norm_pass - _exp_delta)) ] && [ "$_root_fail" = 0 ]; then
    ok "skip-summary: probe pass=$_root_pass = baseline pass=$_norm_pass − $_exp_delta; fail=$_root_fail (delta derived: probe skips=$_probe_skip_cnt, baseline skips=$_norm_skip_cnt)"
  else
    no "skip-summary: probe pass=${_root_pass:-?} (want $(( ${_norm_pass:-0} - _exp_delta ))) baseline=${_norm_pass:-?} delta=$_exp_delta probe-skips=$_probe_skip_cnt baseline-skips=$_norm_skip_cnt fail=${_root_fail:-?} (want 0)"
  fi

  # Env-isolation-nonzero: the forced-probe baseline has skip≠0 (cases 16 and
  # 18).  Adding _IS_ROOT=1 to the environment of an already-forced invocation
  # must not alter that triple.  This proves the triple comparison holds for
  # a non-zero skip baseline — which the ordinary-baseline control cannot
  # exercise on non-root machines (its baseline has 0 skips there).
  echo "-- env-isolation-nonzero: _IS_ROOT=1 must not change the forced-probe triple (skip≠0 baseline) --"
  _probe_skip="$(printf '%s\n' "$_root_out" | grep -cE '^  SKIP  ')"
  _probe_env_out="$(_IS_ROOT=1 _CENSUS_TEETH_PROBE="census-target.test.sh" bash "$_self" --_teeth-probe-root 2>&1)"
  _probe_env_pass="$(printf '%s\n' "$_probe_env_out" | awk '/^== [0-9]+ passed/{print $2}')"
  _probe_env_skip="$(printf '%s\n' "$_probe_env_out" | grep -cE '^  SKIP  ')"
  _probe_env_fail="$(printf '%s\n' "$_probe_env_out" | awk '/^== [0-9]+ passed/{print $5}')"
  if [ "$_probe_env_pass" = "$_root_pass" ] \
     && [ "$_probe_env_skip" = "$_probe_skip" ] \
     && [ "$_probe_env_fail" = "$_root_fail" ]; then
    ok "env-isolation-nonzero: forced-probe+_IS_ROOT=1 → pass=$_probe_env_pass skip=$_probe_env_skip fail=$_probe_env_fail (triple unchanged; baseline=$_root_pass/$_probe_skip/$_root_fail, skip≠0)"
  else
    no "env-isolation-nonzero: env changed forced-probe triple — baseline=${_root_pass}/${_probe_skip}/${_root_fail} env=${_probe_env_pass:-?}/${_probe_env_skip:-?}/${_probe_env_fail:-?}"
  fi

  # Mutation RED check: re-route case 16 skip → ok; forced-probe must show PASS
  # line for case 16, not SKIP, and the pass summary increases by 1.
  # Mutants live in the mirrored $MUT/tests layout so dirname "$0" resolves a SUT copy — no _TEETH_HERE.
  # Backreference \( \) inserts a backslash-paren before the quote, making the
  # sed line's byte sequence differ from the anchor so cnt_occ does not count it.
  # The mutants are mutants of the TEST FILE: built in the mirrored layout under $MUT (see top).
  cp "$SUT" "$MUT/census-target.sh"
  mkdir -p "$MUT/tests/lib" && cp "$HERE/lib/mutant.sh" "$MUT/tests/lib/mutant.sh"   # the mutant test sources it too
  _mut16="$MUT/tests/census-target.SKIPMUT16.sh"
  if MK_ORIG="$_self" mk_sed "skip-mut-16" "$_mut16" \
    's/skip \("16 unreadable dir warning — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory\)/ok \1/'; then
    _mut16_out="$(_CENSUS_TEETH_PROBE="census-target.test.sh" bash "$_mut16" --_teeth-probe-root 2>&1)"
    _mut16_skip16="$(printf '%s\n' "$_mut16_out" | grep -cE '^  SKIP  16 ')"
    _mut16_pass16="$(printf '%s\n' "$_mut16_out" | grep -cE '^  PASS  16 ')"
    _mut16_sumpass="$(printf '%s\n' "$_mut16_out" | awk '/^== [0-9]+ passed/{print $2}')"
    if [ "$_mut16_pass16" = 1 ] && [ "$_mut16_skip16" = 0 ] \
       && [ -n "$_mut16_sumpass" ] && [ "$_mut16_sumpass" = $((_root_pass + 1)) ]; then
      ok "skip-mut-16 (RED): mutant routes case-16 through ok — PASS present, SKIP absent, pass=$_mut16_sumpass (was $_root_pass)"
    else
      no "skip-mut-16 (RED): expected pass16=1 skip16=0 sumpass=$((_root_pass+1)); got pass16=$_mut16_pass16 skip16=$_mut16_skip16 sum=${_mut16_sumpass:-?}"
    fi
  fi

  # Mutation RED check: re-route case 18 skip → ok; same accounting proof.
  _mut18="$MUT/tests/census-target.SKIPMUT18.sh"
  if MK_ORIG="$_self" mk_sed "skip-mut-18" "$_mut18" \
    's/skip \("18 WARNING on stdout — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory\)/ok \1/'; then
    _mut18_out="$(_CENSUS_TEETH_PROBE="census-target.test.sh" bash "$_mut18" --_teeth-probe-root 2>&1)"
    _mut18_skip18="$(printf '%s\n' "$_mut18_out" | grep -cE '^  SKIP  18 ')"
    _mut18_pass18="$(printf '%s\n' "$_mut18_out" | grep -cE '^  PASS  18 ')"
    _mut18_sumpass="$(printf '%s\n' "$_mut18_out" | awk '/^== [0-9]+ passed/{print $2}')"
    if [ "$_mut18_pass18" = 1 ] && [ "$_mut18_skip18" = 0 ] \
       && [ -n "$_mut18_sumpass" ] && [ "$_mut18_sumpass" = $((_root_pass + 1)) ]; then
      ok "skip-mut-18 (RED): mutant routes case-18 through ok — PASS present, SKIP absent, pass=$_mut18_sumpass (was $_root_pass)"
    else
      no "skip-mut-18 (RED): expected pass18=1 skip18=0 sumpass=$((_root_pass+1)); got pass18=$_mut18_pass18 skip18=$_mut18_skip18 sum=${_mut18_sumpass:-?}"
    fi
  fi

  echo "-- teeth-git: remove .git exclusion; (no ext) row must appear for the git object --"
  d_git="$TMP/teeth-git-dir"; mkdir -p "$d_git/.git/objects"
  printf 'x\n' > "$d_git/.git/objects/noext"  # no-extension file inside .git
  printf 'x\n' > "$d_git/real.txt"             # .txt extension — unrelated to (no ext)

  # Original: exit 0 and no (no ext) row (the .git object is excluded). Mutant (exclusion removed):
  # exit 0 and the (no ext) row appears.
  git_anchor="-not -path '*/.git/*' "
  sut_git_content="$(cat "$SUT")"
  if [[ "$sut_git_content" != *"$git_anchor"* ]]; then
    no "teeth-git: .git exclusion anchor not found in SUT — SUT drifted?"
  else
    mutant_git="$MUT/census-target.GIT-MUTANT.sh"
    printf '%s\n' "${sut_git_content/"$git_anchor"/}" > "$mutant_git"
    chmod +x "$mutant_git"
    mk_verify "teeth-git" "$mutant_git" \
      && tooth "teeth-git: mutant (no .git exclusion) shows (no ext) row; SUT does not — exclusion is load-bearing (case 11 has teeth)" 0 0 "$mutant_git" \
           --good-lacks '\(no ext\)' --bad-has '\(no ext\)' -- bash @SUT@ "$d_git"
  fi

  echo "-- teeth-mb: neuter byte comparison; 1MB file must NOT be starred in the mutant --"
  d="$TMP/teeth-mb-dir"; mkdir -p "$d"
  dd if=/dev/zero of="$d/onebig.iso" bs=1048576 count=1 2>/dev/null  # 1MB, count=1 < 5

  # Original: exit 0 and the 1MB file IS starred via the MB arm. Mutant (byte comparison neutered,
  # count arm intact): exit 0 and it is NOT starred.
  mutant_mb="$MUT/census-target.MB-MUTANT.sh"
  mk_sed "teeth-mb" "$mutant_mb" 's/bytes\[e\] >= tm + 0/0 >= tm + 0/' \
    && tooth "teeth-mb: byte-neutered mutant does NOT star the 1MB file (count < 5, byte arm dead); SUT does — byte comparison is load-bearing" 0 0 "$mutant_mb" \
         --good-has 'iso[[:space:]].*\*' --bad-lacks 'iso[[:space:]].*\*' -- bash @SUT@ "$d"

  # Neutral-mutant refusals (#1299): the helper must reject a mutant that cannot be a real mutation,
  # so a control built from one can never read as teeth. Asserts the SPECIFIC refusal code of each.
  echo "-- teeth-helper: lib/mutant.sh refuses byte-identical / syntax-broken mutants; no-op stage refused --"
  mutant_sed "$SUT" "$MUT/neutral-identical.sh" 's/ZZZ_NO_SUCH_TOKEN_ZZZ/x/' 2>/dev/null; _hrc=$?
  [ "$_hrc" = 4 ] && [ ! -e "$MUT/neutral-identical.sh" ] \
    && ok "teeth-helper: byte-identical (no-op sed) mutant REFUSED with rc=4 and removed" \
    || no "teeth-helper: byte-identical mutant not refused as rc=4" "(rc=$_hrc)"
  mutant_sed "$SUT" "$MUT/neutral-syntax.sh" 's/^set -uo pipefail$/fi/' 2>/dev/null; _hrc=$?
  [ "$_hrc" = 5 ] && [ ! -e "$MUT/neutral-syntax.sh" ] \
    && ok "teeth-helper: syntax-broken mutant REFUSED with rc=5 and removed" \
    || no "teeth-helper: syntax-broken mutant not refused as rc=5" "(rc=$_hrc)"
  _hfail0="$fail"
  mk_sed "chain" "$MUT/neutral-chain.sh" 's/flag = (cnt/flag = (CNT/' 's/ZZZ_NO_SUCH_TOKEN_ZZZ/x/' >/dev/null; _hrc=$?
  _hfail1="$fail"; fail="$_hfail0"   # the refusal was the expected outcome: do not count its no() as a failure
  [ "$_hrc" != 0 ] && [ "$_hfail1" = $((_hfail0 + 1)) ] && [ ! -e "$MUT/neutral-chain.sh" ] \
    && ok "teeth-helper: chain containing a no-op stage REFUSED (no mutant written)" \
    || no "teeth-helper: chain with a no-op stage was not refused" "(rc=$_hrc)"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

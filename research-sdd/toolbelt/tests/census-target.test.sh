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
# _mut16/_mut18 are placed in $HERE (not $TMP) so their dirname resolves to
# the tests directory, keeping $SUT reachable.  Initialise to empty so the
# trap below is safe before --prove-teeth assigns them.
_mut16=""; _mut18=""
trap 'rm -rf "$TMP"; [ -n "${_mut16:-}" ] && rm -f "$_mut16"; [ -n "${_mut18:-}" ] && rm -f "$_mut18"' EXIT
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
if echo "$out" | grep -qE 'pdf.*\*'; then
  ok "5 .pdf files → pdf starred (*) at threshold count=5" "(found '*' on pdf line)"
else
  no "5 .pdf files → pdf should be starred" "$(echo "$out" | grep -i pdf || echo '(pdf line absent)')"
fi

# 6 — NOT starred below threshold (4 files < default count=5).
d="$TMP/below-count"; mkdir -p "$d"
for i in 1 2 3 4; do printf 'x\n' > "$d/doc${i}.pdf"; done
out="$(run "$d")"
if ! echo "$out" | grep -qE 'pdf.*\*'; then
  ok "4 .pdf files → pdf NOT starred (below threshold)" "(no '*' on pdf line)"
else
  no "4 .pdf files → pdf should NOT be starred" "$(echo "$out" | grep -i pdf | head -1)"
fi

# 7 — STARRED for custom threshold-count override (--threshold-count 3).
d="$TMP/custom-count"; mkdir -p "$d"
for i in 1 2 3; do printf 'x\n' > "$d/report${i}.docx"; done
out="$(run "$d" --threshold-count 3)"
if echo "$out" | grep -qE 'docx.*\*'; then
  ok "--threshold-count 3: 3 .docx files → starred" "(threshold override honored)"
else
  no "--threshold-count 3: 3 .docx files should be starred" "$(echo "$out" | grep -i docx || echo '(docx line absent)')"
fi

# 8 — NOT starred when count=3 with threshold=4.
d="$TMP/under-custom"; mkdir -p "$d"
for i in 1 2 3; do printf 'x\n' > "$d/report${i}.docx"; done
out="$(run "$d" --threshold-count 4)"
if ! echo "$out" | grep -qE 'docx.*\*'; then
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
if echo "$out" | grep -qE 'pdf.*\*' && [ "$pdf_lines" = "1" ]; then
  ok "case-fold: .PDF + .pdf merged → single pdf line, starred" "(${pdf_lines} pdf line(s))"
else
  no "case-fold: expected 1 starred pdf line" "pdf_lines=$pdf_lines; out=$(echo "$out" | grep -iE 'pdf' | head -2 | tr '\n' '|')"
fi

# 10 — Files WITHOUT extension reported as '(no ext)'.
d="$TMP/no-ext"; mkdir -p "$d"
printf 'x\n' > "$d/Makefile"
printf 'x\n' > "$d/README"
out="$(run "$d")"
if echo "$out" | grep -q '(no ext)'; then
  ok "files without extension → '(no ext)' group" "(no-ext line present)"
else
  no "files without extension: expected '(no ext)' group" "$(echo "$out" | head -5 | tr '\n' '|')"
fi

# 11 — .git directory excluded: git object files must not appear.
d="$TMP/with-git"; mkdir -p "$d/.git/objects"
printf 'x\n' > "$d/.git/objects/abc123"  # git internal file
printf 'x\n' > "$d/real.txt"
out="$(run "$d")"
# Objects dir should be excluded; '(no ext)' count should be 0 or only count real.txt
if ! echo "$out" | grep -q 'abc123'; then
  ok ".git/ directory excluded from census" "(git object not in output)"
else
  no ".git/ not excluded: git file appeared in output"
fi

# ---------------------------------------------------------------------------
# 12 — STARRED via MB threshold: 1 file exactly 1MB (= THRESH_MB_BYTES), count=1 < threshold=5.
# The MB arm must fire independently of the count arm.
d="$TMP/threshold-mb"; mkdir -p "$d"
dd if=/dev/zero of="$d/archive.iso" bs=1048576 count=1 2>/dev/null
out="$(run "$d")"
if echo "$out" | grep -qE 'iso[[:space:]].*\*'; then
  ok "12 1 file exactly 1MB → iso starred (*) via MB threshold arm" "(count=1 < 5; MB arm fires)"
else
  no "12 1 file 1MB → iso should be starred via MB arm" \
     "$(echo "$out" | grep -i iso || echo '(iso line absent)')"
fi

# 13 — NOT starred below both thresholds: 1 tiny file (count < 5, bytes << 1MB).
d="$TMP/below-both"; mkdir -p "$d"
printf 'hello\n' > "$d/tiny.iso"
out="$(run "$d")"
if ! echo "$out" | grep -qE 'iso[[:space:]].*\*'; then
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
if ! echo "$out" | grep -qE 'bin[[:space:]].*\*'; then
  ok "14 1048575 bytes (1MB − 1 B) → NOT starred (strictly below 1MB threshold)" "(boundary below)"
else
  no "14 1048575 bytes: should NOT be starred (below 1MB)" \
     "$(echo "$out" | grep -i bin | head -1)"
fi

# 15 — Custom --threshold-mb 2: file of exactly 2MB → starred; below 2MB → not starred.
d="$TMP/custom-mb"; mkdir -p "$d"
dd if=/dev/zero of="$d/big.bin" bs=1048576 count=2 2>/dev/null   # 2MB exactly
out="$(run "$d" --threshold-mb 2)"
if echo "$out" | grep -qE 'bin[[:space:]].*\*'; then
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
if echo "$out" | grep -qE 'iso[[:space:]]+1[[:space:]]+1\.0' && echo "$out" | grep -qE 'iso[[:space:]].*\*'; then
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

  # First, assert the SUT does NOT star it (negative control).
  out_sut="$(run "$d")"
  if echo "$out_sut" | grep -qE 'xyz.*\*'; then
    no "teeth pre-check: SUT incorrectly stars a 1-file type (baseline broken)" "(can't prove teeth)"
  else
    ok "teeth pre-check: SUT does NOT star 1-file type below threshold" "(baseline clean)"
    # Now build a mutant that forces flag=1 always in awk.
    mutant="$TMP/census-target.MUTANT.sh"
    # Swap the conditional expression in the awk to always set flag="*"
    sed 's/flag = (cnt\[e\] >= tc + 0 || bytes\[e\] >= tm + 0) ? "\*" : ""/flag = "*"/' "$SUT" > "$mutant"
    chmod +x "$mutant"
    out_mut="$(bash "$mutant" "$d" 2>&1)"
    if echo "$out_mut" | grep -qE 'xyz.*\*'; then
      ok "teeth: mutant (flag=1 always) DOES star the sub-threshold type (guard is load-bearing)" "(case 6 has teeth)"
    else
      no "teeth: mutant should star sub-threshold type but did not — guard may not be the decider" \
         "$(echo "$out_mut" | grep -i xyz | head -1)"
    fi
  fi

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
  # Mutants live in $HERE so dirname "$0" resolves SUT correctly — no _TEETH_HERE.
  # Backreference \( \) inserts a backslash-paren before the quote, making the
  # sed line's byte sequence differ from the anchor so cnt_occ does not count it.
  _mut16="$HERE/census-target.SKIPMUT16.sh"
  sed 's/skip \("16 unreadable dir warning — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory\)/ok \1/' \
    "$_self" > "$_mut16"
  if cmp -s "$_mut16" "$_self"; then
    no "skip-mut-16: mutant is byte-identical to test file — sed found no site to mutate"
  else
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
  _mut18="$HERE/census-target.SKIPMUT18.sh"
  sed 's/skip \("18 WARNING on stdout — SKIPPED (chmod 000 does not deny traversal; fixture cannot produce locked directory\)/ok \1/' \
    "$_self" > "$_mut18"
  if cmp -s "$_mut18" "$_self"; then
    no "skip-mut-18: mutant is byte-identical to test file — sed found no site to mutate"
  else
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

  echo "-- teeth-mb: neuter byte comparison; 1MB file must NOT be starred in the mutant --"
  d="$TMP/teeth-mb-dir"; mkdir -p "$d"
  dd if=/dev/zero of="$d/onebig.iso" bs=1048576 count=1 2>/dev/null  # 1MB, count=1 < 5

  # Positive control: SUT must star it via MB arm.
  out_sut_mb="$(run "$d")"
  if echo "$out_sut_mb" | grep -qE 'iso[[:space:]].*\*'; then
    ok "teeth-mb pre-check: SUT stars 1MB single file via MB arm" "(positive control)"
    # Mutant: neuter ONLY the byte comparison (0>=tm is always false; count arm still works).
    mutant_mb="$TMP/census-target.MB-MUTANT.sh"
    sed 's/bytes\[e\] >= tm + 0/0 >= tm + 0/' "$SUT" > "$mutant_mb"
    chmod +x "$mutant_mb"
    out_mut_mb="$(bash "$mutant_mb" "$d" 2>&1)"
    if ! echo "$out_mut_mb" | grep -qE 'iso[[:space:]].*\*'; then
      ok "teeth-mb: byte-neutered mutant does NOT star 1MB file (count < 5, byte arm dead) — byte comparison is load-bearing"
    else
      no "teeth-mb: byte-neutered mutant still stars iso — byte comparison may not be the decider (THEATER)" \
         "$(echo "$out_mut_mb" | grep -i iso | head -1)"
    fi
  else
    no "teeth-mb pre-check: SUT fails to star 1MB file (baseline broken, can't prove MB teeth)" \
       "$(echo "$out_sut_mb" | grep -i iso | head -1)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

#!/usr/bin/env bash
# run-all-timings.test.sh — suite for the per-suite wall-time report of run-all.sh (kit issue #2230): the
# `Slowest suites` block of the aggregate and the append-only history under ${XDG_STATE_HOME}/research-sdd/.
#
# ISOLATION (same rule as run-all.test.sh): every case builds a repo-shaped fixture under a mktemp dir, copies the SUT
# in and runs that copy; the history lives in a per-case XDG_STATE_HOME under $TMP, never in the fixture repo.
#
# Cases: serial block + history row shape · history survives a second run · failing suite keeps its rc · top-15 cap ·
# -j mode (window of the batch) · --cache (a reused suite is `cached`, not 0 s, and adds no row) · --shard ·
# unwritable state dir -> typed DEGRADED, gate result unchanged · nothing written inside the fixture repo.
# Mutation controls (--prove-teeth): append neutered, sort order, top cap, cache counted as measured, the -j window
# ignored, a swallowed history failure.
#
# Usage: run-all-timings.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 SUT missing.
# RUN_ALL_TIMINGS_SUT overrides the SUT (used to prove RED against the pre-change runner).
set -uo pipefail
HERE="$(cd -P -- "$(dirname "$0")" && pwd -P)"
SUT="${RUN_ALL_TIMINGS_SUT:-$HERE/run-all.sh}"
IMP="$HERE/suite-impact.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$IMP" ] || { echo "FATAL: suite-impact.sh not found: $IMP" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not on PATH" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_sed || exit 2
TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export RUN_ALL_DEFAULT_RSDD_ROOT="$TMP/default-rsdd-private"   # never scan the host's real /tmp/rsdd
unset XDG_CACHE_HOME XDG_STATE_HOME
MID='·'
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
cgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git -c init.defaultBranch=main "$@"; }

CT='research-sdd/toolbelt/tests'
# mkfix <file> <exit> [sleep-seconds]: a suite with a valid summary line, optionally sleeping first.
mkfix() {
  { printf '#!/usr/bin/env bash\n'; printf ': "$TB/alpha.sh"\n'
    [ -z "${3:-}" ] || printf 'sleep %s\n' "$3"
    printf 'echo "== %s passed %s %s failed =="\n' "$([ "$2" = 0 ] && echo 1 || echo 0)" "$MID" "$([ "$2" = 0 ] && echo 0 || echo 1)"
    printf 'exit %s\n' "$2"; } > "$1"
}
# tree <name> <n-fast> [with-git]: toolbelt suites f01.. (instant) plus slow.test.sh (sleeps 1 s); prints the tests dir.
tree() {
  local root="$TMP/$1" w i; w="$root/$CT"
  mkdir -p "$w/lib" "$root/research-sdd/install/tests" "$root/research-sdd/toolbelt/lib"
  cp "$SUT" "$w/run-all.sh"; cp "$IMP" "$w/suite-impact.sh"; cp "$HERE/../lib/test-lane.sh" "$root/research-sdd/toolbelt/lib/test-lane.sh"
  for ((i = 1; i <= $2; i++)); do mkfix "$w/f$(printf %02d "$i").test.sh" 0; done
  mkfix "$w/slow.test.sh" 0 1
  printf '# fixture: no extras\n' > "$w/suite-tiers.txt"
  printf "#!/usr/bin/env bash\necho alpha\n" > "$root/research-sdd/toolbelt/alpha.sh"
  printf '# fixture: no always-run\n' > "$w/impact-always.txt"
  printf '# fixture: no blind-spot suites\n' > "$w/impact-blindspot.txt"
  if [ -n "${3:-}" ]; then cgit -C "$root" init -q && cgit -C "$root" add -A && cgit -C "$root" commit -q -m base || return 1; fi
  printf '%s' "$w"
}
# run <tests-dir> <state-dir> [args...] — sets OUT, RC; the history of the run is <state-dir>/research-sdd/suite-timings.log.
OUT=""; RC=0
run() {
  local t="$1" st="$2"; shift 2
  OUT="$(cd "${t%/$CT}" && XDG_STATE_HOME="$st" XDG_CACHE_HOME="$TMP/xdg-cache" bash "$t/run-all.sh" "$@" 2>&1)"; RC=$?
}
hist() { printf '%s/research-sdd/suite-timings.log' "$1"; }
nrows() { local f; f="$(hist "$1")"; if [ -f "$f" ]; then wc -l < "$f" | tr -d ' '; else echo absent; fi; }
# secs_of <suite-basename> — the seconds the Slowest block printed for a suite (empty when not listed)
secs_of() { awk -v n="$1" '$2 ~ ("/" n "$") { print $1 }' <<<"$OUT"; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && a + 0 >= b + 0) }'; }
header() { grep -E '^Slowest suites' <<<"$OUT"; }

# ---- 1: serial block, row shape ---------------------------------------------------------------------------------------------
t="$(tree s1 2 git)"; st="$TMP/st1"
run "$t" "$st"
h="$(header)"; s="$(secs_of slow.test.sh)"; f="$(secs_of f01.test.sh)"
row="$(grep -F "$CT/slow.test.sh" "$(hist "$st")" 2>/dev/null)"
if [ "$RC" = 0 ] && grep -qxF 'Slowest suites (top 3 of 3 timed, wall seconds, serial): measured 3, cached 0 (not timed), unmeasured 0' <<<"$h" \
   && ge "$s" 1 && [ -n "$f" ] && ! ge "$f" 1 \
   && [ "$(nrows "$st")" = 3 ] && grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9a-f]+ $CT/slow\.test\.sh [0-9]+\.[0-9] 0\$" <<<"$row" \
   && grep -qF "Suite timing history: appended 3 row(s) to $(hist "$st")" <<<"$OUT"; then
  ok "serial: block header counts, slow suite >= 1 s ($s), fast suite < 1 s ($f), 3 history rows of '<date> <head> <suite> <seconds> <rc>'"
else no "serial block/row wrong: rc=$RC header=[$h] slow=[$s] fast=[$f] rows=$(nrows "$st") row=[$row]"; fi
# the slowest suite is listed first
first="$(awk '/^Slowest suites/ { getline; print $2; exit }' <<<"$OUT")"
[ "$first" = "$CT/slow.test.sh" ] && ok "serial: the slowest suite is the first listed" || no "serial: first listed is [$first]"
# block sits before the closing separator, after the aggregate counters
ln_s="$(grep -n '^Suites run:' <<<"$OUT" | cut -d: -f1)"; ln_b="$(grep -n '^Slowest suites' <<<"$OUT" | cut -d: -f1)"
{ [ -n "$ln_s" ] && [ -n "$ln_b" ] && [ "$ln_b" -gt "$ln_s" ]; } && ok "serial: the block follows the existing aggregate lines" || no "serial: block position wrong ($ln_s / $ln_b)"
# nothing written inside the fixture repo
if [ -z "$(cgit -C "${t%/$CT}" status --porcelain 2>/dev/null)" ]; then ok "serial: the fixture repo stays clean (history is outside the repo)"; else no "serial: fixture repo dirty: $(cgit -C "${t%/$CT}" status --porcelain)"; fi

# ---- 2: the history survives a second run -----------------------------------------------------------------------------------
run "$t" "$st"
{ [ "$RC" = 0 ] && [ "$(nrows "$st")" = 6 ]; } && ok "history: a second run appends (6 rows after two runs of 3 suites)" || no "history: rows=$(nrows "$st") rc=$RC"

# ---- 3: a failing suite keeps its rc ----------------------------------------------------------------------------------------
t="$(tree s3 1)"; st="$TMP/st3"; mkfix "$t/bad.test.sh" 1
run "$t" "$st"
if [ "$RC" = 1 ] && grep -qE "$CT/bad\.test\.sh [0-9]+\.[0-9] 1\$" "$(hist "$st")" && grep -qF "$CT/bad.test.sh (rc=1)" <<<"$OUT"; then
  ok "failing suite: timed with its rc in the history and flagged (rc=1) in the block; gate still exits 1"
else no "failing suite: rc=$RC row=[$(grep bad "$(hist "$st")" 2>/dev/null)]"; fi

# ---- 4: top-15 cap ----------------------------------------------------------------------------------------------------------
t="$(tree s4 16)"; st="$TMP/st4"      # 16 instant + 1 slow = 17 suites
run "$t" "$st"
n_lines="$(awk '/^Slowest suites/ { f = 1; next } f && /^  / { c++ } f && !/^  / { f = 0 } END { print c + 0 }' <<<"$OUT")"
if grep -qF 'Slowest suites (top 15 of 17 timed' <<<"$OUT" && [ "$n_lines" = 15 ] && [ "$(nrows "$st")" = 17 ]; then
  ok "top-15: 17 suites -> 15 listed, all 17 recorded in the history"
else no "top-15: header=[$(header)] listed=$n_lines rows=$(nrows "$st")"; fi

# ---- 5: -j mode -------------------------------------------------------------------------------------------------------------
if command -v parallel >/dev/null 2>&1 && parallel --version 2>/dev/null | grep -q 'GNU parallel'; then
  t="$(tree s5 2)"; st="$TMP/st5"
  run "$t" "$st" -j 2
  s="$(secs_of slow.test.sh)"
  if [ "$RC" = 0 ] && grep -qF 'wall seconds, -j 2): measured 3, cached 0 (not timed), unmeasured 0' <<<"$OUT" && ge "$s" 1 && [ "$(nrows "$st")" = 3 ]; then
    ok "-j: every suite measured from its batch window (slow ${s} s), 3 history rows"
  else no "-j: rc=$RC slow=[$s] header=[$(header)] rows=$(nrows "$st")"; fi
else
  echo "SKIP: GNU parallel not available — -j case not run"
fi

# ---- 6: --cache -------------------------------------------------------------------------------------------------------------
t="$(tree s6 1 git)"; st="$TMP/st6"
run "$t" "$st" --cache; r1=$RC
rows1="$(nrows "$st")"
run "$t" "$st" --cache
if [ "$r1" = 0 ] && [ "$RC" = 0 ] && [ "$rows1" = 2 ] && [ "$(nrows "$st")" = 2 ] \
   && grep -qxF 'Slowest suites (top 0 of 0 timed, wall seconds, serial): measured 0, cached 2 (not timed), unmeasured 0' <<<"$OUT" \
   && grep -qF 'Suite timing history: nothing to record' <<<"$OUT"; then
  ok "--cache: reused suites are reported cached (not 0 s) and add no history row"
else no "--cache: rc=$r1/$RC rows=$rows1/$(nrows "$st") header=[$(header)] cache=[$(grep -E "^Cache" <<<"$OUT")]"; fi

# ---- 7: --shard -------------------------------------------------------------------------------------------------------------
t="$(tree s7 3)"; st="$TMP/st7"
run "$t" "$st" --shard 1/2 --shard-manifest "$TMP/s7.manifest"
if [ "$RC" = 0 ] && grep -qE '^Slowest suites \(top 2 of 2 timed, wall seconds, serial\): measured 2' <<<"$OUT" && [ "$(nrows "$st")" = 2 ]; then
  ok "--shard: only the shard's suites are timed and recorded (2 of 4)"
else no "--shard: rc=$RC header=[$(header)] rows=$(nrows "$st")"; fi

# ---- 8: unwritable state dir ------------------------------------------------------------------------------------------------
t="$(tree s8 1)"; printf 'a regular file, not a directory\n' > "$TMP/notadir"
run "$t" "$TMP/notadir"
if [ "$RC" = 0 ] && grep -qF "Suite timing history: DEGRADED — cannot write $TMP/notadir/research-sdd/suite-timings.log; 2 timings not recorded" <<<"$OUT" \
   && grep -qE '^Slowest suites \(top 2 of 2 timed' <<<"$OUT"; then
  ok "unwritable state dir: typed DEGRADED line, the block is still printed, gate result unchanged (exit 0)"
else no "unwritable state dir: rc=$RC [$(grep -E 'Suite timing' <<<"$OUT")]"; fi

# ---- teeth ------------------------------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant of the runner must turn its case red --"
  mut() { # <label> <sed-expr> — builds the mutant into $TMP/m-<label>/, sets MUT (empty on refusal)
    MUT=""; mkdir -p "$TMP/m-$1"
    if mutant_sed "$SUT" "$TMP/m-$1/run-all.sh" "$2" 2>"$TMP/m-$1/err"; then MUT="$TMP/m-$1/run-all.sh"; else no "teeth-$1: no mutant: $(cat "$TMP/m-$1/err")"; fi
  }
  with() { local t="$1" m="$2"; cp "$m" "$t/run-all.sh"; }   # swap the runner of a fixture for the mutant

  mut append 's|^       } >> "\$_th_file" 2>/dev/null; then$|       } > "$_th_file" 2>/dev/null; then|'
  if [ -n "$MUT" ]; then
    t="$(tree m1 2)"; with "$t" "$MUT"; st="$TMP/stm1"; run "$t" "$st"; run "$t" "$st"
    [ "$(nrows "$st")" = 3 ] && ok "teeth-append: an overwriting history keeps 3 rows after two runs, not 6 -> the survival case bites" || no "teeth-append: rows=$(nrows "$st") (THEATER)"
  fi
  mut sort 's/-k1,1nr -k2,2/-k1,1n -k2,2/'
  if [ -n "$MUT" ]; then
    t="$(tree m2 2)"; with "$t" "$MUT"; run "$t" "$TMP/stm2"
    first="$(awk '/^Slowest suites/ { getline; print $2; exit }' <<<"$OUT")"
    [ "$first" != "$CT/slow.test.sh" ] && ok "teeth-sort: an ascending sort lists the fast suite first -> the order case bites" || no "teeth-sort: slow suite still first (THEATER)"
  fi
  mut cap 's/|| _ts_top=15$/|| _ts_top=16/'
  if [ -n "$MUT" ]; then
    t="$(tree m3 16)"; with "$t" "$MUT"; run "$t" "$TMP/stm3"
    grep -qF 'Slowest suites (top 15 of 17' <<<"$OUT" && no "teeth-cap: still capped at 15 (THEATER)" || ok "teeth-cap: a 16-row cap changes the header -> the cap case bites"
  fi
  mut cached 's/^    timing_cached=\$((timing_cached + 1))$/    :/'
  if [ -n "$MUT" ]; then
    t="$(tree m4 1 git)"; with "$t" "$MUT"; ( cd "${t%/$CT}" && cgit add -A && cgit commit -q -m mut ) >/dev/null 2>&1
    st="$TMP/stm4"; run "$t" "$st" --cache; run "$t" "$st" --cache
    grep -qF 'cached 2 (not timed)' <<<"$OUT" && no "teeth-cached: cached count still reported (THEATER)" || ok "teeth-cached: a runner that forgets to count reused suites reports cached 0 -> the cache case bites"
  fi
  mut window 's/^      _ts_val="\$(_ts_secs "\$_ts_w0" "\$_ts_w1")"$/      _ts_val="0.0"/'
  if [ -n "$MUT" ] && command -v parallel >/dev/null 2>&1; then
    t="$(tree m5 2)"; with "$t" "$MUT"; run "$t" "$TMP/stm5" -j 2; s="$(secs_of slow.test.sh)"
    ge "$s" 1 && no "teeth-window: -j still reports the real duration (THEATER)" || ok "teeth-window: a -j runner that ignores the batch window reports ${s:-nothing} for the slow suite -> the -j case bites"
  fi
  mut swallow 's|^       } >> "\$_th_file" 2>/dev/null; then$|       } >> "$_th_file" 2>/dev/null \|\| true; then|'
  if [ -n "$MUT" ]; then
    t="$(tree m6 1)"; with "$t" "$MUT"; run "$t" "$TMP/notadir"
    grep -qF 'DEGRADED' <<<"$OUT" && no "teeth-swallow: failure still reported (THEATER)" || ok "teeth-swallow: a swallowed append failure prints no DEGRADED line -> the degraded case bites"
  fi
fi

echo "== $pass passed $MID $fail failed =="
[ "$fail" -eq 0 ] || exit 1

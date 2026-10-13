#!/usr/bin/env bash
# shard-join.test.sh — suite for shard-join.sh, the join step of the sharded CI gate (kit issue #2114).
#
# Every case writes tiny manifests by hand in the documented format and runs the SUT against an
# --expected list; one case uses real `run-all.sh --shard` manifests end to end. The point of the
# join is the anti-silent-zero rule (§7): missing / duplicated / failed suites, absent or corrupt
# manifests, and a missing shard must each fail with a NAMED finding, and OK must never print
# unless everything was read.
#
# Usage: shard-join.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 SUT missing.
# SHARD_JOIN_SUT overrides the SUT (used to prove RED against a stub).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SHARD_JOIN_SUT:-$HERE/shard-join.sh}"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_sed || exit 2
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MID='·'
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

A=research-sdd/install/tests/a.test.sh
B=research-sdd/toolbelt/tests/b.test.sh
C=research-sdd/toolbelt/tests/c.test.sh
D=research-sdd/toolbelt/tests/d.test.sh
printf '%s\n' "$A" "$B" "$C" "$D" > "$TMP/exp"

# mf <path> <I/N> <exit> [<suite> <RESULT>]... — write a well-formed manifest
mf(){ local f="$1" sh="$2" rc="$3" n; shift 3; n=$(( $# / 2 ))
  { printf '# shard %s suites=%s exit=%s\n' "$sh" "$n" "$rc"; while [ $# -gt 0 ]; do printf '%s %s\n' "$1" "$2"; shift 2; done; } > "$f"; }
# join <args...> — runs the SUT; sets OUT and RC
join(){ OUT="$(bash "$SUT" "$@" 2>&1)"; RC=$?; }

# 1 — a complete green split joins OK (shards of different sizes, including a first/last position)
mf "$TMP/m1" 1/2 0 "$A" PASS "$C" PASS; mf "$TMP/m2" 2/2 0 "$B" PASS "$D" PASS
join --expected "$TMP/exp" --shards 2 "$TMP/m1" "$TMP/m2"
if [ "$RC" -eq 0 ] && grep -q '^Shard join: OK' <<<"$OUT"; then ok "complete green split: exit 0 and an OK line"; else no "green split rc=$RC out=$OUT"; fi

# 2 — missing suite (edge: LAST expected suite dropped) and missing FIRST suite
mf "$TMP/m1" 1/2 0 "$A" PASS "$C" PASS; mf "$TMP/m2" 2/2 0 "$B" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"
if [ "$RC" -eq 1 ] && grep -qF "JOIN: MISSING SUITE: $D" <<<"$OUT" && ! grep -q '^Shard join: OK' <<<"$OUT"; then ok "missing LAST suite is named, exit 1"; else no "missing last rc=$RC out=$OUT"; fi
mf "$TMP/m1" 1/2 0 "$C" PASS; mf "$TMP/m2" 2/2 0 "$B" PASS "$D" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"
if [ "$RC" -eq 1 ] && grep -qF "JOIN: MISSING SUITE: $A" <<<"$OUT"; then ok "missing FIRST suite is named, exit 1"; else no "missing first rc=$RC out=$OUT"; fi
mf "$TMP/m1" 1/2 0 "$A" PASS "$B" PASS "$D" PASS; mf "$TMP/m2" 2/2 0 "$C" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"; [ "$RC" -eq 0 ] && ok "middle position in either shard is fine" || no "reordered split rc=$RC out=$OUT"
mf "$TMP/m1" 1/2 0 "$A" PASS "$D" PASS; mf "$TMP/m2" 2/2 0 "$B" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"
if [ "$RC" -eq 1 ] && grep -qF "JOIN: MISSING SUITE: $C" <<<"$OUT"; then ok "missing MIDDLE suite is named, exit 1"; else no "missing middle rc=$RC out=$OUT"; fi

# 3 — duplicated suite
mf "$TMP/m1" 1/2 0 "$A" PASS "$B" PASS "$C" PASS; mf "$TMP/m2" 2/2 0 "$B" PASS "$D" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"
if [ "$RC" -eq 1 ] && grep -qF "JOIN: DUPLICATED SUITE: $B ran 2 times" <<<"$OUT"; then ok "duplicated suite is named, exit 1"; else no "duplicate rc=$RC out=$OUT"; fi

# 4 — failed suite, and a shard whose own exit code was non-zero with every suite PASS
mf "$TMP/m1" 1/2 1 "$A" PASS "$C" FAIL; mf "$TMP/m2" 2/2 0 "$B" PASS "$D" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"
if [ "$RC" -eq 1 ] && grep -qF "JOIN: FAILED SUITE: $C" <<<"$OUT" && grep -qF 'JOIN: SHARD FAILED: shard 1/2 exited 1' <<<"$OUT"; then ok "failed suite and failed shard are both named"; else no "failed rc=$RC out=$OUT"; fi
mf "$TMP/m1" 1/2 1 "$A" PASS "$C" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"
if [ "$RC" -eq 1 ] && grep -qF 'JOIN: SHARD FAILED: shard 1/2' <<<"$OUT" && ! grep -q 'FAILED SUITE' <<<"$OUT"; then ok "all-PASS shard with non-zero exit (hermeticity/teeth gate) still fails the join"; else no "shard-exit rc=$RC out=$OUT"; fi

# 5 — absent and corrupt manifests are typed failures, never a pass
mf "$TMP/m1" 1/2 0 "$A" PASS "$C" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/nope"
if [ "$RC" -eq 1 ] && grep -qF 'JOIN: ABSENT manifest' <<<"$OUT" && grep -qF 'MISSING SHARD: shard 2/2' <<<"$OUT"; then ok "absent manifest: ABSENT + MISSING SHARD, exit 1"; else no "absent rc=$RC out=$OUT"; fi
: > "$TMP/empty"
join --expected "$TMP/exp" "$TMP/m1" "$TMP/empty"; { [ "$RC" -eq 1 ] && grep -qF 'CORRUPT manifest' <<<"$OUT" && grep -qF 'is empty' <<<"$OUT"; } && ok "empty manifest is CORRUPT" || no "empty rc=$RC out=$OUT"
printf 'garbage\n%s PASS\n' "$B" > "$TMP/nohdr"
join --expected "$TMP/exp" "$TMP/m1" "$TMP/nohdr"; { [ "$RC" -eq 1 ] && grep -qF 'no valid header' <<<"$OUT"; } && ok "headerless manifest is CORRUPT" || no "nohdr rc=$RC out=$OUT"
printf '# shard 2/2 suites=2 exit=0\n%s PASS\n' "$B" > "$TMP/trunc"
join --expected "$TMP/exp" "$TMP/m1" "$TMP/trunc"; { [ "$RC" -eq 1 ] && grep -qF 'truncated' <<<"$OUT"; } && ok "truncated manifest (K != lines) is CORRUPT" || no "trunc rc=$RC out=$OUT"
printf '# shard 2/2 suites=1 exit=0\n%s MAYBE\n' "$B" > "$TMP/badline"
join --expected "$TMP/exp" "$TMP/m1" "$TMP/badline"; { [ "$RC" -eq 1 ] && grep -qF 'malformed' <<<"$OUT"; } && ok "unknown result token is CORRUPT" || no "badline rc=$RC out=$OUT"
printf '# shard 3/2 suites=0 exit=0\n' > "$TMP/badidx"
join --expected "$TMP/exp" "$TMP/m1" "$TMP/badidx"; { [ "$RC" -eq 1 ] && grep -qF 'outside 1..2' <<<"$OUT"; } && ok "shard index outside 1..N is CORRUPT" || no "badidx rc=$RC out=$OUT"

# 5b — no readable manifest at all: NO VALID MANIFEST (no shard count is known), never a pass
join --expected "$TMP/exp" "$TMP/trunc" "$TMP/nohdr"
if [ "$RC" -eq 1 ] && grep -qF 'JOIN: NO VALID MANIFEST' <<<"$OUT"; then ok "only corrupt manifests: NO VALID MANIFEST, exit 1"; else no "no valid rc=$RC out=$OUT"; fi

# 6 — shard-set mismatches: missing shard, duplicate shard, N disagreement, --shards disagreement
mf "$TMP/m1" 1/3 0 "$A" PASS; mf "$TMP/m2" 2/3 0 "$B" PASS "$C" PASS "$D" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"
if [ "$RC" -eq 1 ] && grep -qF 'MISSING SHARD: shard 3/3' <<<"$OUT" && grep -qF 'SHARD COUNT MISMATCH: 3 shard(s) expected but 2' <<<"$OUT"; then ok "a dropped shard is named"; else no "dropped shard rc=$RC out=$OUT"; fi
mf "$TMP/m1" 1/2 0 "$A" PASS "$C" PASS; mf "$TMP/m2" 1/2 0 "$B" PASS "$D" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"
if [ "$RC" -eq 1 ] && grep -qF 'DUPLICATE SHARD: shard 1/2' <<<"$OUT" && grep -qF 'MISSING SHARD: shard 2/2' <<<"$OUT"; then ok "the same shard twice is named"; else no "dup shard rc=$RC out=$OUT"; fi
mf "$TMP/m1" 1/2 0 "$A" PASS "$C" PASS; mf "$TMP/m2" 2/3 0 "$B" PASS "$D" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"; { [ "$RC" -eq 1 ] && grep -qF 'SHARD COUNT MISMATCH' <<<"$OUT"; } && ok "headers that disagree on N fail" || no "N disagree rc=$RC out=$OUT"
mf "$TMP/m2" 2/2 0 "$B" PASS "$D" PASS
join --expected "$TMP/exp" --shards 3 "$TMP/m1" "$TMP/m2"; { [ "$RC" -eq 1 ] && grep -qF 'but --shards 3 was expected' <<<"$OUT"; } && ok "--shards cross-check catches a consistently wrong N" || no "--shards rc=$RC out=$OUT"

# 7 — unexpected suite, skipped suite (non-failing by default, failing under --strict-skip)
mf "$TMP/m1" 1/2 0 "$A" PASS "$C" PASS "research-sdd/toolbelt/tests/ghost.test.sh" PASS; mf "$TMP/m2" 2/2 0 "$B" PASS "$D" PASS
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"; { [ "$RC" -eq 1 ] && grep -qF 'UNEXPECTED SUITE: research-sdd/toolbelt/tests/ghost.test.sh' <<<"$OUT"; } && ok "a suite outside the expected list is named" || no "unexpected rc=$RC out=$OUT"
mf "$TMP/m1" 1/2 0 "$A" PASS "$C" SKIP
join --expected "$TMP/exp" "$TMP/m1" "$TMP/m2"; [ "$RC" -eq 0 ] && ok "SKIP passes by default (matches the local gate)" || no "skip default rc=$RC out=$OUT"
join --expected "$TMP/exp" --strict-skip "$TMP/m1" "$TMP/m2"; { [ "$RC" -eq 1 ] && grep -qF "SKIPPED SUITE: $C" <<<"$OUT"; } && ok "--strict-skip fails on a SKIP" || no "strict skip rc=$RC out=$OUT"

# 8 — expected list problems and usage errors
mf "$TMP/m1" 1/2 0 "$A" PASS; mf "$TMP/m2" 2/2 0 "$B" PASS
join --expected "$TMP/none" "$TMP/m1" "$TMP/m2"; { [ "$RC" -eq 1 ] && grep -qF 'EXPECTED LIST ABSENT' <<<"$OUT"; } && ok "absent expected list fails" || no "absent exp rc=$RC out=$OUT"
: > "$TMP/exp-empty"; join --expected "$TMP/exp-empty" "$TMP/m1" "$TMP/m2"; { [ "$RC" -eq 1 ] && grep -qF 'EXPECTED LIST EMPTY' <<<"$OUT"; } && ok "empty expected list fails (nothing expected is not a pass)" || no "empty exp rc=$RC out=$OUT"
join --expected "$TMP/exp"; RC1=$RC; join --expected "$TMP/exp" --bogus "$TMP/m1"; RC2=$RC; join --expected "$TMP/exp" --shards x "$TMP/m1"; RC3=$RC
{ [ "$RC1" -eq 2 ] && [ "$RC2" -eq 2 ] && [ "$RC3" -eq 2 ]; } && ok "no manifests / unknown flag / bad --shards exit 2" || no "usage rcs=$RC1/$RC2/$RC3"

# 9 — end to end with real run-all.sh manifests (default expected list via --list-suites)
if [ -z "${SHARD_JOIN_SUT:-}" ]; then
  r="$TMP/e2e/research-sdd"; mkdir -p "$r/toolbelt/tests" "$r/install/tests" "$TMP/e2e/aux"
  cp "$HERE/run-all.sh" "$r/toolbelt/tests/run-all.sh"; cp "$SUT" "$r/toolbelt/tests/shard-join.sh"
  printf '# fixture: no extras\n' > "$r/toolbelt/tests/suite-tiers.txt"   # an absent manifest is DEGRADED (kit issue #2203)
  for f in t1 t2 t3; do printf '#!/usr/bin/env bash\necho "== 1 passed %s 0 failed =="\n' "$MID" > "$r/toolbelt/tests/$f.test.sh"; done
  printf '#!/usr/bin/env bash\necho "== 1 passed %s 0 failed =="\n' "$MID" > "$r/install/tests/i1.test.sh"
  for i in 1 2 3; do bash "$r/toolbelt/tests/run-all.sh" --shard "$i/3" --shard-manifest "$TMP/e2e/aux/m$i" >/dev/null 2>&1; done
  OUT="$(bash "$r/toolbelt/tests/shard-join.sh" --shards 3 "$TMP/e2e/aux/m1" "$TMP/e2e/aux/m2" "$TMP/e2e/aux/m3" 2>&1)"; RC=$?
  if [ "$RC" -eq 0 ] && grep -q '^Shard join: OK — 3 shard(s), 4 suite(s)' <<<"$OUT"; then ok "end to end: real shard manifests + --list-suites join OK"; else no "e2e rc=$RC out=$OUT"; fi
  OUT="$(bash "$r/toolbelt/tests/shard-join.sh" --shards 3 "$TMP/e2e/aux/m1" "$TMP/e2e/aux/m3" "$TMP/e2e/aux/m3" 2>&1)"; RC=$?
  if [ "$RC" -eq 1 ] && grep -qF 'DUPLICATE SHARD: shard 3/3' <<<"$OUT" && grep -qF 'MISSING SHARD: shard 2/3' <<<"$OUT"; then ok "end to end: a duplicated manifest in place of shard 2 fails"; else no "e2e dup rc=$RC out=$OUT"; fi

  # 10 — tiers (kit issue #2203): the default expected list is the CORE tier; --tier X selects the list the shards ran.
  #      t3 is extras. Core shards (2) joined by default: 3 suites; the same manifests joined as --tier all miss t3;
  #      extras manifests joined as --tier extras: 1 suite; a core join of extras manifests must not pass.
  rt="$TMP/e2et/research-sdd"; mkdir -p "$rt/toolbelt/tests" "$rt/install/tests" "$TMP/e2et/aux"
  cp "$r/toolbelt/tests/"*.sh "$rt/toolbelt/tests/"; cp "$r/install/tests/i1.test.sh" "$rt/install/tests/"
  printf '%s\n' "research-sdd/toolbelt/tests/t3.test.sh extras e2e fixture" > "$rt/toolbelt/tests/suite-tiers.txt"
  for i in 1 2; do bash "$rt/toolbelt/tests/run-all.sh" --shard "$i/2" --shard-manifest "$TMP/e2et/aux/c$i" >/dev/null 2>&1; done
  bash "$rt/toolbelt/tests/run-all.sh" --tier extras --shard 1/1 --shard-manifest "$TMP/e2et/aux/x1" >/dev/null 2>&1
  OUT="$(bash "$rt/toolbelt/tests/shard-join.sh" --shards 2 "$TMP/e2et/aux/c1" "$TMP/e2et/aux/c2" 2>&1)"; RC=$?
  OUT2="$(bash "$rt/toolbelt/tests/shard-join.sh" --tier all --shards 2 "$TMP/e2et/aux/c1" "$TMP/e2et/aux/c2" 2>&1)"; RC2=$?
  OUT3="$(bash "$rt/toolbelt/tests/shard-join.sh" --tier=extras --shards 1 "$TMP/e2et/aux/x1" 2>&1)"; RC3=$?
  OUT4="$(bash "$rt/toolbelt/tests/shard-join.sh" --shards 1 "$TMP/e2et/aux/x1" 2>&1)"; RC4=$?
  bash "$rt/toolbelt/tests/shard-join.sh" --tier bogus "$TMP/e2et/aux/c1" >/dev/null 2>&1; RC5=$?
  if [ "$RC" -eq 0 ] && grep -q '^Shard join: OK — 2 shard(s), 3 suite(s)' <<<"$OUT" \
     && [ "$RC2" -eq 1 ] && grep -qF 'MISSING SUITE: research-sdd/toolbelt/tests/t3.test.sh' <<<"$OUT2" \
     && [ "$RC3" -eq 0 ] && grep -q '^Shard join: OK — 1 shard(s), 1 suite(s)' <<<"$OUT3" \
     && [ "$RC4" -eq 1 ] && grep -qF 'UNEXPECTED SUITE: research-sdd/toolbelt/tests/t3.test.sh' <<<"$OUT4" && [ "$RC5" -eq 2 ]; then
    ok "tiers end to end: the default join is core, --tier all/extras joins the matching shards, a tier mismatch fails, a bad --tier exits 2"
  else no "tier e2e rc=$RC/$RC2/$RC3/$RC4/$RC5 out=[$OUT] [$OUT2] [$OUT3] [$OUT4]"; fi
fi

if [ "${1:-}" = "--prove-teeth" ]; then
  mf "$TMP/g1" 1/2 0 "$A" PASS "$C" PASS; mf "$TMP/g2" 2/2 0 "$B" PASS "$D" PASS   # a green split
  mf "$TMP/x1" 1/2 0 "$A" PASS; mf "$TMP/x2" 2/2 0 "$B" PASS "$D" PASS              # missing C
  mf "$TMP/f1" 1/2 0 "$A" PASS "$C" FAIL; mf "$TMP/f2" 2/2 0 "$B" PASS "$D" PASS   # failed C
  mf "$TMP/d1" 1/2 0 "$A" PASS "$B" PASS "$C" PASS; mf "$TMP/d2" 2/2 0 "$B" PASS "$D" PASS # duplicated B
  mf "$TMP/e1" 1/2 1 "$A" PASS "$C" PASS                                            # shard exit 1, all PASS
  mf "$TMP/s1" 1/2 0 "$A" PASS "$C" PASS; mf "$TMP/s2" 1/2 0 "$B" PASS "$D" PASS   # shard 1 twice, 2 absent, full coverage
  mf "$TMP/z1" 1/1 0                                                                # zero-suite manifest
  : > "$TMP/exp-empty"
  mf "$TMP/k1" 1/2 0 "$A" PASS "$C" SKIP                                           # a SKIP result
  mf "$TMP/c1" 1/3 0 "$A" PASS; mf "$TMP/c2" 2/3 0 "$B" PASS "$C" PASS "$D" PASS   # 3 shards declared, 2 manifests
  mf "$TMP/u1" 1/2 0 "$A" PASS "$C" PASS "research-sdd/toolbelt/tests/ghost.test.sh" PASS # a suite nobody expects
  # tooth <label> <sed-expr> <finding-regex> <expected-file> <manifests...>
  # The mutant (one detector removed) must make the NAMED finding disappear from the output of an
  # input that the unmutated SUT flags with it; the finding, not the exit code, because several
  # detectors overlap on one input (e.g. an absent manifest also shows as a missing shard).
  tooth(){ local lbl="$1" expr="$2" pat="$3" ef="$4" w="$TMP/t-$1" gout mout; shift 4; mkdir -p "$w"
    gout="$(bash "$SUT" --expected "$ef" "$@" 2>&1)"
    if ! grep -qE -- "$pat" <<<"$gout"; then no "teeth-$lbl: the unmutated SUT does not emit /$pat/ on this input — the tooth cannot discriminate"; return; fi
    if ! mutant_sed "$SUT" "$w/shard-join.sh" "$expr" 2>"$w/err"; then no "teeth-$lbl: no mutant: $(cat "$w/err")"; return; fi
    mout="$(bash "$w/shard-join.sh" --expected "$ef" "$@" 2>&1)"
    if ! grep -qE -- "$pat" <<<"$mout"; then ok "teeth-$lbl: mutant loses the /$pat/ finding -> the case has real teeth"
    else no "teeth-$lbl: mutant still reports it (THEATER)"; fi; }
  echo "-- teeth: each detector removed in turn; its named finding must then vanish --"
  tooth missing 's/add "MISSING SUITE: \$s ran in no shard"/:/' 'MISSING SUITE' "$TMP/exp" "$TMP/x1" "$TMP/x2"
  tooth failed 's/FAIL) add "FAILED SUITE: \$s" ;;/FAIL) : ;;/' 'FAILED SUITE' "$TMP/exp" "$TMP/f1" "$TMP/f2"
  tooth duplicate 's/elif \[\[ "\$c" -gt 1 \]\]; then add "DUPLICATED SUITE: \$s ran \$c times"/elif false; then :/' 'DUPLICATED SUITE' "$TMP/exp" "$TMP/d1" "$TMP/d2"
  tooth shardexit 's/if \[\[ \$h_rc -ne 0 \]\]; then add "SHARD FAILED/if false; then add "SHARD FAILED/' 'SHARD FAILED' "$TMP/exp" "$TMP/e1" "$TMP/g2"
  tooth absent 's/add "ABSENT manifest: .*continue; fi/continue; fi/' 'ABSENT manifest' "$TMP/exp" "$TMP/g1" "$TMP/nope-a"
  tooth shardset 's/case "\${shard_seen\[\$_i\]:-0}" in/case x in/' 'MISSING SHARD|DUPLICATE SHARD' "$TMP/exp" "$TMP/s1" "$TMP/s2"
  tooth corrupt 's/if \[\[ -n "\$bad" \]\]; then add "CORRUPT manifest: .\$m. \$bad"; continue; fi/if [[ -n "$bad" ]]; then continue; fi/' 'CORRUPT manifest' "$TMP/exp" "$TMP/g1" "$TMP/trunc"
  tooth unexpected 's/add "UNEXPECTED SUITE: \$s is not in the expected list"/:/' 'UNEXPECTED SUITE' "$TMP/exp" "$TMP/u1" "$TMP/g2"
  tooth manifestcount 's/add "SHARD COUNT MISMATCH: \$n_expect shard(s) expected but [^"]*"/:/' 'shard\(s\) expected but' "$TMP/exp" "$TMP/c1" "$TMP/c2"
  tooth shardsflag 's/"\$h_n" != "\$want_shards"/"$h_n" == "x$want_shards"/' 'but --shards 3 was expected' "$TMP/exp" --shards 3 "$TMP/g1" "$TMP/g2"
  tooth novalid 's/add "NO VALID MANIFEST[^"]*"/:/' 'NO VALID MANIFEST' "$TMP/exp" "$TMP/trunc" "$TMP/nohdr"
  tooth strictskip 's/\[\[ -z "\$strict_skip" \]\] || add "SKIPPED SUITE/true || add "SKIPPED SUITE/' 'SKIPPED SUITE' "$TMP/exp" --strict-skip "$TMP/k1" "$TMP/g2"
  echo "-- teeth: --tier not forwarded to run-all.sh --list-suites; the extras join must then compare against the core list (case 10) --"
  w="$TMP/t-tier"; mkdir -p "$w"
  if [ -z "${rt:-}" ]; then no "teeth-tier: tier fixture (case 10) not built"
  elif ! mutant_sed "$SUT" "$w/shard-join.sh" 's/--list-suites --tier "\$tier"/--list-suites/' 2>"$w/err"; then no "teeth-tier: no mutant: $(cat "$w/err")"
  else
    cp "$w/shard-join.sh" "$rt/toolbelt/tests/shard-join-mut.sh"
    mout="$(bash "$rt/toolbelt/tests/shard-join-mut.sh" --tier extras --shards 1 "$TMP/e2et/aux/x1" 2>&1)"; mrc=$?
    if [ "$mrc" -ne 0 ]; then ok "teeth-tier: forwarding-less mutant fails the extras join -> the tier join case has real teeth"
    else no "teeth-tier: mutant still joins the extras shards OK (THEATER)"; fi
  fi
  tooth emptyexp 's/add "EXPECTED LIST EMPTY: zero suites expected, which cannot be a pass"/:/' 'EXPECTED LIST EMPTY' "$TMP/exp-empty" "$TMP/z1"
fi

echo "== $pass passed $MID $fail failed =="
[ "$fail" -eq 0 ] || exit 1

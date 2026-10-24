#!/usr/bin/env bash
# run-all-shard.test.sh — suite for run-all.sh --shard I/N / --shard-manifest / --list-suites (kit issue #2114).
#
# ISOLATION (same rule as run-all.test.sh): the runner discovers suites in ITS OWN tree, so every
# case builds a repo-shaped fixture under a mktemp dir (research-sdd/toolbelt/tests + research-sdd/
# install/tests), copies the SUT in, and runs that copy. Never the real tests/ dir.
#
# Usage: run-all-shard.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 SUT missing.
# RUN_ALL_SHARD_SUT overrides the SUT (used to prove RED against the pre-change runner).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${RUN_ALL_SHARD_SUT:-$HERE/run-all.sh}"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
# shellcheck source=lib/stage-run-all.sh
. "$HERE/lib/stage-run-all.sh"
mutant_bootstrap mutant_sed mutant_chain || exit 2
TMP="$(mktemp -d)"
# run-all.sh scans the default rsdd root (#2164); keep this suite's runs off the real /tmp/rsdd.
export RUN_ALL_DEFAULT_RSDD_ROOT="$TMP/default-rsdd-private"
trap 'rm -rf "$TMP"' EXIT
MID='·'
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

mkfix(){ # file exitcode — a minimal passing (0) or failing (1) suite
  printf '#!/usr/bin/env bash\necho "== %s passed %s %s failed =="\nexit %s\n' \
    "$([ "$2" = 0 ] && echo 2 || echo 1)" "$MID" "$([ "$2" = 0 ] && echo 0 || echo 1)" "$2" > "$1"
}
# mktree <name> <nTool> <nInst> — repo-shaped fixture; prints the toolbelt/tests dir.
mktree(){
  local root="$TMP/$1/research-sdd" i
  mkdir -p "$root/toolbelt/tests" "$root/install/tests" "$root/../aux"
  rsdd_stage_run_all "$root/toolbelt/tests" "$SUT" || return 2
  for ((i = 1; i <= $2; i++)); do mkfix "$root/toolbelt/tests/t$(printf %02d "$i").test.sh" 0; done
  for ((i = 1; i <= $3; i++)); do mkfix "$root/install/tests/i$(printf %02d "$i").test.sh" 0; done
  # one node suite per corpus so the .test.mjs discovery/shard path is exercised too
  printf 'console.log("== 1 passed %s 0 failed ==");\n' "$MID" > "$root/toolbelt/tests/n01.test.mjs"
  printf 'console.log("== 1 passed %s 0 failed ==");\n' "$MID" > "$root/install/tests/n02.test.mjs"
  printf '# fixture: no extras\n' > "$root/toolbelt/tests/suite-tiers.txt"   # an absent manifest is DEGRADED + exit 1 (kit issue #2203)
  printf '%s' "$root/toolbelt/tests"
}
# expected_list <tooldir> — independent oracle of the full repo-relative list (find, not the SUT)
expected_list(){ local r="${1%/research-sdd/toolbelt/tests}"; (cd "$r" && find research-sdd/toolbelt/tests research-sdd/install/tests \( -name '*.test.sh' -o -name '*.test.mjs' \) | LC_ALL=C sort); }
# shard_run <tooldir> <I/N> [extra...] — runs one shard; manifest $d/m.I-N, output $d/out.I-N
shard_run(){ local d="$1" sh="$2"; shift 2; bash "$d/run-all.sh" --shard "$sh" --shard-manifest "$d/../../../aux/m.${sh/\//-}" "$@" >"$d/../../../aux/out.${sh/\//-}" 2>&1; }
hdr_of(){ head -n 1 "$1"; }   # captured by callers (here-string), never piped into grep -q (pipefail SIGPIPE)
manifest_suites(){ grep -v '^#' "$1" | awk '{print $1}'; }

# 1 — partition is a disjoint cover for several N (N=1, middle, N=T, N>T)
d="$(mktree part 4 3)"; expected_list "$d" > "$d/expected.txt"; T="$(wc -l < "$d/expected.txt")"
bad=""
for N in 1 2 3 "$T" 9; do
  : > "$d/union.txt"
  for ((I = 1; I <= N; I++)); do
    shard_run "$d" "$I/$N"
    if [ -f "$d/../../../aux/m.$I-$N" ]; then manifest_suites "$d/../../../aux/m.$I-$N" >> "$d/union.txt"; else bad="$bad [N=$N I=$I no manifest]"; fi
  done
  LC_ALL=C sort "$d/union.txt" > "$d/union.sorted"
  cmp -s "$d/union.sorted" "$d/expected.txt" || bad="$bad [N=$N union != full list (T=$T)]"
done
[ -z "$bad" ] && ok "partition: shards are a disjoint cover of all $T suites for N=1,2,3,T,9" || no "partition broken:$bad"

# 2 — list edges: first suite is in shard 1, last in shard ((T-1) mod N)+1, 4th follows round-robin
bad=""; first="$(sed -n 1p "$d/expected.txt")"; last="$(sed -n "${T}p" "$d/expected.txt")"; mid="$(sed -n 4p "$d/expected.txt")"
grep -qxF "$first" <(manifest_suites "$d/../../../aux/m.1-3") || bad="$bad [first not in 1/3]"
grep -qxF "$last" <(manifest_suites "$d/../../../aux/m.$(( (T - 1) % 3 + 1 ))-3") || bad="$bad [last not in its shard]"
grep -qxF "$mid" <(manifest_suites "$d/../../../aux/m.1-3") || bad="$bad [4th suite not in shard 1/3]"
[ -z "$bad" ] && ok "partition edges: first, middle and last positions land in the round-robin shard" || no "edges:$bad"

# 3 — Shard line, manifest header and result lines
out="$(cat "$d/../../../aux/out.2-3")"; k="$(manifest_suites "$d/../../../aux/m.2-3" | wc -l)"
if grep -qxF "Shard: 2/3 — $k of $T suites" <<<"$out" && grep -qxF "# shard 2/3 suites=$k exit=0" <<<"$(hdr_of "$d/../../../aux/m.2-3")" \
   && [ "$(grep -vc '^#' "$d/../../../aux/m.2-3")" = "$k" ] && [ "$(grep -v '^#' "$d/../../../aux/m.2-3" | grep -cvE ' PASS$')" = 0 ]; then
  ok "aggregate: 'Shard: I/N — K of T suites' line and manifest header/lines present"
else no "shard line/manifest wrong: $(grep '^Shard' <<<"$out" | tr '\n' '|') hdr=$(head -1 "$d/../../../aux/m.2-3")"; fi

# 4 — invalid arguments exit 2 before any suite runs
bad=""
d4="$(mktree inv 2 1)"
for a in "0/3" "4/3" "a/b" "1/0" "1/33" "1/" "/3" "3" "1/2/3" "-1/3" "1/1000" ""; do
  o="$(bash "$d4/run-all.sh" --shard "$a" 2>&1)"; rc=$?
  { [ "$rc" -eq 2 ] && ! grep -qF 'running:' <<<"$o"; } || bad="$bad [shard '$a' rc=$rc]"
done
bash "$d4/run-all.sh" --shard >/dev/null 2>&1; [ $? -eq 2 ] || bad="$bad [bare --shard]"
bash "$d4/run-all.sh" --shard-manifest "$d4/x" >/dev/null 2>&1; rc=$?; { [ $rc -eq 2 ] && [ ! -e "$d4/x" ]; } || bad="$bad [manifest without shard rc=$rc]"
bash "$d4/run-all.sh" --shard 1/2 --shard-manifest >/dev/null 2>&1; [ $? -eq 2 ] || bad="$bad [manifest w/o path]"
bash "$d4/run-all.sh" --list-suites --shard 1/2 >/dev/null 2>&1; [ $? -eq 2 ] || bad="$bad [list+shard]"
bash "$d4/run-all.sh" --shard=1/2 --shard-manifest="$d4/eq.m" >/dev/null 2>&1; rc=$?; { [ $rc -eq 0 ] && [ -f "$d4/eq.m" ]; } || bad="$bad [= forms rc=$rc]"
[ -z "$bad" ] && ok "invalid --shard / --shard-manifest usage exits 2 before any suite runs; --opt=value forms work" || no "arg validation:$bad"

# 4b — --require-teeth with --shard is refused (exit 2, nothing runs): the waiver gate needs the whole corpus
o="$(bash "$d4/run-all.sh" --shard 1/2 --require-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'cannot be combined with --shard' <<<"$o" && ! grep -qF 'AGGREGATE' <<<"$o"; then ok "--require-teeth + --shard exits 2 before any suite runs"
else no "require-teeth+shard rc=$rc"; fi

# 5 — empty shard (N > T) is reported distinctly, exits 1, writes a zero-suite manifest
d5="$(mktree empty 1 1)"; shard_run "$d5" 7/9; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'EMPTY SHARD' "$d5/../../../aux/out.7-9" && grep -qxF 'Shard: 7/9 — 0 of 4 suites' "$d5/../../../aux/out.7-9" \
   && grep -qxF '# shard 7/9 suites=0 exit=1' <<<"$(hdr_of "$d5/../../../aux/m.7-9")" && [ "$(grep -vc '^#' "$d5/../../../aux/m.7-9")" = 0 ]; then
  ok "empty shard: distinct EMPTY SHARD report, exit 1, zero-suite manifest"
else no "empty shard wrong: rc=$rc $(grep -E '^Shard' "$d5/../../../aux/out.7-9" | tr '\n' '|')"; fi

# 6 — failing suite recorded FAIL (shard exits 1); skipped suite recorded SKIP
d6="$(mktree res 2 1)"; mkfix "$d6/t02.test.sh" 1
printf '#!/usr/bin/env bash\necho "SKIP: x"\necho "== 0 passed %s 0 failed =="\nexit 0\n' "$MID" > "$d6/t03.test.sh"
shard_run "$d6" 1/1; rc=$?
if [ "$rc" -eq 1 ] && grep -qxF 'research-sdd/toolbelt/tests/t02.test.sh FAIL' "$d6/../../../aux/m.1-1" \
   && grep -qxF 'research-sdd/toolbelt/tests/t03.test.sh SKIP' "$d6/../../../aux/m.1-1" && grep -qxF 'research-sdd/toolbelt/tests/t01.test.sh PASS' "$d6/../../../aux/m.1-1" \
   && grep -qxF '# shard 1/1 suites=6 exit=1' <<<"$(hdr_of "$d6/../../../aux/m.1-1")"; then ok "manifest records PASS/FAIL/SKIP per suite and the shard exit code"
else no "manifest results wrong: rc=$rc $(tr '\n' '|' < "$d6/../../../aux/m.1-1")"; fi

# 7 — corpus gates still apply to the FULL list: an ABSENT install corpus fails even when the shard passes
d7="$(mktree absent 3 0)"; rm -rf "${d7%/toolbelt/tests}/install"
shard_run "$d7" 1/3; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'ABSENT-INPUT' "$d7/../../../aux/out.1-3"; then ok "shard keeps the install-corpus ABSENT-INPUT gate (exit 1)"
else no "absent install corpus under --shard did not fail: rc=$rc"; fi
d7b="$TMP/nolist/research-sdd/toolbelt/tests"; mkdir -p "$d7b" "$TMP/nolist/research-sdd/install/tests"; rsdd_stage_run_all "$d7b" "$SUT" || { echo "FATAL: cannot stage the run-all.sh fixture" >&2; exit 2; }; printf '# fixture: no extras\n' > "$d7b/suite-tiers.txt"
bash "$d7b/run-all.sh" --shard 1/2 >/dev/null 2>&1; [ $? -eq 1 ] && ok "no suites at all still exits 1 under --shard" || no "empty discovery under --shard did not exit 1"

# 8 — without --shard nothing new appears
d8="$(mktree plain 2 1)"; o="$(bash "$d8/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -qE '^Shard' <<<"$o" && grep -qx 'Suites run:    5' <<<"$o"; then ok "no --shard: no Shard line, all suites run"
else no "unsharded run changed: rc=$rc"; fi

# 9 — --list-suites prints the full sorted list and runs nothing
o="$(bash "$d/run-all.sh" --list-suites 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$o" = "$(cat "$d/expected.txt")" ]; then ok "--list-suites prints the full repo-relative C-sorted list"; else no "--list-suites wrong rc=$rc"; fi
bash "$d7/run-all.sh" --list-suites >/dev/null 2>&1; [ $? -eq 1 ] && ok "--list-suites exits 1 on an absent install corpus" || no "--list-suites absent corpus rc"

# 10 — combines with --prove-teeth and -j 2 (when GNU parallel is usable)
d10="$(mktree combo 2 1)"; shard_run "$d10" 1/2 --prove-teeth; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'Suites without teeth' "$d10/../../../aux/out.1-2"; then ok "--shard combines with --prove-teeth"; else no "shard+prove-teeth rc=$rc"; fi
_pv="$(parallel --version 2>/dev/null)"
if grep -q 'GNU parallel' <<<"$_pv"; then
  shard_run "$d10" 2/2 -j 2; rc=$?
  if [ "$rc" -eq 0 ] && grep -qE '^Parallel: -j 2' "$d10/../../../aux/out.2-2" && grep -qE '^Shard: 2/2' "$d10/../../../aux/out.2-2"; then ok "--shard combines with -j 2"; else no "shard+jobs rc=$rc"; fi
  shard_run "$d5" 7/9 -j 2; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF 'EMPTY SHARD' "$d5/../../../aux/out.7-9"; then ok "empty shard under -j does not hang and is reported"; else no "empty shard -j rc=$rc"; fi
else echo "  SKIP  shard + -j: GNU parallel not usable here"; fi

# 11 — suite tiers (kit issue #2203): the tier filter runs BEFORE --shard/--list-suites, so both see the tier's list
#      (the Shard line's T is the tier's count) while the corpus gates still judge the full set. Extras: one toolbelt
#      .sh suite, one node suite. mktree 3 2 => 7 suites, 5 core + 2 extras.
d11="$(mktree tier 3 2)"; A11="$d11/../../../aux"
printf '%s\n' "research-sdd/toolbelt/tests/t02.test.sh extras r" "research-sdd/toolbelt/tests/n01.test.mjs extras r" > "$d11/suite-tiers.txt"
expected_list "$d11" > "$d11/all.txt"
grep -vxF -e research-sdd/toolbelt/tests/t02.test.sh -e research-sdd/toolbelt/tests/n01.test.mjs "$d11/all.txt" > "$d11/core.txt"
printf '%s\n' research-sdd/toolbelt/tests/n01.test.mjs research-sdd/toolbelt/tests/t02.test.sh > "$d11/extras.txt"
bad=""
for T in core extras all; do
  case "$T" in core) want="$d11/core.txt" ;; extras) want="$d11/extras.txt" ;; all) want="$d11/all.txt" ;; esac
  nT="$(wc -l < "$want")"; : > "$d11/u11"
  for I in 1 2; do
    shard_run "$d11" "$I/2" --tier "$T"
    [ -f "$A11/m.$I-2" ] && manifest_suites "$A11/m.$I-2" >> "$d11/u11"
    grep -qE "^Shard: $I/2 — [0-9]+ of $nT suites\$" "$A11/out.$I-2" || bad="$bad [$T $I/2 Shard line: $(grep '^Shard' "$A11/out.$I-2")]"
  done
  LC_ALL=C sort "$d11/u11" > "$d11/u11s"
  cmp -s "$d11/u11s" "$want" || bad="$bad [$T union != the tier's list]"
  lo="$(bash "$d11/run-all.sh" --list-suites --tier "$T" 2>/dev/null)"; [ "$lo" = "$(cat "$want")" ] || bad="$bad [$T --list-suites differs]"
done
bash "$d11/run-all.sh" --list-suites --tier extras --shard 1/2 >/dev/null 2>&1; [ $? -eq 2 ] || bad="$bad [list+shard+tier not refused]"
# the corpus gate still judges the FULL set: an absent install corpus fails a core shard even though no install suite is extras
d11b="$(mktree tierabs 3 2)"; printf '%s\n' "research-sdd/toolbelt/tests/t02.test.sh extras r" > "$d11b/suite-tiers.txt"; rm -rf "${d11b%/toolbelt/tests}/install"
shard_run "$d11b" 1/2; rc=$?; { [ "$rc" -eq 1 ] && grep -qF "ABSENT-INPUT" "$d11b/../../../aux/out.1-2"; } || bad="$bad [absent install corpus under a core shard rc=$rc]"
[ -z "$bad" ] && ok "tier + shard: --shard and --list-suites operate on the selected tier (core/extras/all) while the corpus gates judge the full set" || no "tier shard:$bad"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: shard assignment off by one; the union must stop covering the list --"
  w="$TMP/teeth-assign"; mkdir -p "$w"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/_si % SHARD_N == SHARD_I - 1/_si % SHARD_N == SHARD_I/' 2>"$w/err"; then no "teeth-assign: no mutant: $(cat "$w/err")"
  else
    dm="$(mktree mut-assign 4 3)"; cp "$w/run-all.sh" "$dm/run-all.sh"; expected_list "$dm" > "$dm/exp"; : > "$dm/u"
    for I in 1 2 3; do shard_run "$dm" "$I/3"; [ -f "$dm/../../../aux/m.$I-3" ] && manifest_suites "$dm/../../../aux/m.$I-3" >> "$dm/u"; done
    LC_ALL=C sort "$dm/u" > "$dm/us"
    if ! cmp -s "$dm/us" "$dm/exp"; then ok "teeth-assign: off-by-one assignment breaks the cover -> the partition case has real teeth"; else no "teeth-assign: mutant still covered (THEATER)"; fi
  fi
  echo "-- teeth: drop the I<=N bound; '4/3' must then be accepted --"
  w="$TMP/teeth-bound"; mkdir -p "$w"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/ || "\$_i" -gt "\$_n"//' 2>"$w/err"; then no "teeth-bound: no mutant: $(cat "$w/err")"
  else
    dm="$(mktree mut-bound 2 1)"; cp "$w/run-all.sh" "$dm/run-all.sh"; bash "$dm/run-all.sh" --shard 4/3 >/dev/null 2>&1; mrc=$?
    if [ "$mrc" -ne 2 ]; then ok "teeth-bound: bound-less mutant accepts 4/3 -> the validation case has real teeth"; else no "teeth-bound: mutant still rejected (THEATER)"; fi
  fi
  echo "-- teeth: drop the cap on N; '1/33' must then be accepted --"
  w="$TMP/teeth-cap"; mkdir -p "$w"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/ || "\$_n" -gt "\$MAX_SHARDS"//' 2>"$w/err"; then no "teeth-cap: no mutant: $(cat "$w/err")"
  else
    dm="$(mktree mut-cap 2 1)"; cp "$w/run-all.sh" "$dm/run-all.sh"; bash "$dm/run-all.sh" --shard 1/33 >/dev/null 2>&1; mrc=$?
    if [ "$mrc" -ne 2 ]; then ok "teeth-cap: cap-less mutant accepts 1/33 -> the cap case has real teeth"; else no "teeth-cap: mutant still rejected (THEATER)"; fi
  fi
  echo "-- teeth: EMPTY SHARD wording removed; the distinct report must vanish --"
  w="$TMP/teeth-empty"; mkdir -p "$w"
  if ! mutant_chain teeth-empty "$SUT" "$w/run-all.sh" 's/EMPTY SHARD/shard/' >"$w/err" 2>&1; then no "teeth-empty: no mutant: $(cat "$w/err")"
  else
    dm="$(mktree mut-empty 1 1)"; cp "$w/run-all.sh" "$dm/run-all.sh"; shard_run "$dm" 7/9
    if ! grep -qF 'EMPTY SHARD' "$dm/../../../aux/out.7-9"; then ok "teeth-empty: mutant loses the distinct report -> the empty-shard case has real teeth"; else no "teeth-empty: still reported (THEATER)"; fi
  fi
  echo "-- teeth: drop the --require-teeth/--shard refusal; the combination must then be accepted --"
  w="$TMP/teeth-reqteeth"; mkdir -p "$w"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/if \[\[ -n "\$REQUIRE_TEETH" \&\& -n "\$SHARD_N" \]\]; then/if false; then/' 2>"$w/err"; then no "teeth-reqteeth: no mutant: $(cat "$w/err")"
  else
    dm="$(mktree mut-reqteeth 2 1)"; cp "$w/run-all.sh" "$dm/run-all.sh"; bash "$dm/run-all.sh" --shard 1/2 --require-teeth >/dev/null 2>&1; mrc=$?
    if [ "$mrc" -ne 2 ]; then ok "teeth-reqteeth: refusal-less mutant accepts the combination -> the case has real teeth"; else no "teeth-reqteeth: mutant still refused (THEATER)"; fi
  fi
  echo "-- teeth: manifest result defaults to PASS; a failing suite must then read PASS --"
  w="$TMP/teeth-result"; mkdir -p "$w"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/^  _res=FAIL$/  _res=PASS/' 2>"$w/err"; then no "teeth-result: no mutant: $(cat "$w/err")"
  else
    dm="$(mktree mut-res 2 1)"; cp "$w/run-all.sh" "$dm/run-all.sh"; mkfix "$dm/t02.test.sh" 1; shard_run "$dm" 1/1
    if grep -qxF 'research-sdd/toolbelt/tests/t02.test.sh PASS' "$dm/../../../aux/m.1-1"; then ok "teeth-result: mutant hides the failure in the manifest -> the result case has real teeth"; else no "teeth-result: mutant still FAIL (THEATER)"; fi
  fi
  echo "-- teeth: manifest exit code pinned to 0; a failing run must then record exit=0 --"
  w="$TMP/teeth-exit"; mkdir -p "$w"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/"\${#all_suites\[@\]}" "\$final_rc"/"${#all_suites[@]}" 0/' 2>"$w/err"; then no "teeth-exit: no mutant: $(cat "$w/err")"
  else
    dm="$(mktree mut-exit 2 1)"; cp "$w/run-all.sh" "$dm/run-all.sh"; mkfix "$dm/t02.test.sh" 1; shard_run "$dm" 1/1
    if grep -qF 'exit=0' <<<"$(hdr_of "$dm/../../../aux/m.1-1")"; then ok "teeth-exit: mutant records exit=0 for a failing shard -> the header case has real teeth"; else no "teeth-exit: header still exit=1 (THEATER)"; fi
  fi
  echo "-- teeth: tier filter neutered; the shard must then see the FULL list (case 11) --"
  w="$TMP/teeth-tierfilter"; mkdir -p "$w"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/^elif \[\[ "\$TIER" != "all" \]\]; then$/elif false; then/' 2>"$w/err"; then no "teeth-tierfilter: no mutant: $(cat "$w/err")"
  else
    # Control first: the REAL runner on this exact fixture must report the tier's list (6 of 6), else the tooth cannot discriminate.
    dg="$(mktree mut-tier-good 3 2)"; printf '%s\n' "research-sdd/toolbelt/tests/t02.test.sh extras r" > "$dg/suite-tiers.txt"; shard_run "$dg" 1/1
    dm="$(mktree mut-tier 3 2)"; cp "$w/run-all.sh" "$dm/run-all.sh"; printf '%s\n' "research-sdd/toolbelt/tests/t02.test.sh extras r" > "$dm/suite-tiers.txt"; shard_run "$dm" 1/1
    if ! grep -qxF 'Shard: 1/1 — 6 of 6 suites' "$dg/../../../aux/out.1-1"; then no "teeth-tierfilter: the real runner does not report '6 of 6' on this fixture — the tooth cannot discriminate"
    elif grep -qxF 'Shard: 1/1 — 7 of 7 suites' "$dm/../../../aux/out.1-1"; then ok "teeth-tierfilter: filter-less mutant shards the full list (7 of 7, control 6 of 6) -> the tier+shard case has real teeth"
    else no "teeth-tierfilter: mutant still shards the tier (THEATER)"; fi
  fi
fi

echo "== $pass passed $MID $fail failed =="
[ "$fail" -eq 0 ] || exit 1

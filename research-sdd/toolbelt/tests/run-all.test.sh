#!/usr/bin/env bash
# run-all.test.sh — RED-FIRST harness for run-all.sh, the central toolbelt test runner.
#
# The runner is itself a script under test: it auto-discovers sibling suites, streams+captures
# their output, tracks suite outcome by EXIT CODE (via PIPESTATUS, not tee's code, not the parsed
# count), sums case totals off the `== N passed · N failed ==` line (literal U+00B7 middle dot),
# forwards --prove-teeth to *.test.sh only, and exits 0 iff no suite failed AND
# at least one suite passed (a fully-skipped run — suites_ok == 0 — exits 1).
#
# ISOLATION: the runner discovers suites in ITS OWN dir, so we NEVER invoke the real ../run-all.sh
# in the real tests/ dir. Per case we mktemp a workdir, cp the SUT into it, drop tiny FIXTURE suites
# beside it, and run that copy. --prove-teeth neuters the runner's PIPESTATUS capture and asserts a
# failing fixture then FALSE-PASSES, proving the exit-code teeth are real (not theater).
#
# Usage: run-all.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 SUT missing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/run-all.sh"   # the runner lives NEXT TO this test, not one dir up
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MID='·'   # literal U+00B7 MIDDLE DOT — the summary-line separator (NOT an ascii period)
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# --- fixture builders -----------------------------------------------------
# A minimal shell suite: prints a header + a valid summary line, then exits with $4.
mkfix_sh(){ # file passed failed exitcode
  local f="$1" p="$2" fl="$3" ec="$4"
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "== %s =="\n' "$(basename "$f")"
    printf 'echo "== %s passed %s %s failed =="\n' "$p" "$MID" "$fl"
    printf 'exit %s\n' "$ec"
  } > "$f"
}
# A harness-error suite: emits NO summary line and exits 2 (script-under-test missing).
mkfix_harness(){ # file
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "FATAL: SUT not found" >&2\n'
    printf 'exit 2\n'
  } > "$1"
}
newdir(){ local w="$TMP/$1"; mkdir -p "$w"; cp "$SUT" "$w/run-all.sh"; printf '%s' "$w"; }
# A suite-level skip fixture: emits SKIP: on stdout, prints a 0/0 summary, exits 0.
mkfix_skip(){ # file label
  local f="$1" label="$2"
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "SKIP: %s tests (missing: some-tool)"\n' "$label"
    printf 'echo "== 0 passed %s 0 failed =="\n' "$MID"
    printf 'exit 0\n'
  } > "$f"
}
zero_case_oracle(){ # runner workdir
  local runner="$1" w="$2"
  mkfix_sh "$w/pass.test.sh" 2 0 0
  mkfix_sh "$w/zero.test.sh" 0 0 0
  ORACLE_OUT="$(bash "$runner" 2>&1)"; ORACLE_RC=$?
  [ "$ORACLE_RC" -eq 1 ] \
    && grep -qF 'zero.test.sh (zero test cases, exit 0)' <<<"$ORACLE_OUT" \
    && grep -qF 'Suites passed: 1' <<<"$ORACLE_OUT" \
    && grep -qF 'Suites failed: 1' <<<"$ORACLE_OUT"
}

echo "== run-all.test.sh (SUT: run-all.sh) =="

# 1 — all fixtures exit 0 → runner exits 0 and aggregates the summed case counts.
w="$(newdir c1)"
mkfix_sh "$w/a.test.sh" 3 0 0
mkfix_sh "$w/b.test.sh" 2 0 0
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -qF 'Suites passed: 2' <<<"$out" \
   && grep -qF 'Test cases passed: 5' <<<"$out"; then
  ok "all-green: runner exit 0, suites 2, cases 5 summed"
else no "all-green failed: rc=$rc :: $(grep -E 'Suites passed|Test cases passed' <<<"$out" | tr '\n' ' ')"; fi

# 2 — one fixture exits 1 → runner exits 1 and NAMES that fixture as failed (exit-code teeth).
w="$(newdir c2)"
mkfix_sh "$w/good.test.sh" 2 0 0
mkfix_sh "$w/bad.test.sh"  1 1 1
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'bad.test.sh (exit 1)' <<<"$out"; then
  ok "one-fail: runner exit 1 and names bad.test.sh (exit 1)"
else no "one-fail failed: rc=$rc :: $(grep -iE 'failed suites|bad.test' <<<"$out" | tr '\n' ' ')"; fi

# 3 — one fixture exits 2 with NO summary → runner exits 1 and labels it a HARNESS ERROR distinctly.
w="$(newdir c3)"
mkfix_sh "$w/fine.test.sh" 1 0 0
mkfix_harness "$w/broken.test.sh"
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'broken.test.sh (HARNESS ERROR, exit 2)' <<<"$out"; then
  ok "harness: exit-2 no-summary fixture → runner exit 1, labeled HARNESS ERROR distinctly"
else no "harness failed: rc=$rc :: $(grep -iE 'harness|broken' <<<"$out" | tr '\n' ' ')"; fi

# 4 — empty dir (only run-all.sh) → runner exits non-zero with a diagnostic, never runs `bash '*.test.sh'`.
w="$(newdir c4)"   # no fixtures copied in
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] \
   && grep -qF 'no test suites' <<<"$out" \
   && ! grep -qiE 'no such file|\*\.test\.sh: ' <<<"$out"; then
  ok "empty: no fixtures → runner exit $rc with diagnostic, glob did not expand literally"
else no "empty failed: rc=$rc :: $(tr '\n' ' ' <<<"$out")"; fi

# 5 — --prove-teeth forwarding: reaches the *.test.sh suite as $1, NEVER reaches the .mjs suite.
w="$(newdir c5)"
{ printf '#!/usr/bin/env bash\n'
  printf 'h="$(cd "$(dirname "$0")" && pwd)"\n'
  printf 'printf "%%s" "${1:-NONE}" > "$h/arg-sh.txt"\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  printf 'exit 0\n'
} > "$w/rec.test.sh"
if command -v node >/dev/null 2>&1; then
  { printf "import { writeFileSync } from 'node:fs';\n"
    printf "import { fileURLToPath } from 'node:url';\n"
    printf "import { dirname, join } from 'node:path';\n"
    printf "const here = dirname(fileURLToPath(import.meta.url));\n"
    printf "writeFileSync(join(here, 'arg-mjs.txt'), process.argv.slice(2).join(','));\n"
    printf "console.log('== 1 passed %s 0 failed ==');\n" "$MID"
    printf "process.exit(0);\n"
  } > "$w/rec.test.mjs"
fi
bash "$w/run-all.sh" --prove-teeth >/dev/null 2>&1
argsh="$(cat "$w/arg-sh.txt" 2>/dev/null || true)"
if [ "$argsh" = "--prove-teeth" ]; then ok "forwarding: *.test.sh suite received --prove-teeth as \$1"
else no "forwarding to .sh broken: arg-sh=[$argsh] (want --prove-teeth)"; fi
if command -v node >/dev/null 2>&1; then
  argmjs="$(cat "$w/arg-mjs.txt" 2>/dev/null || true)"
  if [ -z "$argmjs" ]; then ok "forwarding: .mjs suite received NO extra arg (argv extras empty)"
  else no "forwarding leaked to .mjs: argv-extras=[$argmjs] (want empty)"; fi
else
  ok "forwarding: node absent — skipped .mjs half (node is a CI dep, normally exercised)"
fi

# 6 — case-total parsing: two fixtures with known counts → aggregate totals equal the sums
#     (proves the middle-dot regex actually matched, not a silent 0/0 fallthrough).
w="$(newdir c6)"
mkfix_sh "$w/p.test.sh" 5 0 0   # 5 passed, 0 failed, exit 0
mkfix_sh "$w/q.test.sh" 3 2 1   # 3 passed, 2 failed, exit 1
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if grep -qF 'Test cases passed: 8' <<<"$out" \
   && grep -qF 'Test cases failed: 2' <<<"$out"; then
  ok "totals: middle-dot summaries parsed → cases passed=8, failed=2 (not 0/0)"
else no "totals failed: rc=$rc :: $(grep -E 'Test cases (passed|failed)' <<<"$out" | tr '\n' ' ')"; fi

# 7 — unknown flag rejected: bogus flag → exit 2, message on STDERR, STDOUT empty (no partial run).
#     Teeth: if the guard regressed to silently accepting unknown flags, this must FAIL.
w="$(newdir c7)"
mkfix_sh "$w/a.test.sh" 1 0 0   # a fixture exists, so a regressed guard would run it and pollute stdout
sout="$(bash "$w/run-all.sh" --bogus 2>"$w/err.txt")"; rc=$?
serr="$(cat "$w/err.txt" 2>/dev/null || true)"
if [ "$rc" -eq 2 ] && grep -qF 'unknown flag' <<<"$serr" && [ -z "$sout" ]; then
  ok "unknown-flag: --bogus → exit 2, 'unknown flag' on stderr, stdout empty (no partial run)"
else no "unknown-flag guard failed: rc=$rc · stdout=[$sout] · stderr=$(tr '\n' ' ' <<<"$serr")"; fi

# 8 — empty-string arg is accepted as no-flag (boundary): discovers + runs fixtures, exit 0.
w="$(newdir c8)"
mkfix_sh "$w/a.test.sh" 2 0 0
out="$(bash "$w/run-all.sh" "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'Test cases passed: 2' <<<"$out"; then
  ok "empty-arg: \"\" behaves as no-flag → discovers + runs fixtures, exit 0"
else no "empty-arg regressed: rc=$rc :: $(grep -E 'Test cases passed|unknown flag' <<<"$out" | tr '\n' ' ')"; fi

# 9 — trailing args after --prove-teeth are ignored (only $1 inspected): runs normally, and the
#     garbage is NOT forwarded to suites (the .test.sh recorder must see exactly "--prove-teeth").
w="$(newdir c9)"
{ printf '#!/usr/bin/env bash\n'
  printf 'h="$(cd "$(dirname "$0")" && pwd)"\n'
  printf 'printf "%%s" "${1:-NONE}" > "$h/arg-sh.txt"\n'
  printf 'echo "== 3 passed %s 0 failed =="\n' "$MID"
  printf 'exit 0\n'
} > "$w/rec.test.sh"
out="$(bash "$w/run-all.sh" --prove-teeth extra-garbage 2>&1)"; rc=$?
argsh="$(cat "$w/arg-sh.txt" 2>/dev/null || true)"
if [ "$rc" -eq 0 ] && [ "$argsh" = "--prove-teeth" ] && grep -qF 'Test cases passed: 3' <<<"$out"; then
  ok "trailing-args: '--prove-teeth extra-garbage' runs normally, only \$1 inspected (suite got --prove-teeth, not the garbage)"
else no "trailing-args regressed: rc=$rc · arg-sh=[$argsh] :: $(grep -E 'Test cases passed|unknown flag' <<<"$out" | tr '\n' ' ')"; fi

# 10 — skip-reporting: a suite that emits SKIP: and exits 0 must appear in the
#      "Suites skipped" section, not counted as passed or failed. A passing suite
#      running alongside it keeps the overall exit code 0.
w="$(newdir c10)"
mkfix_sh   "$w/pass.test.sh" 3 0 0
mkfix_skip "$w/skip.test.sh" "skip"
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -qF 'Suites skipped: 1' <<<"$out" \
   && grep -qF 'skip.test.sh' <<<"$out" \
   && grep -qF 'Suites passed: 1' <<<"$out"; then
  ok "skip-report: one skip + one pass → exit 0, Suites skipped=1 named, Suites passed=1"
else no "skip-report failed: rc=$rc :: $(grep -iE 'Suites (passed|skipped|failed)|skip\.test' <<<"$out" | tr '\n' ' ')"; fi

# 11 — all-skip: when every suite signals SKIP and none pass, the run must not
#      exit 0 (a fully-skipped run must not read as "all green").
w="$(newdir c11)"
mkfix_skip "$w/s1.test.sh" "s1"
mkfix_skip "$w/s2.test.sh" "s2"
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] \
   && grep -qF 'Suites skipped: 2' <<<"$out" \
   && grep -qF 'Suites passed: 0' <<<"$out"; then
  ok "all-skip: all suites skip → exit 1 (no coverage), Suites skipped=2"
else no "all-skip failed: rc=$rc :: $(grep -iE 'Suites (passed|skipped|failed)' <<<"$out" | tr '\n' ' ')"; fi

# 12 — pcap-format: corroborate-pcap.test.sh and pcap-flows.test.sh must emit SKIP:
#       (canonical whole-suite format recognized by run-all.sh) when tshark, capinfos,
#       or bwrap are absent. RED before normalizing those two suites; GREEN after.
#       Approach: build a minimal clean-bin PATH (no pcap tools), stub out the SUTs so
#       the harness check passes, then run the real suites through a copy of run-all.sh.
_c12root="$TMP/c12pfix"; mkdir -p "$_c12root/tests"
cp "$SUT" "$_c12root/tests/run-all.sh"
cp "$HERE/corroborate-pcap.test.sh" "$_c12root/tests/"
cp "$HERE/pcap-flows.test.sh" "$_c12root/tests/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_c12root/corroborate-pcap.sh"; chmod +x "$_c12root/corroborate-pcap.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_c12root/pcap-flows.sh";      chmod +x "$_c12root/pcap-flows.sh"
touch "$_c12root/analysis_manifest.py"
_c12bin="$TMP/c12bin"; mkdir -p "$_c12bin"
for _c in bash dirname sort mktemp tee grep rm basename; do
  _p="$(command -v "$_c" 2>/dev/null)"
  [ -n "$_p" ] && ln -s "$_p" "$_c12bin/$_c" 2>/dev/null || true
done
out="$(PATH="$_c12bin" bash "$_c12root/tests/run-all.sh" 2>&1)"
if grep -qF 'Suites skipped: 2' <<<"$out" \
   && grep -qF 'Suites passed: 0' <<<"$out"; then
  ok "pcap-format: pcap suites classified as SKIPPED when tshark/capinfos/bwrap absent"
else
  no "pcap-format: expected skipped=2/passed=0; got: $(grep -E 'Suites (passed|skipped)' <<<"$out" | tr '\n' ' ')"
fi

# 13 — per-test-skip-agg: per-test "  SKIP  " lines (tool-env T5, capa T14, etc.) must be
#       counted and reported as "Test cases skipped: N" in the aggregate summary.
#       RED before adding total_skipped to run-all.sh; GREEN after.
w="$(newdir c13)"
{ printf '#!/usr/bin/env bash\n'
  printf 'echo "  SKIP  T5: unzip absent"\n'
  printf 'echo "  SKIP  T12: too fast"\n'
  printf 'echo "== 3 passed %s 0 failed =="\n' "$MID"
  printf 'exit 0\n'
} > "$w/partial-skip.test.sh"
out="$(bash "$w/run-all.sh" 2>&1)"
if grep -qF 'Test cases skipped: 2' <<<"$out"; then
  ok "per-test-skip-agg: 2 per-test SKIP lines → 'Test cases skipped: 2' in aggregate"
else
  no "per-test-skip-agg: 'Test cases skipped: 2' absent; got: $(grep 'Test cases skipped' <<<"$out" || echo '<absent>')"
fi

# 14 — malformed-summary: fixture emits a slash-separated line (not middle-dot); runner names it
#       and fails. Message must contain "malformed" (distinct from "no summary line").
w="$(newdir c14)"
mkfix_sh "$w/ok.test.sh" 2 0 0
{ printf '#!/usr/bin/env bash\n'
  printf 'echo "== 3 passed / 2 failed =="\n'
  printf 'exit 0\n'
} > "$w/malformed.test.sh"
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -qF 'malformed.test.sh' <<<"$out" && grep -qiF 'malformed' <<<"$out"; then
  ok "malformed-summary: runner names the suite and fails with 'malformed' in message"
else no "malformed-summary failed: rc=$rc :: $(grep -iE 'malformed|failed suite' <<<"$out" | tr '\n' ' ')"; fi

# 15 — no-summary-line: fixture emits output but no summary-like line; runner names it distinctly
#       and fails. Message must contain "no summary" and must NOT contain "malformed".
w="$(newdir c15)"
mkfix_sh "$w/ok.test.sh" 2 0 0
{ printf '#!/usr/bin/env bash\n'
  printf 'echo "some output but no summary"\n'
  printf 'exit 0\n'
} > "$w/nosummary.test.sh"
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -qF 'nosummary.test.sh' <<<"$out" && grep -qF 'no summary' <<<"$out" \
   && ! grep -qF 'malformed' <<<"$out"; then
  ok "no-summary-line: runner names suite, fails with 'no summary' (distinct from malformed)"
else no "no-summary-line failed: rc=$rc :: $(grep -iE 'nosummary|no summary|malformed' <<<"$out" | tr '\n' ' ')"; fi

# 16 — no-output: fixture exits 0 with absolutely no output; runner names it distinctly and fails.
#       Message must contain "no output" and must NOT contain "no summary".
w="$(newdir c16)"
mkfix_sh "$w/ok.test.sh" 2 0 0
{ printf '#!/usr/bin/env bash\n'
  printf 'exit 0\n'
} > "$w/noout.test.sh"
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -qF 'noout.test.sh' <<<"$out" && grep -qF 'no output' <<<"$out" \
   && ! grep -qF 'no summary' <<<"$out"; then
  ok "no-output: runner names suite, fails with 'no output' (distinct from no-summary-line)"
else no "no-output failed: rc=$rc :: $(grep -iE 'noout|no output|no summary' <<<"$out" | tr '\n' ' ')"; fi

# 17 — skip-no-summary: a SKIP suite with no canonical summary is classified as skipped,
#       NOT as unparsed. The new guard must not fire on the skip route.
w="$(newdir c17)"
mkfix_sh "$w/ok.test.sh" 2 0 0
{ printf '#!/usr/bin/env bash\n'
  printf 'echo "SKIP: test-tool absent"\n'
  printf 'exit 0\n'
} > "$w/skipnosummary.test.sh"
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -qF 'Suites skipped: 1' <<<"$out" \
   && grep -qF 'skipnosummary.test.sh' <<<"$out" \
   && ! grep -qF 'no summary' <<<"$out" \
   && ! grep -qF 'no output' <<<"$out"; then
  ok "skip-no-summary: skip suite without canonical summary is skipped, not unparsed (guard does not misfire)"
else no "skip-no-summary failed: rc=$rc :: $(grep -iE 'Suites (passed|skipped)|no summary|no output' <<<"$out" | tr '\n' ' ')"; fi

# 18 — zero-case: a non-skip suite that reports a valid 0/0 summary must be named as
#       failed and must not increment suites_ok. A normal passing peer remains passing.
w="$(newdir c18)"
if zero_case_oracle "$w/run-all.sh" "$w"; then
  ok "zero-case: valid 0/0 non-skip suite is named, fails run, and does not increment suites_ok"
else no "zero-case failed: rc=$ORACLE_RC :: $(grep -iE 'Suites (passed|failed)|zero\.test' <<<"$ORACLE_OUT" | tr '\n' ' ')"; fi

# NEGATIVE CONTROL — neuter the runner's PIPESTATUS capture; a failing fixture must then FALSE-PASS
# (runner exits 0). If it does, our exit-code assertions (cases 2/3/6) have real teeth.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter run-all.sh's PIPESTATUS capture (rc=0); a failing fixture must FALSE-PASS --"
  w="$TMP/teeth"; mkdir -p "$w"
  # Force every suite's captured exit code to 0, regardless of what the suite actually returned.
  sed 's#rc=${PIPESTATUS\[0\]}#rc=0#g' "$SUT" > "$w/run-all.sh"
  mkfix_sh "$w/ok.test.sh"  1 0 0
  mkfix_sh "$w/bad.test.sh" 0 1 1
  bash "$w/run-all.sh" >/dev/null 2>&1; mrc=$?
  if [ "$mrc" -eq 0 ]; then ok "teeth: PIPESTATUS-neutered mutant reports green despite a failing fixture → exit-code teeth real"
  else no "teeth: mutant still failed (rc=$mrc) — PIPESTATUS mutation not exercised (THEATER)"; fi
  # Mutation 2: neuter the unparsed-summary guard → malformed/no-summary fixtures must FALSE-PASS.
  echo "-- teeth: neuter unparsed guard (elif false); malformed+no-summary must FALSE-PASS --"
  w="$TMP/teeth-unparsed"; mkdir -p "$w"
  sed 's/elif \[\[ -z "\$parsed_line" \]\]; then/elif false; then/' "$SUT" > "$w/run-all.sh"
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "== 3 passed / 2 failed =="\n'
    printf 'exit 0\n'
  } > "$w/malformed.test.sh"
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "some output but no summary"\n'
    printf 'exit 0\n'
  } > "$w/nosummary.test.sh"
  bash "$w/run-all.sh" >/dev/null 2>&1; mrc=$?
  if [ "$mrc" -eq 0 ]; then
    ok "teeth-unparsed: neutered guard lets malformed+no-summary FALSE-PASS → guard has real teeth"
  else
    no "teeth-unparsed: mutant still failed (rc=$mrc) — guard mutation not exercised (THEATER)"
  fi
  # Mutation 3: neuter total_skipped counter → C13 per-test-skip aggregation teeth.
  echo "-- teeth: zero-out total_skipped counter; per-test skip count must not show 1 --"
  w="$TMP/teeth-skip"; mkdir -p "$w"
  sed 's/total_skipped=\$((total_skipped + 1))/: # neutered/' "$SUT" > "$w/run-all.sh"
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "  SKIP  T5: skip me"\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
    printf 'exit 0\n'
  } > "$w/skip.test.sh"
  sout="$(bash "$w/run-all.sh" 2>&1)"
  if ! grep -qF 'Test cases skipped: 1' <<<"$sout"; then
    ok "teeth-skip: neutered counter does not report 1 skipped → per-test-skip teeth real"
  else
    no "teeth-skip: neutered counter still shows 1 skipped — aggregation teeth absent (THEATER)"
  fi
  # Mutation 4: neuter the zero-case branch and execute the same oracle as C18.
  echo "-- teeth: neuter zero-case guard; the C18 behavioral oracle must go RED --"
  w="$TMP/teeth-zero"; mkdir -p "$w"
  zero_anchor='  elif [[ -n "$parsed_line" && "$rc" -eq 0 && "$s_passed" -eq 0 && "$s_failed" -eq 0 ]]; then'
  zero_anchor_count="$(grep -Fxc -- "$zero_anchor" "$SUT")"
  sed 's#  elif \[\[ -n "$parsed_line" && "$rc" -eq 0 && "$s_passed" -eq 0 && "$s_failed" -eq 0 \]\]; then#  elif { : > "$SCRIPT_DIR/zero-mutant-executed"; false; }; then#' "$SUT" > "$w/run-all.sh"
  if [ "$zero_anchor_count" -ne 1 ]; then
    no "teeth-zero: mutation anchor cardinality=$zero_anchor_count (want exactly 1)"
  elif cmp -s "$SUT" "$w/run-all.sh"; then
    no "teeth-zero: mutation was a byte-identical no-op"
  elif zero_case_oracle "$w/run-all.sh" "$w"; then
    no "teeth-zero: neutered guard still satisfies zero-case oracle (THEATER)"
  elif [ ! -f "$w/zero-mutant-executed" ]; then
    no "teeth-zero: mutant predicate was not executed"
  else
    ok "teeth-zero: anchor=1, bytes changed, mutant executed, same zero-case oracle went RED"
  fi
fi

echo "== $pass passed $MID $fail failed =="
[ "$fail" -eq 0 ] || exit 1

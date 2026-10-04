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
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
TMP="$(mktemp -d)"
# Files a case chmods to 000: registered here so the EXIT trap restores them even when the case dies
# before its own restore line (a leftover 000 file would otherwise break cleanup and later runs).
LOCKED_FILES=()
_cleanup(){ local f; for f in "${LOCKED_FILES[@]}"; do chmod 644 "$f" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap _cleanup EXIT
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
# newdir <case-name> — kit issue #1144 review, hardened: builds a REPO-SHAPED tree at
# $TMP/<case-name>/research-sdd/toolbelt/tests (SUT copied there), with NO research-sdd/install
# directory at all by default. MUST be nested two levels like the real repo — a shallow
# $TMP/<case-name>/run-all.sh placement (the pre-#1144-review shape) makes the SUT's own
# SCRIPT_DIR/../../install/tests resolution climb OUT of $TMP entirely (to $TMP's own parent,
# i.e. the shared /tmp namespace), which is unstable: whether /tmp/install/tests exists depends
# on what else is running on the host, not on anything this suite controls. Nesting properly
# keeps every case's install-tests resolution fully inside its own isolated $TMP. Returns the
# toolbelt/tests path (where the SUT lives).
newdir(){ # case-name
  local root="$TMP/$1/research-sdd/toolbelt/tests"
  mkdir -p "$root"
  cp "$SUT" "$root/run-all.sh"
  # Kit issue #1144 review finding #2 made an ABSENT install-tests corpus a hard gate failure
  # (nonzero exit), which is correct for the REAL repo but would otherwise force every OTHER
  # case in this file — none of which care about the install corpus — to also stand up an
  # install/tests sibling just to avoid an unrelated ABSENT-INPUT failure. So newdir() creates
  # an EMPTY install/tests sibling by default (the non-failing "= 0" state, §7); only cases 30-32
  # below deliberately deviate from that default to exercise present/empty/absent explicitly.
  mkdir -p "$(install_dir_for "$root")"
  printf '%s' "$root"
}
# install_dir_for <toolbelt-tests-path> — the research-sdd/install/tests sibling of a newdir()
# result, mirroring the SUT's own SCRIPT_DIR/../../install/tests resolution.
install_dir_for(){ printf '%s' "${1%/toolbelt/tests}/install/tests"; }
# mut_workdir <name> — same nested-repo-shape + empty-install-sibling guarantee as newdir(), for
# the --prove-teeth blocks below that build their OWN mutant run-all.sh (sed/cp) directly into a
# fresh workdir instead of going through newdir(). Does NOT copy $SUT — callers write $w/run-all.sh
# themselves.
mut_workdir(){ # name
  local root="$TMP/$1/research-sdd/toolbelt/tests"
  mkdir -p "$root"
  mkdir -p "$(install_dir_for "$root")"
  printf '%s' "$root"
}
# A suite WITH teeth: handles --prove-teeth AND emits a "-- teeth:" banner.
mkfix_teeth(){ # file
  local f="$1"
  { printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = "--prove-teeth" ]; then\n'
    printf '  echo "-- teeth: fixture mutation control --"\n'
    printf '  echo "  PASS  teeth-fixture: mutant verified --"\n'
    printf 'fi\n'
    printf 'echo "== 2 passed %s 0 failed =="\n' "$MID"
    printf 'exit 0\n'
  } > "$f"
}
# A suite that handles --prove-teeth but emits NO "-- teeth:" banner (no-banner category).
mkfix_teeth_nobanner(){ # file
  local f="$1"
  { printf '#!/usr/bin/env bash\n'
    printf '# PROVE_TEETH handled — but no banner line emitted\n'
    printf 'if [ "${1:-}" = "--prove-teeth" ]; then\n'
    printf '  echo "  PASS  prove-teeth: handled (no banner)"\n'
    printf 'fi\n'
    printf 'echo "== 2 passed %s 0 failed =="\n' "$MID"
    printf 'exit 0\n'
  } > "$f"
}
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

# 9 — an unknown token in ANY position is refused (exit 2, "unknown flag") and no suite runs: a typo
#     after a valid flag (`-j 2 --prove-teath`) must not silently drop teeth and report green.
w="$(newdir c9)"
{ printf '#!/usr/bin/env bash\n'
  printf ': > "%s"\n' "$TMP/c9-ran.txt"
  printf 'echo "== 3 passed %s 0 failed =="\n' "$MID"
} > "$w/rec.test.sh"
_c9bad=""
for _a in "garbage" "--prove-teeth garbage" "--prove-teeth --prove-teath" "-j 2 --prove-teath" "--prove-teeth -j 2 garbage" "-j 2 --prove-teeth garbage"; do
  rm -f "$TMP/c9-ran.txt"
  # shellcheck disable=SC2086
  out="$(bash "$w/run-all.sh" $_a 2>&1)"; rc=$?
  if [ "$rc" -ne 2 ] || ! grep -qF 'unknown flag:' <<<"$out" || [ -e "$TMP/c9-ran.txt" ]; then _c9bad="$_c9bad [$_a rc=$rc]"; fi
done
if [ -z "$_c9bad" ]; then ok "unknown-flag: an unknown token in first/middle/last position exits 2 and runs nothing"
else no "unknown-flag regressed:$_c9bad"; fi

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

# 19 — prove-teeth banner: the no-teeth suite is listed; the clause and node-n/a line appear.
w="$(newdir c19)"
mkfix_sh    "$w/nt.test.sh" 3 0 0  # no teeth — mkfix_sh never handles --prove-teeth
mkfix_teeth "$w/wt.test.sh"        # has teeth banner
out="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"
if grep -qF "Suites without teeth: 1 — [nt]" <<<"$out" \
   && grep -qF '(vocabulary check:' <<<"$out" \
   && grep -qF 'Suites n/a for teeth (node):' <<<"$out"; then
  ok "prove-teeth-banner: no-teeth suite listed, clause present, node-n/a line present"
else no "prove-teeth-banner failed: $(grep -iE 'Suites without|vocabulary|n.a for' <<<"$out" | tr '\n' '|')"; fi

# 20 — require-teeth: exits 1 when there are no-teeth suites.
w="$(newdir c20)"
mkfix_sh    "$w/nt.test.sh" 3 0 0
mkfix_teeth "$w/wt.test.sh"
out="$(bash "$w/run-all.sh" --require-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'Suites without teeth: 1' <<<"$out"; then
  ok "--require-teeth: exits 1 when no-teeth suites exist"
else no "--require-teeth-fail: rc=$rc :: $(grep 'Suites without' <<<"$out" | tr '\n' ' ')"; fi

# 21 — require-teeth: exits 0 when all suites have teeth (no-teeth list is empty).
w="$(newdir c21)"
mkfix_teeth "$w/wt1.test.sh"; printf '. "$HERE/lib/mutant.sh"\n' >> "$w/wt1.test.sh"
mkfix_teeth "$w/wt2.test.sh"; printf '. "$HERE/lib/mutant.sh"\n' >> "$w/wt2.test.sh"
out="$(bash "$w/run-all.sh" --require-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'Suites without teeth: 0 — []' <<<"$out"; then
  ok "--require-teeth: exits 0 when all suites have teeth"
else no "--require-teeth-ok: rc=$rc :: $(grep 'Suites without' <<<"$out" | tr '\n' ' ')"; fi

# 22 — with-teeth-but-no-banner: a suite that handles --prove-teeth but emits no banner
#       must appear in the "Suites with teeth but no banner" line, not in "without teeth".
w="$(newdir c22)"
mkfix_sh          "$w/nt.test.sh"  3 0 0  # truly no teeth
mkfix_teeth       "$w/wt.test.sh"          # has teeth banner
mkfix_teeth_nobanner "$w/nb.test.sh"       # handles flag, no banner
out="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"
if grep -qF 'Suites without teeth: 1 — [nt]' <<<"$out" \
   && grep -qF 'Suites with teeth but no banner: 1' <<<"$out" \
   && grep -qF 'nb' <<<"$(grep 'but no banner' <<<"$out")"; then
  ok "with-teeth-no-banner: no-banner suite in its own category, not counted as no-teeth"
else no "with-teeth-no-banner failed: $(grep -iE 'Suites without|but no banner' <<<"$out" | tr '\n' '|')"; fi

# 23 — hermeticity (kit issue #1032, hardened per #1118 review): a suite that leaks a stray
#      NEW top-level file into the CALLER's cwd (not $SCRIPT_DIR — suites run via `bash
#      "$suite"` with no cd, so an unguarded redirection lands wherever run-all.sh itself was
#      invoked from) is detected, named "(new)", and fails the run. Neither a clean suite
#      running BEFORE the leak (clean.test.sh, sorts first) NOR one running AFTER it
#      (z-clean.test.sh, sorts last — this is what actually exercises baseline rollforward,
#      since a suite running before a leak can never be blamed by construction) is blamed, and
#      the violation count is EXACTLY 1 (not re-counted against every later suite). Runs from a
#      dedicated empty cwd so the leak (and its cleanup) stay contained.
w="$(newdir c23)"
mkfix_sh "$w/clean.test.sh" 2 0 0
{ printf '#!/usr/bin/env bash\n'
  printf 'echo oops > stray-c23.txt\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  printf 'exit 0\n'
} > "$w/leaky.test.sh"
mkfix_sh "$w/z-clean.test.sh" 1 0 0
_c23cwd="$TMP/c23-cwd"; mkdir -p "$_c23cwd"
out="$(cd "$_c23cwd" && bash "$w/run-all.sh" 2>&1)"; rc=$?
_c23_hv="$(grep -F 'leaked:' <<<"$out")"
_c23_hv_count="$(grep -cF 'leaked:' <<<"$out" 2>/dev/null || echo 0)"
if [ "$rc" -ne 0 ] \
   && grep -qF 'Hermeticity violations (new/modified/removed top-level entries in caller cwd): 1' <<<"$out" \
   && [ "$_c23_hv_count" -eq 1 ] \
   && grep -qF 'leaky.test.sh leaked: stray-c23.txt (new)' <<<"$_c23_hv" \
   && ! grep -qF 'clean.test.sh leaked:' <<<"$_c23_hv" \
   && ! grep -qF 'z-clean.test.sh leaked:' <<<"$_c23_hv"; then
  ok "hermeticity: leaky.test.sh's new stray top-level cwd file is detected, named, run fails; neither clean.test.sh nor z-clean.test.sh (sorts after) is blamed; exactly 1 violation"
else no "hermeticity failed: rc=$rc :: $(tr '\n' '|' <<<"$_c23_hv")"; fi
rm -f "$_c23cwd/stray-c23.txt" 2>/dev/null || true

# 24 — hermeticity-clean: an all-clean batch reports zero violations and does not fail on
#      their account (the guard must not misfire on suites that behave).
w="$(newdir c24)"
mkfix_sh "$w/a.test.sh" 2 0 0
mkfix_sh "$w/b.test.sh" 1 0 0
_c24cwd="$TMP/c24-cwd"; mkdir -p "$_c24cwd"
out="$(cd "$_c24cwd" && bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'Hermeticity violations (new/modified/removed top-level entries in caller cwd): 0' <<<"$out"; then
  ok "hermeticity-clean: all-clean batch → 0 violations, run still exits 0"
else no "hermeticity-clean failed: rc=$rc :: $(grep -i 'hermeticity' <<<"$out" | tr '\n' '|')"; fi

# 25 — hermeticity-modify (kit issue #1118 review finding #2): the guard also catches an
#      OVERWRITE of a pre-existing top-level entry, and a SECOND leak onto a name that a prior
#      suite already leaked (the exact #1032 state: two leaks onto the same stray name `git`,
#      not just the first). Both are name+size+mtime changes, reported "(modified)".
w="$(newdir c25)"
{ printf '#!/usr/bin/env bash\n'
  printf 'echo overwritten-by-modifier > preexisting.txt\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  printf 'exit 0\n'
} > "$w/modifier.test.sh"
{ printf '#!/usr/bin/env bash\n'
  printf 'echo second-leak-same-name > stray-c25.txt\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  printf 'exit 0\n'
} > "$w/a-first-leak.test.sh"
{ printf '#!/usr/bin/env bash\n'
  printf 'sleep 1.1; echo re-leaked-different-size > stray-c25.txt\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  printf 'exit 0\n'
} > "$w/z-second-leak.test.sh"
_c25cwd="$TMP/c25-cwd"; mkdir -p "$_c25cwd"
printf 'original content' > "$_c25cwd/preexisting.txt"
out="$(cd "$_c25cwd" && bash "$w/run-all.sh" 2>&1)"; rc=$?
_c25_hv="$(grep -F 'leaked:' <<<"$out")"
rm -f "$_c25cwd/preexisting.txt" "$_c25cwd/stray-c25.txt" 2>/dev/null || true
if [ "$rc" -ne 0 ] \
   && grep -qF 'modifier.test.sh leaked: preexisting.txt (modified)' <<<"$_c25_hv" \
   && grep -qF 'a-first-leak.test.sh leaked: stray-c25.txt (new)' <<<"$_c25_hv" \
   && grep -qF 'z-second-leak.test.sh leaked: stray-c25.txt (modified)' <<<"$_c25_hv"; then
  ok "hermeticity-modify: overwrite of a pre-existing entry AND a second leak onto an already-leaked name are both caught, attributed to the right suite"
else no "hermeticity-modify failed: rc=$rc :: $(tr '\n' '|' <<<"$_c25_hv")"; fi

# 26 — hermeticity-removed: a suite that DELETES a pre-existing top-level entry is caught too.
w="$(newdir c26)"
{ printf '#!/usr/bin/env bash\n'
  printf 'rm -f will-be-deleted.txt\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  printf 'exit 0\n'
} > "$w/deleter.test.sh"
_c26cwd="$TMP/c26-cwd"; mkdir -p "$_c26cwd"
printf 'gone soon' > "$_c26cwd/will-be-deleted.txt"
out="$(cd "$_c26cwd" && bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -qF 'deleter.test.sh leaked: will-be-deleted.txt (removed)' <<<"$out"; then
  ok "hermeticity-removed: deletion of a pre-existing top-level entry is caught and attributed"
else no "hermeticity-removed failed: rc=$rc :: $(grep -F 'leaked:' <<<"$out" | tr '\n' '|')"; fi

# 27 — hermeticity-degraded (kit issue #1118 review finding #3, §7 three-state doctrine): an
#      unreadable caller cwd must report a typed DEGRADED state, not a confident "0 violations"
#      (an unreadable cwd cannot be verified clean — that is absent-input, not empty-input).
#      Root cannot be locked out of its own files, so this case SKIPs under root (CI images).
#      Enters the dir WHILE readable (so cd/pwd resolve), then chmod's it 000 from inside — an
#      already-open cwd's OWN readdir/find calls still hit EACCES against the revoked bits,
#      while `pwd`'s getcwd() does not need to re-read the leaf, so the invocation still lands
#      with $(pwd) == the now-locked directory, exactly reproducing an unreadable caller cwd.
w="$(newdir c27)"
mkfix_sh "$w/a.test.sh" 1 0 0
if [ "$(id -u)" -eq 0 ]; then
  ok "hermeticity-degraded: SKIP under root (root ignores directory permission bits)"
else
  _c27cwd="$TMP/c27-cwd"; mkdir -p "$_c27cwd"
  out="$(cd "$_c27cwd" && chmod 000 "$_c27cwd" && bash "$w/run-all.sh" 2>&1)"; rc=$?
  chmod 755 "$_c27cwd" 2>/dev/null || true
  rm -rf "$_c27cwd" 2>/dev/null || true
  # kit issue #1121 (#1118 review finding #1): the AGGREGATE's own "Hermeticity: DEGRADED — ..."
  # line must name THIS guard specifically (an unreadable directory), not a scanner failure — the
  # two guards are distinct causes and the aggregate used to print one hardcoded reason string
  # regardless of which fired. Isolate the aggregate line itself (^Hermeticity: DEGRADED) rather
  # than grepping the whole output, which also contains the (always-correct) per-branch stderr
  # WARNING line and would pass even against the pre-fix aggregate.
  _c27agg_line="$(grep -E '^Hermeticity: DEGRADED' <<<"$out")"
  if [ "$rc" -ne 0 ] && grep -qF 'Hermeticity: DEGRADED' <<<"$out" && ! grep -qF 'Hermeticity violations' <<<"$out" \
     && grep -qF 'readable/traversable directory' <<<"$_c27agg_line" && ! grep -qF 'cwd scanner' <<<"$_c27agg_line"; then
    ok "hermeticity-degraded: unreadable caller cwd reports DEGRADED with the unreadable-directory reason (not a confident 0, not the scanner's reason)"
  else no "hermeticity-degraded failed: rc=$rc :: $(grep -iF 'hermeticity' <<<"$out" | tr '\n' '|')"; fi
fi

# 28 — hermeticity-git-status (kit issue #1118 round-2 review, HIGH/blocking): a suite that runs
#      `git status` against a PRE-EXISTING git repo already in the caller's cwd (i.e. baseline,
#      not something the suite itself created) must report ZERO violations, even though that
#      call opportunistically refreshes the index (lock+rename), which bumps `.git/`'s own
#      mtime. Directories are tracked by NAME ONLY (existence), never mtime, precisely so this
#      legitimate, read-adjacent operation is not misread as a leak. This is the exact scenario
#      that failed a full-aggregate run from a non-worktree checkout root in the round-2 review
#      (the reviewer's clone root, with `.git` already present, not created by the run).
w="$(newdir c28)"
{ printf '#!/usr/bin/env bash\n'
  printf 'git status --porcelain >/dev/null\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  printf 'exit 0\n'
} > "$w/gitstatus.test.sh"
_c28cwd="$TMP/c28-cwd"; mkdir -p "$_c28cwd"
( cd "$_c28cwd" \
  && git init -q . \
  && git config user.email t@example.com \
  && git config user.name tester \
  && printf x > f.txt \
  && git add -A && git commit -qm init \
  && touch f.txt )   # touch f.txt: force a stat mismatch so status has something to refresh
out="$(cd "$_c28cwd" && bash "$w/run-all.sh" 2>&1)"; rc=$?
rm -rf "$_c28cwd" 2>/dev/null || true
if [ "$rc" -eq 0 ] \
   && grep -qF 'Hermeticity violations (new/modified/removed top-level entries in caller cwd): 0' <<<"$out"; then
  ok "hermeticity-git-status: git status against a pre-existing repo in cwd does not trip the guard (directories tracked by name only)"
else no "hermeticity-git-status failed: rc=$rc :: $(grep -iF 'hermeticity' <<<"$out" | tr '\n' '|')"; fi

# 29 — hermeticity-scanner-degraded (kit issue #1118 round-2 review, MEDIUM, §7 "could it run at
#      all"): a `find` that rejects `-printf` (as BSD/macOS find does — the flag is a GNU
#      extension) must make the guard report DEGRADED, not silently scan as if the cwd were
#      empty. Shadows PATH with a stub `find` that errors on `-printf` and delegates everything
#      else to the real binary, so suite discovery (glob-based, not find) is unaffected.
_c29realfind="$(command -v find)"
if [ -z "$_c29realfind" ]; then
  ok "hermeticity-scanner-degraded: SKIP — no real 'find' on PATH to build the stub from"
else
  w="$(newdir c29)"
  mkfix_sh "$w/a.test.sh" 1 0 0
  { printf '#!/usr/bin/env bash\n'
    printf 'for _a in "$@"; do\n'
    printf '  if [ "$_a" = "-printf" ]; then echo "find: unknown primary or operator" >&2; exit 1; fi\n'
    printf 'done\n'
    printf 'exec %s "$@"\n' "$_c29realfind"
  } > "$TMP/c29-bin-find"
  _c29bin="$TMP/c29-bin"; mkdir -p "$_c29bin"
  mv "$TMP/c29-bin-find" "$_c29bin/find"; chmod +x "$_c29bin/find"
  _c29cwd="$TMP/c29-cwd"; mkdir -p "$_c29cwd"
  out="$(cd "$_c29cwd" && PATH="$_c29bin:$PATH" bash "$w/run-all.sh" 2>&1)"; rc=$?
  rm -rf "$_c29cwd" "$_c29bin" 2>/dev/null || true
  # kit issue #1121 (#1118 review finding #1): the AGGREGATE's own "Hermeticity: DEGRADED — ..."
  # line must name THIS guard specifically (the scanner), not the unreadable-directory guard's
  # reason. Isolate the aggregate line itself, same rationale as case 27 above.
  _c29agg_line="$(grep -E '^Hermeticity: DEGRADED' <<<"$out")"
  if [ "$rc" -ne 0 ] && grep -qF 'Hermeticity: DEGRADED' <<<"$out" && ! grep -qF 'Hermeticity violations' <<<"$out" \
     && grep -qF 'cwd scanner' <<<"$_c29agg_line" && ! grep -qF 'readable/traversable directory' <<<"$_c29agg_line"; then
    ok "hermeticity-scanner-degraded: a find that rejects -printf makes the guard DEGRADED with the scanner-failure reason (not a confident 0, not the unreadable-directory reason)"
  else no "hermeticity-scanner-degraded failed: rc=$rc :: $(grep -iF 'hermeticity' <<<"$out" | tr '\n' '|')"; fi
fi

# 30/31/32 — install-tests corpus present / empty / absent (kit issue #1126/#1144 review: no case
# pinned any of these three §7 states before this — the absent path only ran as a side effect of
# every OTHER case's SCRIPT_DIR/../../install/tests happening to resolve outside $TMP).

# 30 — present: install/tests exists with 1 real suite -> discovered, run, and counted.
w="$(newdir c30)"
mkfix_sh "$w/a.test.sh" 1 0 0
_c30_install="$(install_dir_for "$w")"
mkdir -p "$_c30_install"
mkfix_sh "$_c30_install/b.test.sh" 1 0 0
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -qE 'Corpus: install tests \([^)]*\) = 1 suite\(s\)' <<<"$out" \
   && grep -qF 'Suites run:    2' <<<"$out" \
   && grep -qF 'Suites passed: 2' <<<"$out"; then
  ok "install-present: install/tests suite is discovered, run, and counted (corpus=1, suites run=2)"
else no "install-present failed: rc=$rc :: $(grep -E 'Corpus:|Suites run|Suites passed' <<<"$out" | tr '\n' '|')"; fi

# 31 — empty: install/tests exists but has 0 *.test.sh/*.test.mjs files -> "= 0", distinct from
# ABSENT-INPUT, and does NOT fail the run by itself (the toolbelt suite alone still passes it).
w="$(newdir c31)"
mkfix_sh "$w/a.test.sh" 1 0 0
_c31_install="$(install_dir_for "$w")"
mkdir -p "$_c31_install"
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -qE 'Corpus: install tests \([^)]*\) = 0 suite\(s\)' <<<"$out" \
   && ! grep -qF 'ABSENT-INPUT' <<<"$out" \
   && grep -qF 'Suites run:    1' <<<"$out"; then
  ok "install-empty: install/tests exists with 0 suites -> corpus reports '= 0' (distinct from absent), run still succeeds"
else no "install-empty failed: rc=$rc :: $(grep -E 'Corpus:|Suites run|ABSENT' <<<"$out" | tr '\n' '|')"; fi

# 32 — absent: research-sdd/install/tests does not exist at all -> ABSENT-INPUT reported AND the
# run exits non-zero even though the only discovered (toolbelt) suite passed (kit issue #1144:
# a moved/renamed install corpus must fail the gate loudly, not silently pass on the toolbelt
# corpus alone — the opposite of case 31's legitimately-empty directory).
w="$(newdir c32)"
mkfix_sh "$w/a.test.sh" 1 0 0
# newdir() creates an empty install/tests sibling by default (see its own comment) — remove the
# whole research-sdd/install parent here so this case genuinely exercises ABSENT, not empty.
rm -rf "$(dirname "$(install_dir_for "$w")")"
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] \
   && grep -qF 'Corpus: install tests — ABSENT-INPUT' <<<"$out" \
   && grep -qF 'Suites passed: 1' <<<"$out"; then
  ok "install-absent: research-sdd/install/tests missing -> ABSENT-INPUT reported, run exits non-zero despite the toolbelt suite passing"
else no "install-absent failed: rc=$rc :: $(grep -E 'Corpus:|ABSENT|Suites passed' <<<"$out" | tr '\n' '|')"; fi

# 33 — hermeticity-scanner-stderr-noise (kit issue #1142 review NIT, #1118 review NIT): a find
#      that SUCCEEDS (rc=0) but also prints a harmless warning to stderr must not have that
#      warning line misread as a phantom top-level cwd entry. Stubs find to print one stderr
#      line then delegate to the real find with all args unchanged, so the -printf TSV scan
#      itself still succeeds normally — only the extra stderr noise is new.
#      kit issue #1142 review round 3 (finding #5): the warning text used to be a CONSTANT
#      string, identical on every invocation — the baseline scan and every per-suite scan would
#      then capture the SAME text either way (stdout-only or the old buggy stdout+stderr
#      capture), so this case could not actually tell the two implementations apart; it would
#      have passed unchanged even with the pre-fix 2>&1 capture. The warning now includes a
#      changing value (a nanosecond timestamp, same technique Mutation 12 below already uses) so
#      a capture that merges stderr in would see a DIFFERENT line on every scan and misread it as
#      a new/modified top-level entry — only the stdout-only fix stays clean regardless.
_c33realfind="$(command -v find)"
if [ -z "$_c33realfind" ]; then
  ok "hermeticity-scanner-stderr-noise: SKIP — no real 'find' on PATH to build the stub from"
else
  w="$(newdir c33)"
  mkfix_sh "$w/a.test.sh" 1 0 0
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "find: harmless warning $(date +%%s%%N) not an error" >&2\n'
    printf 'exec %s "$@"\n' "$_c33realfind"
  } > "$TMP/c33-bin-find"
  _c33bin="$TMP/c33-bin"; mkdir -p "$_c33bin"
  mv "$TMP/c33-bin-find" "$_c33bin/find"; chmod +x "$_c33bin/find"
  _c33cwd="$TMP/c33-cwd"; mkdir -p "$_c33cwd"
  out="$(cd "$_c33cwd" && PATH="$_c33bin:$PATH" bash "$w/run-all.sh" 2>&1)"; rc=$?
  rm -rf "$_c33cwd" "$_c33bin" 2>/dev/null || true
  if [ "$rc" -eq 0 ] && grep -qF 'Hermeticity violations (new/modified/removed top-level entries in caller cwd): 0' <<<"$out"; then
    ok "hermeticity-scanner-stderr-noise: a find stderr warning on an otherwise-successful scan is not misread as a phantom entry"
  else no "hermeticity-scanner-stderr-noise failed: rc=$rc :: $(grep -iF 'hermeticity' <<<"$out" | tr '\n' '|')"; fi
fi

# 34 — teeth-helper lint (kit issue #943): under --prove-teeth the aggregate names the suites that
#      HAVE teeth (banner or flag handling) but do not source tests/lib/mutant.sh, so hand-rolled
#      mutants cannot hide. A suite that mentions the helper, and a suite without teeth at all,
#      are NOT in that list; the line is informational and never changes the exit code.
w="$(newdir c34)"
mkfix_sh    "$w/nt.test.sh" 3 0 0            # no teeth at all -> own category, not this one
mkfix_teeth "$w/hand.test.sh"                # teeth, hand-rolled mutants
mkfix_teeth_nobanner "$w/handnb.test.sh"     # teeth without banner, hand-rolled
mkfix_teeth "$w/helped.test.sh"
printf '. "$HERE/lib/mutant.sh"\n' >> "$w/helped.test.sh"
out="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"; rc=$?
_c34line="$(grep -F 'not using lib/mutant.sh' <<<"$out")"
if [ "$rc" -eq 0 ] && [ "$_c34line" = 'Suites with teeth not using lib/mutant.sh: 2 — [hand, handnb]' ]; then
  ok "teeth-helper lint: hand-rolled teeth suites named; helper users and no-teeth suites excluded; exit code unchanged"
else no "teeth-helper lint failed: rc=$rc :: line=[$_c34line]"; fi
# 34b — plain run (no --prove-teeth) prints no such line (teeth are not evaluated).
out="$(bash "$w/run-all.sh" 2>&1)"
if ! grep -qF 'not using lib/mutant.sh' <<<"$out"; then ok "teeth-helper lint: absent from a plain run"
else no "teeth-helper lint: line present without --prove-teeth"; fi
# 34c — all teeth suites use the helper -> explicit zero, not a missing line (absent != zero).
w="$(newdir c34c)"
mkfix_teeth "$w/helped.test.sh"
printf '. "$HERE/lib/mutant.sh"\n' >> "$w/helped.test.sh"
out="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"
if grep -qF 'Suites with teeth not using lib/mutant.sh: 0 — []' <<<"$out"; then ok "teeth-helper lint: explicit zero when every teeth suite uses the helper"
else no "teeth-helper lint zero-state failed: $(grep -F 'lib/mutant.sh' <<<"$out" | tr '\n' '|')"; fi

# 34d — lint precision (kit issue #1299 item 5): a COMMENT that merely mentions the helper must not
#       satisfy the lint; only a real `.`/`source` line does. Indented and `source` forms count;
#       a comment that happens to contain `; . lib/mutant.sh` does not.
w="$(newdir c34d)"
mkfix_teeth "$w/cmt-only.test.sh"
printf '# shellcheck source=lib/mutant.sh\n# . "$HERE/lib/mutant.sh"\n# a; . "$HERE/lib/mutant.sh"\n' >> "$w/cmt-only.test.sh"
mkfix_teeth "$w/src-dot.test.sh";    printf '  . "$HERE/lib/mutant.sh"\n'      >> "$w/src-dot.test.sh"
mkfix_teeth "$w/src-word.test.sh";   printf 'source "$HERE/lib/mutant.sh"\n'   >> "$w/src-word.test.sh"
mkfix_teeth "$w/src-guard.test.sh";  printf '. "$HERE/lib/mutant.sh" || exit 2\n' >> "$w/src-guard.test.sh"
out="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"
_c34dline="$(grep -F 'not using lib/mutant.sh' <<<"$out")"
if [ "$_c34dline" = 'Suites with teeth not using lib/mutant.sh: 1 — [cmt-only]' ]; then
  ok "teeth-helper lint precision: a comment mentioning the helper is NOT use; indented/source/guarded source lines are"
else no "teeth-helper lint precision failed: line=[$_c34dline]"; fi

# 34e — a LARGE suite that really sources the helper is not listed. Regression found by the full gate:
#       `grep -v | grep -q` under pipefail returns 141 (SIGPIPE to the producer) once the file exceeds
#       the pipe buffer, so every big helper-using suite was mislabelled as a non-user.
w="$(newdir c34e)"
mkfix_teeth "$w/big-helped.test.sh"
printf '. "$HERE/lib/mutant.sh"\n' >> "$w/big-helped.test.sh"
head -c 300000 /dev/zero | tr '\0' 'x' | fold -w 79 | sed 's/^/: filler /' >> "$w/big-helped.test.sh"
out="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"
if grep -qF 'Suites with teeth not using lib/mutant.sh: 0 — []' <<<"$out"; then
  ok "teeth-helper lint: a large suite that sources the helper is not misreported (no SIGPIPE under pipefail)"
else no "teeth-helper lint large-suite failed: $(grep -F 'lib/mutant.sh' <<<"$out" | tr '\n' '|')"; fi

# 34f — lint recognition (kit issue #1299 review): one level of VAR=...lib/mutant.sh indirection
#       (mutant.test.sh uses LIB="${MUTANT_LIB:-$HERE/lib/mutant.sh}" + `. "$LIB"`), and the
#       `then . x` / `; . x` / `&& . x` prefixes, are USE. Not use: a source of a variable never
#       assigned the helper path, a variable assigned only in a comment, and a source line that
#       is just the body of a heredoc.
w="$(newdir c34f)"
mkfix_teeth "$w/via-var.test.sh";  printf 'LIB="${MUTANT_LIB:-$HERE/lib/mutant.sh}"\n. "$LIB"\n' >> "$w/via-var.test.sh"
mkfix_teeth "$w/via-brace.test.sh"; printf 'H=$HERE/lib/mutant.sh\nsource ${H}\n' >> "$w/via-brace.test.sh"
mkfix_teeth "$w/via-then.test.sh"; printf 'if true; then . "$HERE/lib/mutant.sh"; fi\n' >> "$w/via-then.test.sh"
mkfix_teeth "$w/via-and.test.sh";  printf '[ -f x ] && . "$HERE/lib/mutant.sh"\n' >> "$w/via-and.test.sh"
mkfix_teeth "$w/other-var.test.sh"; printf 'LIB=/usr/lib/other.sh\n. "$LIB"\n' >> "$w/other-var.test.sh"
mkfix_teeth "$w/cmt-var.test.sh";  printf '# LIB=$HERE/lib/mutant.sh\n. "$LIB"\n' >> "$w/cmt-var.test.sh"
mkfix_teeth "$w/heredoc.test.sh";  printf 'cat <<EOF\n. "$HERE/lib/mutant.sh"\nEOF\n' >> "$w/heredoc.test.sh"
out="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"
_c34fline="$(grep -F 'not using lib/mutant.sh' <<<"$out")"
if [ "$_c34fline" = 'Suites with teeth not using lib/mutant.sh: 3 — [cmt-var, heredoc, other-var]' ]; then
  ok "teeth-helper lint recognition: VAR indirection and then/;/&& prefixes count; foreign var, comment-only assignment and heredoc body do not"
else no "teeth-helper lint recognition failed: line=[$_c34fline]"; fi

# 35 — kit-tree hermeticity (kit issue #1156): the cwd guard cannot see a suite that writes INTO
#      the repo tree (the install suite wrote research-sdd-install.MUTANT*.sh next to its SUT).
#      The runner also snapshots research-sdd/ (resolved from its own location, never the cwd)
#      around each suite: a new, modified or removed file is a violation, attributed to the suite
#      that was running, and fails the run even though the suite itself passed.
w="$(newdir c35)"; _c35kit="${w%/toolbelt/tests}"
mkdir -p "$_c35kit/install"; printf 'original\n' > "$_c35kit/install/keep.sh"; printf 'doomed\n' > "$_c35kit/install/doomed.sh"
{ printf '#!/usr/bin/env bash\n'
  printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
  printf 'printf x > "$k/install/leak.MUTANT.sh"\n'
  printf 'printf changed-content > "$k/install/keep.sh"\n'
  printf 'rm -f "$k/install/doomed.sh"\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
} > "$w/a-leaky.test.sh"
mkfix_sh "$w/b-clean.test.sh" 1 0 0
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] \
   && grep -qF 'Kit-tree hermeticity violations (new/modified/removed files under research-sdd/): 3' <<<"$out" \
   && grep -qF 'a-leaky.test.sh leaked: install/leak.MUTANT.sh (new)' <<<"$out" \
   && grep -qF 'a-leaky.test.sh leaked: install/keep.sh (modified)' <<<"$out" \
   && grep -qF 'a-leaky.test.sh leaked: install/doomed.sh (removed)' <<<"$out" \
   && ! grep -qF 'b-clean.test.sh leaked' <<<"$out"; then
  ok "kit-tree hermeticity: new/modified/removed files under research-sdd/ named per suite, clean suite not blamed, run fails"
else no "kit-tree hermeticity failed: rc=$rc :: $(grep -iE 'kit-tree|leaked' <<<"$out" | tr '\n' '|')"; fi

# 35b — a clean batch reports an explicit zero (absent != zero) and exits 0.
w="$(newdir c35b)"; mkfix_sh "$w/a.test.sh" 1 0 0
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'Kit-tree hermeticity violations (new/modified/removed files under research-sdd/): 0' <<<"$out"; then
  ok "kit-tree hermeticity: clean batch reports 0 violations, run exits 0"
else no "kit-tree hermeticity clean failed: rc=$rc :: $(grep -iF 'kit-tree' <<<"$out" | tr '\n' '|')"; fi

# 35d — noise that must NOT count (measured on the real tree): rewriting a file with IDENTICAL
#       bytes (new mtime) and python bytecode under __pycache__ are not violations; a same-length
#       change in content IS (hash, not size/mtime).
w="$(newdir c35d)"; _c35dkit="${w%/toolbelt/tests}"
mkdir -p "$_c35dkit/install"; printf 'same\n' > "$_c35dkit/install/fixture.bog"; printf 'aaaa\n' > "$_c35dkit/install/flip.sh"
{ printf '#!/usr/bin/env bash\n'
  printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
  printf 'printf "same\\n" > "$k/install/fixture.bog"\n'
  printf 'mkdir -p "$k/install/__pycache__" && printf x > "$k/install/__pycache__/m.cpython-314.pyc"\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
} > "$w/a-noise.test.sh"
{ printf '#!/usr/bin/env bash\n'
  printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
  printf 'printf "bbbb\\n" > "$k/install/flip.sh"\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
} > "$w/b-flip.test.sh"
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] \
   && grep -qF 'files under research-sdd/): 1' <<<"$out" \
   && grep -qF 'b-flip.test.sh leaked: install/flip.sh (modified)' <<<"$out" \
   && ! grep -qF 'a-noise.test.sh leaked' <<<"$out"; then
  ok "kit-tree hermeticity: identical-bytes rewrite and __pycache__ are ignored; a same-size content change is caught"
else no "kit-tree hermeticity noise failed: rc=$rc :: $(grep -iE 'kit-tree|leaked' <<<"$out" | tr '\n' '|')"; fi

# 35e — symlinks (kit issue #1299 item 7): the guard used `-type f`, so a symlink a suite created,
#       retargeted or removed under research-sdd/ was invisible. Links are tracked by path + target
#       (never followed), dangling ones included; an untouched link is not blamed.
w="$(newdir c35e)"; _c35ekit="${w%/toolbelt/tests}"
mkdir -p "$_c35ekit/install"; printf 'k\n' > "$_c35ekit/install/keep.sh"
ln -s keep.sh "$_c35ekit/install/stable.lnk"; ln -s keep.sh "$_c35ekit/install/retarget.lnk"; ln -s keep.sh "$_c35ekit/install/doomed.lnk"
{ printf '#!/usr/bin/env bash\n'
  printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
  printf 'ln -s nowhere-dangling "$k/install/new.lnk"\n'
  printf 'ln -sfn elsewhere.sh "$k/install/retarget.lnk"\n'
  printf 'rm -f "$k/install/doomed.lnk"\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
} > "$w/a-linky.test.sh"
mkfix_sh "$w/b-clean.test.sh" 1 0 0
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] \
   && grep -qF 'files under research-sdd/): 3' <<<"$out" \
   && grep -qF 'a-linky.test.sh leaked: install/new.lnk (new)' <<<"$out" \
   && grep -qF 'a-linky.test.sh leaked: install/retarget.lnk (modified)' <<<"$out" \
   && grep -qF 'a-linky.test.sh leaked: install/doomed.lnk (removed)' <<<"$out" \
   && ! grep -qF 'stable.lnk' <<<"$out" && ! grep -qF 'b-clean.test.sh leaked' <<<"$out"; then
  ok "kit-tree hermeticity: a new, retargeted (dangling too) and removed symlink under research-sdd/ is named; an untouched link is not"
else no "kit-tree symlink case failed: rc=$rc :: $(grep -iE 'kit-tree|leaked|lnk' <<<"$out" | tr '\n' '|')"; fi

# 35c — DEGRADED, never a confident 0: a scanner that fails ONLY on the kit-tree scan (the cwd scan
#       still works) must fail the run and say so with the kit-tree reason.
_c35realfind="$(command -v find)"
if [ -z "$_c35realfind" ]; then
  ok "kit-tree hermeticity degraded: SKIP — no real 'find' on PATH to build the stub from"
else
  w="$(newdir c35c)"; mkfix_sh "$w/a.test.sh" 1 0 0
  _c35bin="$TMP/c35c-bin"; mkdir -p "$_c35bin"
  { printf '#!/usr/bin/env bash\n'
    printf 'case "$*" in *sha1sum*) echo "find: simulated failure" >&2; exit 1;; esac\n'
    printf 'exec %s "$@"\n' "$_c35realfind"
  } > "$_c35bin/find"; chmod +x "$_c35bin/find"
  _c35cwd="$TMP/c35c-cwd"; mkdir -p "$_c35cwd"
  out="$(cd "$_c35cwd" && PATH="$_c35bin:$PATH" bash "$w/run-all.sh" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF 'Kit-tree hermeticity: DEGRADED' <<<"$out"; then
    ok "kit-tree hermeticity degraded: a failing kit-tree scan is DEGRADED and fails the run (not a confident 0)"
  else no "kit-tree hermeticity degraded failed: rc=$rc :: $(grep -iE 'hermeticity' <<<"$out" | tr '\n' '|')"; fi
fi

# 36 — teeth-helper gate (kit issue #1299 item 4): under --require-teeth a hand-rolled teeth suite must
#      use lib/mutant.sh or carry a waiver in teeth-helper-waivers.txt next to the runner.
#      36a unwaived -> exit 1 and named; 36b waived -> exit 0, waived count + names on their own line.
w="$(newdir c36a)"
mkfix_teeth "$w/hand.test.sh"
mkfix_teeth "$w/helped.test.sh"; printf '. "$HERE/lib/mutant.sh"\n' >> "$w/helped.test.sh"
out="$(bash "$w/run-all.sh" --require-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] \
   && grep -qxF 'Suites with teeth not using lib/mutant.sh and not waived: 1 — [hand]' <<<"$out" \
   && grep -qxF 'Waived teeth-helper suites (teeth-helper-waivers.txt): 0 — []' <<<"$out"; then
  ok "teeth-helper gate: an unwaived hand-rolled teeth suite fails --require-teeth and is named"
else no "teeth-helper gate (unwaived) failed: rc=$rc :: $(grep -iE 'waive|lib/mutant' <<<"$out" | tr '\n' '|')"; fi
# 36a2 — the same fixture under plain --prove-teeth stays report-only (exit 0, no gate lines).
out="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -qF 'not waived' <<<"$out"; then ok "teeth-helper gate: --prove-teeth alone stays report-only"
else no "teeth-helper gate leaked into --prove-teeth: rc=$rc :: $(grep -iE 'waive' <<<"$out" | tr '\n' '|')"; fi
w="$(newdir c36b)"
mkfix_teeth "$w/hand.test.sh"; mkfix_teeth "$w/hand2.test.sh"
printf '# comment\n\nhand fixture is hand-rolled\n  hand2   second reason with spaces\n' > "$w/teeth-helper-waivers.txt"
out="$(bash "$w/run-all.sh" --require-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -qxF 'Suites with teeth not using lib/mutant.sh and not waived: 0 — []' <<<"$out" \
   && grep -qxF 'Waived teeth-helper suites (teeth-helper-waivers.txt): 2 — [hand, hand2]' <<<"$out" \
   && grep -qF 'Stale teeth-helper waivers (suite uses the helper, has no teeth, or does not exist): 0 — []' <<<"$out"; then
  ok "teeth-helper gate: waived suites pass, are printed with count and names, comments/blank lines ignored"
else no "teeth-helper gate (waived) failed: rc=$rc :: $(grep -iE 'waive|lib/mutant' <<<"$out" | tr '\n' '|')"; fi

# 36c — STALE waivers fail loudly: a waived suite that now uses the helper, one with no teeth at
#       all, and one that no longer exists. Each is named; the run exits 1.
w="$(newdir c36c)"
mkfix_teeth "$w/helped.test.sh"; printf '. "$HERE/lib/mutant.sh"\n' >> "$w/helped.test.sh"
mkfix_sh "$w/noteeth.test.sh" 1 0 0
mkfix_teeth "$w/hand.test.sh"
printf 'helped now migrated\nnoteeth never had teeth\ngone deleted suite\nhand still waived\n' > "$w/teeth-helper-waivers.txt"
out="$(bash "$w/run-all.sh" --require-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] \
   && grep -qF 'Stale teeth-helper waivers (suite uses the helper, has no teeth, or does not exist): 3 — [gone, helped, noteeth]' <<<"$out"; then
  ok "teeth-helper gate: stale waivers (now helper user / no teeth / nonexistent suite) are named and fail the run"
else no "teeth-helper gate (stale) failed: rc=$rc :: $(grep -iE 'stale|waive' <<<"$out" | tr '\n' '|')"; fi

# 36d — a waiver line with no reason (and a bad suite name, and a duplicate) is invalid and fails.
w="$(newdir c36d)"
mkfix_teeth "$w/hand.test.sh"
printf 'hand\nbad/name reason\nhand first\nhand second\n' > "$w/teeth-helper-waivers.txt"
out="$(bash "$w/run-all.sh" --require-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] \
   && grep -qF 'Invalid teeth-helper waiver lines: 3 — [line 1: '"'hand'"' has no reason, line 2: bad suite name, line 4: '"'hand'"' waived twice]' <<<"$out"; then
  ok "teeth-helper gate: reason-less, badly named and duplicate waiver lines are reported and fail the run"
else no "teeth-helper gate (invalid) failed: rc=$rc :: $(grep -iE 'invalid|waive' <<<"$out" | tr '\n' '|')"; fi

# 36e — absent waiver file is absent-input, not a silent pass: said so; passes only when nothing needs a waiver.
w="$(newdir c36e)"
mkfix_teeth "$w/helped.test.sh"; printf '. "$HERE/lib/mutant.sh"\n' >> "$w/helped.test.sh"
out="$(bash "$w/run-all.sh" --require-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF 'Teeth-helper waivers: ABSENT-INPUT' <<<"$out" \
   && grep -qxF 'Suites with teeth not using lib/mutant.sh and not waived: 0 — []' <<<"$out"; then
  ok "teeth-helper gate: an absent waiver file is reported as ABSENT-INPUT and passes only because nothing needs a waiver"
else no "teeth-helper gate (absent) failed: rc=$rc :: $(grep -iE 'waive' <<<"$out" | tr '\n' '|')"; fi
# 36f — a waiver path that is not a readable file (a directory) fails the run.
w="$(newdir c36f)"
mkfix_teeth "$w/helped.test.sh"; printf '. "$HERE/lib/mutant.sh"\n' >> "$w/helped.test.sh"
mkdir "$w/teeth-helper-waivers.txt"
out="$(bash "$w/run-all.sh" --require-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF 'Teeth-helper waivers: UNREADABLE' <<<"$out"; then
  ok "teeth-helper gate: an unreadable waiver path is reported as UNREADABLE and fails the run"
else no "teeth-helper gate (unreadable) failed: rc=$rc :: $(grep -iE 'waive' <<<"$out" | tr '\n' '|')"; fi
# 36g — a suite basename present in BOTH corpora makes a waiver ambiguous (one line would silently
#       cover both files): the gate reports it as an invalid entry and fails, never a quiet waiver.
w="$(newdir c36g)"
mkfix_teeth "$w/hand.test.sh"
mkdir -p "$(install_dir_for "$w")"; mkfix_teeth "$(install_dir_for "$w")/hand.test.sh"
printf 'hand covers one of them\n' > "$w/teeth-helper-waivers.txt"
out="$(bash "$w/run-all.sh" --require-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qF "Invalid teeth-helper waiver lines: 1 — ['hand' is ambiguous" <<<"$out"; then
  ok "teeth-helper gate: a basename shared by both corpora is reported as ambiguous and fails the run"
else no "teeth-helper gate (basename collision) failed: rc=$rc :: $(grep -iE 'invalid|waive' <<<"$out" | tr '\n' '|')"; fi
# 36h — an UNWAIVED collision is reported on its own line, is not an Invalid waiver line, and still
#       fails via the 'not waived' count.
w="$(newdir c36h)"
mkfix_teeth "$w/hand.test.sh"
mkdir -p "$(install_dir_for "$w")"; mkfix_teeth "$(install_dir_for "$w")/hand.test.sh"
out="$(bash "$w/run-all.sh" --require-teeth 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -qxF 'Ambiguous teeth-helper suite names (both corpora): 1 — [hand]' <<<"$out" \
   && grep -qxF 'Invalid teeth-helper waiver lines: 0 — []' <<<"$out" \
   && grep -qF 'and not waived: 2 — [hand, hand]' <<<"$out"; then
  ok "teeth-helper gate: an unwaived shared basename is listed as ambiguous (not as an invalid waiver) and fails via 'not waived'"
else no "teeth-helper gate (unwaived collision) failed: rc=$rc :: $(grep -iE 'ambiguous|invalid|waive' <<<"$out" | tr '\n' '|')"; fi

# 37 — kit-tree guard gaps (kit issue #1299 item 7).
# 37a — dotfiles: a leak onto a dotfile/dot-directory under research-sdd/ is tracked like any file
#       (probe: `find` lists them; there is no shell glob in the scan to skip them).
w="$(newdir c37a)"; _c37akit="${w%/toolbelt/tests}"
mkdir -p "$_c37akit/install"; printf 'k\n' > "$_c37akit/.hidden-keep"
{ printf '#!/usr/bin/env bash\n'
  printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
  printf 'printf x > "$k/.hidden-new"; mkdir -p "$k/.hdir" && printf x > "$k/.hdir/f"; rm -f "$k/.hidden-keep"\n'
  printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
} > "$w/a-dotty.test.sh"
out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] \
   && grep -qF 'a-dotty.test.sh leaked: .hidden-new (new)' <<<"$out" \
   && grep -qF 'a-dotty.test.sh leaked: .hdir/f (new)' <<<"$out" \
   && grep -qF 'a-dotty.test.sh leaked: .hidden-keep (removed)' <<<"$out"; then
  ok "kit-tree hermeticity: dotfiles and dot-directories under research-sdd/ are tracked"
else no "kit-tree dotfile case failed: rc=$rc :: $(grep -iE 'kit-tree|leaked' <<<"$out" | tr '\n' '|')"; fi

# 37b — a chmod-000 file left under research-sdd/ makes the scan fail; the DEGRADED reason must NAME
#       the unreadable entry (a leftover/suite fault), not blame the scanner. Root ignores mode bits: SKIP.
if [ "$(id -u)" -eq 0 ]; then
  ok "kit-tree unreadable entry: SKIP under root (root ignores permission bits)"
else
  # before any suite runs
  w="$(newdir c37b)"; _c37bkit="${w%/toolbelt/tests}"
  mkdir -p "$_c37bkit/install"; printf 's\n' > "$_c37bkit/install/locked.sh"
  LOCKED_FILES+=("$_c37bkit/install/locked.sh"); chmod 000 "$_c37bkit/install/locked.sh"
  mkfix_sh "$w/a.test.sh" 1 0 0
  out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
  chmod 644 "$_c37bkit/install/locked.sh"
  _c37line="$(grep -E '^Kit-tree hermeticity: DEGRADED' <<<"$out")"
  if [ "$rc" -eq 1 ] && grep -qF 'unreadable entry under research-sdd/ before any suite ran: install/locked.sh' <<<"$_c37line" \
     && ! grep -qF "scanner ('find'" <<<"$_c37line"; then
    ok "kit-tree unreadable entry: a pre-existing chmod-000 file is named in the DEGRADED reason, not blamed on the scanner"
  else no "kit-tree unreadable (pre-existing) failed: rc=$rc :: $_c37line"; fi
  # created by a suite mid-run
  w="$(newdir c37c)"; _c37ckit="${w%/toolbelt/tests}"
  mkdir -p "$_c37ckit/install"; LOCKED_FILES+=("$_c37ckit/install/leftover.sh")
  { printf '#!/usr/bin/env bash\n'
    printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
    printf 'printf s > "$k/install/leftover.sh"; chmod 000 "$k/install/leftover.sh"\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  } > "$w/a-locker.test.sh"
  mkfix_sh "$w/b-clean.test.sh" 1 0 0
  out="$(bash "$w/run-all.sh" 2>&1)"; rc=$?
  chmod 644 "$_c37ckit/install/leftover.sh"
  _c37line="$(grep -E '^Kit-tree hermeticity: DEGRADED' <<<"$out")"
  if [ "$rc" -eq 1 ] && grep -qF 'unreadable entry under research-sdd/ after a-locker.test.sh: install/leftover.sh' <<<"$_c37line"; then
    ok "kit-tree unreadable entry: a chmod-000 file created by a suite is named with the suite, not blamed on the scanner"
  else no "kit-tree unreadable (mid-run) failed: rc=$rc :: $_c37line"; fi
fi

# --- Opt-in parallel mode (kit issue #1463): `-j N` ---------------------------------------------
# GNU parallel is needed for the batch cases; without it they SKIP (never a silent pass), and the
# flag-refusal and DEGRADED cases still run because they do not need it.
have_gnu_parallel=0
_pv="$(parallel --version 2>/dev/null)"   # captured, not piped into grep -m1 (SIGPIPE under pipefail)
case "$_pv" in *"GNU parallel"*) have_gnu_parallel=1 ;; esac
skip_j(){ printf '  SKIP  %s (GNU parallel not installed)\n' "$1"; }
# agg_norm — the aggregate block minus the lines that legitimately differ between serial and -j
# (the corpus path, the Parallel line); everything else must be byte-identical.
agg_norm(){ sed -n '/^AGGREGATE RESULT$/,$p' <<<"$1" | grep -v -e '^Corpus: toolbelt' -e '^Parallel:'; }

# mkbin_without <dir> <name>... — a PATH directory holding a symlink to EVERY executable found on the
# current PATH except the named ones (derived, not a hand-kept allowlist: a tool the runner later
# starts needing can never turn the case into a wrong-reason failure). Prints <dir>.
mkbin_without(){
  local d="$1"; shift; mkdir -p "$d"
  local pd f n x skip
  local IFS=:
  for pd in $PATH; do
    [ -d "$pd" ] || continue
    for f in "$pd"/*; do
      [ -x "$f" ] && [ -f "$f" ] || continue
      n="${f##*/}"; skip=0
      for x in "$@"; do [ "$n" = "$x" ] && skip=1; done
      [ "$skip" -eq 1 ] || [ -e "$d/$n" ] || ln -s "$f" "$d/$n"
    done
  done
  printf '%s' "$d"
}

# j1 — refusals: bare -j, -j 0, -j 100%, non-numeric, above the cap are exit 2 with a named reason.
w="$(newdir j1)"; mkfix_sh "$w/a.test.sh" 1 0 0
_j1bad=""
for _a in "-j" "-j 0" "-j 100%" "-j abc" "-j 7" "-j 100" "--jobs" "-j -3"; do
  # shellcheck disable=SC2086
  out="$(bash "$w/run-all.sh" $_a 2>&1)"; rc=$?
  if [ "$rc" -ne 2 ] || ! grep -qF 'invalid -j value' <<<"$out"; then _j1bad="$_j1bad [$_a rc=$rc]"; fi
done
if [ -z "$_j1bad" ]; then ok "-j refusals: bare/0/100%/non-numeric/over-cap are exit 2 with 'invalid -j value'"
else no "-j refusals failed:$_j1bad"; fi

# j2 — -j parity: same fixtures, serial vs -j 3: identical aggregate (modulo the Parallel line),
#      same exit code, and the Parallel line is present only under -j.
if [ "$have_gnu_parallel" -eq 1 ]; then
  w="$(newdir j2)"
  mkfix_sh "$w/a.test.sh" 3 0 0; mkfix_sh "$w/b.test.sh" 1 1 1; mkfix_sh "$w/c.test.sh" 2 0 0
  mkfix_skip "$w/d.test.sh" dskip; mkfix_harness "$w/e.test.sh"
  sout="$(bash "$w/run-all.sh" 2>&1)"; src=$?
  pout="$(bash "$w/run-all.sh" -j 3 2>&1)"; prc=$?
  if [ "$src" -eq "$prc" ] && [ "$prc" -eq 1 ] \
     && [ "$(agg_norm "$sout")" = "$(agg_norm "$pout")" ] \
     && [ -n "$(agg_norm "$pout")" ] \
     && grep -qF 'Suites run:    5' <<<"$pout" \
     && grep -qF 'b.test.sh (exit 1)' <<<"$pout" \
     && grep -qF 'e.test.sh (HARNESS ERROR, exit 2)' <<<"$pout" \
     && grep -qF 'Parallel: -j 3' <<<"$pout" \
     && ! grep -qF 'Parallel:' <<<"$sout"; then
    ok "-j parity: aggregate identical to serial (rc $prc), 5 suites counted, failures named, Parallel line only under -j"
  else no "-j parity failed: src=$src prc=$prc :: $(diff <(agg_norm "$sout") <(agg_norm "$pout") | head -6 | tr '\n' '|')"; fi
else skip_j "-j parity"; fi

# j3 — replay order: suite banners appear in the serial (sorted) order even though they ran concurrently.
if [ "$have_gnu_parallel" -eq 1 ]; then
  w="$(newdir j3)"
  for n in a b c d; do mkfix_sh "$w/$n.test.sh" 1 0 0; done
  sed -i 's/^exit 0$/sleep 1; exit 0/' "$w/a.test.sh"   # a finishes last; replay must still list it first
  out="$(bash "$w/run-all.sh" -j 4 2>&1)"; rc=$?
  _order="$(grep '^>>> running:' <<<"$out" | tr '\n' ' ')"
  if [ "$rc" -eq 0 ] && [ "$_order" = ">>> running: a.test.sh >>> running: b.test.sh >>> running: c.test.sh >>> running: d.test.sh " ]; then
    ok "-j replay order: banners follow the sorted serial order"
  else no "-j replay order failed: rc=$rc order=[$_order]"; fi
else skip_j "-j replay order"; fi

# j4 — --prove-teeth is forwarded under -j, in either flag order.
if [ "$have_gnu_parallel" -eq 1 ]; then
  w="$(newdir j4)"
  { printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s" "${1:-none}" > "%s/arg.txt"\n' "$w"
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  } > "$w/rec.test.sh"
  bash "$w/run-all.sh" -j 2 --prove-teeth >/dev/null 2>&1; _a1="$(cat "$w/arg.txt")"
  rm -f "$w/arg.txt"
  bash "$w/run-all.sh" --prove-teeth -j2 >/dev/null 2>&1; _a2="$(cat "$w/arg.txt")"
  if [ "$_a1" = "--prove-teeth" ] && [ "$_a2" = "--prove-teeth" ]; then ok "-j forwards --prove-teeth to *.test.sh in both flag orders"
  else no "-j teeth forwarding failed: [$_a1] [$_a2]"; fi
else skip_j "-j teeth forwarding"; fi

# j5 — DEGRADED, never silent: -j without usable GNU parallel prints a typed line carrying the
#      CONCRETE reason (kit issue #1491 item 2) and still runs serially. Three distinct causes:
#      not on PATH, on PATH but not GNU, on PATH but `--version` fails.
w="$(newdir j5)"; mkfix_sh "$w/a.test.sh" 2 0 0; mkfix_sh "$w/b.test.sh" 1 0 0
_j5bin="$TMP/j5-bin"; mkdir -p "$_j5bin"
{ printf '#!/bin/sh\n'; printf 'echo "not the real thing"\n'; } > "$_j5bin/parallel"; chmod +x "$_j5bin/parallel"
_j5nobin="$(mkbin_without "$TMP/j5-nobin" parallel)"
_j5brk="$TMP/j5-brk"; mkdir -p "$_j5brk"
{ printf '#!/bin/sh\n'; printf 'exit 3\n'; } > "$_j5brk/parallel"; chmod +x "$_j5brk/parallel"
_j5bad=""
out="$(PATH="$_j5bin:$PATH" bash "$w/run-all.sh" -j 4 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] \
   && grep -qF 'DEGRADED — '"'parallel' on PATH ($_j5bin/parallel) is not GNU parallel" <<<"$out" \
   && grep -qF 'Parallel: DEGRADED' <<<"$out" \
   && ! grep -qF 'not on PATH' <<<"$out" \
   && grep -qF 'Suites passed: 2' <<<"$out" \
   && grep -qF 'Test cases passed: 3' <<<"$out"; then
  ok "-j degraded: non-GNU parallel -> DEGRADED names 'is not GNU parallel' (stderr + aggregate), serial run still counts every suite"
else no "-j degraded (non-GNU) failed: rc=$rc :: $(grep -iE 'degraded|Suites' <<<"$out" | tr '\n' '|')"; fi
out="$(PATH="$_j5brk:$PATH" bash "$w/run-all.sh" -j 4 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF "but 'parallel --version' failed" <<<"$out" && grep -qF 'Suites passed: 2' <<<"$out"; then
  ok "-j degraded: parallel whose --version fails -> DEGRADED names the failing --version"
else no "-j degraded (--version fails) failed: rc=$rc :: $(grep -iE 'degraded' <<<"$out" | tr '\n' '|')"; fi
out="$(PATH="$_j5nobin" "$_j5nobin/bash" "$w/run-all.sh" -j 4 2>&1)"; rc=$?
if [ ! -x "$_j5nobin/bash" ] || [ -e "$_j5nobin/parallel" ]; then
  no "-j degraded (absent): control invalid — stripped PATH lacks bash or still has parallel"
elif [ "$rc" -eq 0 ] && grep -qF "DEGRADED — 'parallel' is not on PATH" <<<"$out" && grep -qF 'Parallel: DEGRADED' <<<"$out"; then
  ok "-j degraded: no parallel on PATH -> DEGRADED names 'not on PATH'"
else no "-j degraded (absent) failed: rc=$rc :: $(grep -iE 'degraded' <<<"$out" | tr '\n' '|')"; fi

# j6 — a leaking suite under -j is NAMED (kit issue #1491 item 1): the batch snapshot catches the
#      leak, then an automatic serial re-run attributes it to the suite whose run re-touches the
#      path. The clean suite is never blamed, and the run still fails.
if [ "$have_gnu_parallel" -eq 1 ]; then
  w="$(newdir j6)"; _j6kit="${w%/toolbelt/tests}"; mkdir -p "$_j6kit/install"
  { printf '#!/usr/bin/env bash\n'
    printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
    printf 'printf x > "$k/install/leak.MUTANT.sh"\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  } > "$w/a-leaky.test.sh"
  mkfix_sh "$w/b-clean.test.sh" 1 0 0
  _j6cwd="$TMP/j6-cwd"; mkdir -p "$_j6cwd"
  out="$(cd "$_j6cwd" && bash "$w/run-all.sh" -j 2 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] \
     && grep -qF 'Kit-tree hermeticity violations (new/modified/removed files under research-sdd/): 1' <<<"$out" \
     && grep -qF 'a-leaky.test.sh leaked: install/leak.MUTANT.sh (new)' <<<"$out" \
     && ! grep -qF 'b-clean.test.sh leaked' <<<"$out" \
     && ! grep -qF -- '-j batch (offender unattributed' <<<"$out"; then
    ok "-j leak: a suite writing into research-sdd/ is named (serial attribution re-run), run fails"
  else no "-j leak failed: rc=$rc :: $(grep -iE 'kit-tree|leaked|batch' <<<"$out" | tr '\n' '|')"; fi
  # j9 — same for the caller-cwd guard.
  w="$(newdir j9)"
  { printf '#!/usr/bin/env bash\n'
    printf 'printf x > "%s/j9-leak.txt"\n' "$TMP/j9-cwd"
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  } > "$w/a-cwdleak.test.sh"
  mkfix_sh "$w/b-clean.test.sh" 1 0 0
  _j9cwd="$TMP/j9-cwd"; mkdir -p "$_j9cwd"
  out="$(cd "$_j9cwd" && bash "$w/run-all.sh" -j 2 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF 'a-cwdleak.test.sh leaked: j9-leak.txt (new)' <<<"$out" && ! grep -qF 'b-clean.test.sh leaked' <<<"$out"; then
    ok "-j cwd leak: a suite dropping a file in the caller cwd is named, run fails"
  else no "-j cwd leak failed: rc=$rc :: $(grep -iE 'hermeticity|leaked' <<<"$out" | tr '\n' '|')"; fi
  # j10 — an unattributable leak (a removal; nothing to re-touch) still fails under the typed batch label.
  w="$(newdir j10)"; _j10kit="${w%/toolbelt/tests}"; mkdir -p "$_j10kit/install"; printf x > "$_j10kit/install/victim.sh"
  { printf '#!/usr/bin/env bash\n'
    printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
    printf 'rm -f "$k/install/victim.sh"\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  } > "$w/a-rm.test.sh"
  _j10cwd="$TMP/j10-cwd"; mkdir -p "$_j10cwd"
  out="$(cd "$_j10cwd" && bash "$w/run-all.sh" -j 2 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF -- '-j batch (offender unattributed' <<<"$out" && grep -qF 'install/victim.sh (removed)' <<<"$out"; then
    ok "-j leak: an unattributable (removed) path keeps the typed batch label and still fails the run"
  else no "-j unattributable leak failed: rc=$rc :: $(grep -iE 'kit-tree|leaked' <<<"$out" | tr '\n' '|')"; fi
  # j11 — serial path unchanged: the same leaky fixture run WITHOUT -j names the suite directly,
  #       prints no Parallel line and never starts an attribution re-run.
  w="$(newdir j11)"; _j11kit="${w%/toolbelt/tests}"; mkdir -p "$_j11kit/install"
  { printf '#!/usr/bin/env bash\n'
    printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
    printf 'printf x > "$k/install/leak.MUTANT.sh"\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  } > "$w/a-leaky.test.sh"
  _j11cwd="$TMP/j11-cwd"; mkdir -p "$_j11cwd"
  out="$(cd "$_j11cwd" && bash "$w/run-all.sh" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF 'a-leaky.test.sh leaked: install/leak.MUTANT.sh (new)' <<<"$out" \
     && ! grep -qF 'attribution re-run' <<<"$out" && ! grep -qF 'Parallel:' <<<"$out"; then
    ok "serial path unchanged: leak named directly, no Parallel line, no attribution re-run"
  else no "serial path unchanged failed: rc=$rc :: $(grep -iE 'leaked|attribution|Parallel' <<<"$out" | tr '\n' '|')"; fi
  # j12 — bound (kit issue #1491 review R4/R3-002): only the suites whose run window held the leak's
  #       mtime are re-run — never the whole corpus.
  w="$(newdir j12)"; _j12kit="${w%/toolbelt/tests}"; mkdir -p "$_j12kit/install"
  { printf '#!/usr/bin/env bash\n'
    printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
    printf 'printf x > "$k/install/leak.MUTANT.sh"\n'
    printf 'sleep 1\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  } > "$w/a-leaky.test.sh"
  mkfix_sh "$w/b-slow.test.sh" 1 0 0; sed -i 's/^exit 0$/sleep 1; exit 0/' "$w/b-slow.test.sh"
  for n in c1 c2 c3 c4; do mkfix_sh "$w/$n.test.sh" 1 0 0; done
  _j12cwd="$TMP/j12-cwd"; mkdir -p "$_j12cwd"; _j12err="$TMP/j12.err"
  out="$(cd "$_j12cwd" && bash "$w/run-all.sh" -j 2 2>"$_j12err")"; rc=$?
  _j12n="$(grep -c 'attribution re-run:' "$_j12err")"
  if [ "$rc" -eq 1 ] && [ "$_j12n" -le 2 ] && [ "$_j12n" -ge 1 ] \
     && ! grep -qE 'attribution re-run: c[0-9]' "$_j12err" \
     && grep -qF 'a-leaky.test.sh leaked: install/leak.MUTANT.sh (new)' <<<"$out" \
     && grep -qE '^Attribution: re-ran [12] candidate suite\(s\) of 6' <<<"$out"; then
    ok "-j attribution is bounded: $_j12n candidate suite(s) of 6 re-run, the Attribution line states the bound"
  else no "-j attribution bound failed: rc=$rc n=$_j12n :: $(grep -E 'attribution|Attribution|leaked' "$_j12err" <<<"$out" | tr '\n' '|')"; fi
  # j13 — a missing stat is a typed DEGRADED attribution, not a silent batch label.
  w="$(newdir j13)"; _j13kit="${w%/toolbelt/tests}"; mkdir -p "$_j13kit/install"
  cp "$_j12kit/toolbelt/tests/a-leaky.test.sh" "$w/a-leaky.test.sh"
  mkfix_sh "$w/b-clean.test.sh" 1 0 0
  _j13bin="$(mkbin_without "$TMP/j13-bin" stat)"; _j13cwd="$TMP/j13-cwd"; mkdir -p "$_j13cwd"
  out="$(cd "$_j13cwd" && PATH="$_j13bin" "$_j13bin/bash" "$w/run-all.sh" -j 2 2>&1)"; rc=$?
  if [ -e "$_j13bin/stat" ] || [ ! -e "$_j13bin/parallel" ]; then no "-j stat-less: control invalid (stat present or parallel missing in the stripped PATH)"
  elif [ "$rc" -eq 1 ] && grep -qE '^Attribution: DEGRADED \(neither' <<<"$out" && grep -qF -- '-j batch (offender unattributed' <<<"$out"; then
    ok "-j stat-less: attribution is a typed DEGRADED line and the leak keeps the batch label (run fails)"
  else no "-j stat-less failed: rc=$rc :: $(grep -iE 'attribution|leaked|degraded' <<<"$out" | tr '\n' '|')"; fi
  # j14 — a suite that REWRITES the leaked path with different bytes but restores its mtime is still
  #       named (the signature is mtime AND content hash).
  w="$(newdir j14)"; _j14kit="${w%/toolbelt/tests}"; mkdir -p "$_j14kit/install"
  { printf '#!/usr/bin/env bash\n'
    printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"; f="$k/install/leak.MUTANT.sh"\n'
    printf 'm="$(stat -c %%y "$f" 2>/dev/null)"\n'
    printf 'printf "%%s" "$RANDOM$RANDOM$(date +%%N)" > "$f"\n'
    printf '[ -n "$m" ] && touch -d "$m" "$f"\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  } > "$w/a-restore.test.sh"
  mkfix_sh "$w/b-clean.test.sh" 1 0 0
  _j14cwd="$TMP/j14-cwd"; mkdir -p "$_j14cwd"
  out="$(cd "$_j14cwd" && bash "$w/run-all.sh" -j 2 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && grep -qF 'a-restore.test.sh leaked: install/leak.MUTANT.sh (new)' <<<"$out"; then
    ok "-j attribution: a suite that rewrites the path and restores its mtime is named via the content hash"
  else no "-j restored-mtime failed: rc=$rc :: $(grep -iE 'attribution|leaked' <<<"$out" | tr '\n' '|')"; fi
else skip_j "-j leak attribution (j6/j9/j10/j11)"; fi

# j8 — progress: under -j every suite emits a stderr "started" and "done ... rc=N" line while it runs,
#      so a hung suite (started, never done) is nameable; the aggregate block is unaffected.
if [ "$have_gnu_parallel" -eq 1 ]; then
  w="$(newdir j8)"; mkfix_sh "$w/a.test.sh" 1 0 0; mkfix_sh "$w/b.test.sh" 1 1 1
  errf="$TMP/j8.err"; bash "$w/run-all.sh" -j 2 >/dev/null 2>"$errf"; rc=$?
  if [ "$rc" -eq 1 ] \
     && grep -qF 'run-all.sh: -j started: a.test.sh' "$errf" && grep -qF 'run-all.sh: -j done: a.test.sh rc=0' "$errf" \
     && grep -qF 'run-all.sh: -j started: b.test.sh' "$errf" && grep -qF 'run-all.sh: -j done: b.test.sh rc=1' "$errf"; then
    ok "-j progress: per-suite started/done(rc) lines on stderr"
  else no "-j progress failed: rc=$rc :: $(tr '\n' '|' < "$errf" | cut -c1-300)"; fi
else skip_j "-j progress"; fi

# j7 — no silent zero: a suite whose worker dies before recording its exit code is named as failed
#      and the result-count mismatch is reported (never read as "nothing failed").
if [ "$have_gnu_parallel" -eq 1 ]; then
  w="$(newdir j7)"
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
    printf 'kill -9 "$PPID"\n'
  } > "$w/dies.test.sh"
  mkfix_sh "$w/fine.test.sh" 1 0 0
  out="$(bash "$w/run-all.sh" -j 2 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] \
     && grep -qF 'recorded 1 result(s) for 2 suite(s)' <<<"$out" \
     && grep -qF 'dies.test.sh (exit 127)' <<<"$out" \
     && grep -qF 'Suites run:    2' <<<"$out"; then
    ok "-j no-silent-zero: a worker that never recorded a result is a named failure plus a count-mismatch line"
  else no "-j no-silent-zero failed: rc=$rc :: $(grep -iE 'recorded|dies|Suites' <<<"$out" | tr '\n' '|')"; fi
else skip_j "-j no-silent-zero"; fi

# NEGATIVE CONTROL — neuter the runner's PIPESTATUS capture; a failing fixture must then FALSE-PASS
# (runner exits 0). If it does, our exit-code assertions (cases 2/3/6) have real teeth.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter run-all.sh's PIPESTATUS capture (rc=0); a failing fixture must FALSE-PASS --"
  w="$(mut_workdir teeth)"
  # Force every suite's captured exit code to 0, regardless of what the suite actually returned.
  sed 's#rc=${PIPESTATUS\[0\]}#rc=0#g' "$SUT" > "$w/run-all.sh"
  mkfix_sh "$w/ok.test.sh"  1 0 0
  mkfix_sh "$w/bad.test.sh" 0 1 1
  bash "$w/run-all.sh" >/dev/null 2>&1; mrc=$?
  if [ "$mrc" -eq 0 ]; then ok "teeth: PIPESTATUS-neutered mutant reports green despite a failing fixture → exit-code teeth real"
  else no "teeth: mutant still failed (rc=$mrc) — PIPESTATUS mutation not exercised (THEATER)"; fi
  # Mutation 2: neuter the unparsed-summary guard → malformed/no-summary fixtures must FALSE-PASS.
  echo "-- teeth: neuter unparsed guard (elif false); malformed+no-summary must FALSE-PASS --"
  w="$(mut_workdir teeth-unparsed)"
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
  w="$(mut_workdir teeth-skip)"
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
  w="$(mut_workdir teeth-zero)"
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
  # Mutation 5: neuter --require-teeth exit-1 via SENTINEL; a no-teeth fixture must
  #             then exit 0 under --require-teeth, proving the exit path has real teeth.
  echo "-- teeth: neuter SENTINEL-REQUIRE-TEETH-EXIT; require-teeth must no longer exit 1 --"
  w="$(mut_workdir teeth-require)"
  sentinel5='  # SENTINEL-REQUIRE-TEETH-EXIT'
  sentinel5_count="$(grep -Fc "$sentinel5" "$SUT")"
  sed '/SENTINEL-REQUIRE-TEETH-EXIT/{n;s/if \[\[ -n "\$REQUIRE_TEETH" \]\]/if false/}' "$SUT" > "$w/run-all.sh"
  if [ "$sentinel5_count" -ne 1 ]; then
    no "teeth-require: SENTINEL-REQUIRE-TEETH-EXIT not found exactly once (count=$sentinel5_count)"
  elif cmp -s "$SUT" "$w/run-all.sh"; then
    no "teeth-require: require-teeth mutation was a byte-identical no-op"
  else
    mkfix_sh    "$w/nt.test.sh" 3 0 0
    mkfix_teeth "$w/wt.test.sh"; printf '. "$HERE/lib/mutant.sh"\n' >> "$w/wt.test.sh"   # helper user: only the no-teeth gate may bite
    bash "$w/run-all.sh" --require-teeth >/dev/null 2>&1; mrc=$?
    if [ "$mrc" -eq 0 ]; then
      ok "teeth-require: neutered exit guard exits 0 despite no-teeth suite → exit path has real teeth"
    else
      no "teeth-require: mutant still exited $mrc — require-teeth exit mutation not exercised (THEATER)"
    fi
  fi
  # Mutation 6: silence SENTINEL-NO-TEETH-BANNER; the "Suites without teeth:" line must
  #             disappear, proving the banner output path has real teeth.
  echo "-- teeth: silence SENTINEL-NO-TEETH-BANNER; 'Suites without teeth:' must vanish --"
  w="$(mut_workdir teeth-banner)"
  sentinel6='  # SENTINEL-NO-TEETH-BANNER'
  sentinel6_count="$(grep -Fc "$sentinel6" "$SUT")"
  sed '/SENTINEL-NO-TEETH-BANNER/{n;s/echo "Suites without teeth:/: # silenced # echo "Suites without teeth:/}' "$SUT" > "$w/run-all.sh"
  if [ "$sentinel6_count" -ne 1 ]; then
    no "teeth-banner: SENTINEL-NO-TEETH-BANNER not found exactly once (count=$sentinel6_count)"
  elif cmp -s "$SUT" "$w/run-all.sh"; then
    no "teeth-banner: banner silence mutation was a byte-identical no-op"
  else
    mkfix_sh    "$w/nt.test.sh" 3 0 0
    mkfix_teeth "$w/wt.test.sh"
    mout="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"
    if ! grep -qF 'Suites without teeth:' <<<"$mout"; then
      ok "teeth-banner: silenced banner absent from output → banner output has real teeth"
    else
      no "teeth-banner: banner still present after silencing → banner output teeth absent (THEATER)"
    fi
  fi
  # Mutation 7 (kit issue #1032): neuter SENTINEL-HERMETICITY-CHECK's detection condition;
  # a suite that leaks a stray top-level cwd file must then FALSE-PASS (runner exits 0, 0
  # violations), proving the hermeticity guard has real teeth. RDD suggestion (#1118 review):
  # confirm the leaky fixture actually CREATED its stray file before trusting a FALSE-PASS as
  # evidence of the mutation — a fixture that silently failed to leak would also read as a
  # false-pass, but for the wrong reason.
  echo "-- teeth: neuter SENTINEL-HERMETICITY-CHECK; a leaked stray file must FALSE-PASS --"
  w="$(mut_workdir teeth-hermeticity)"
  sentinel7='  # SENTINEL-HERMETICITY-CHECK'
  sentinel7_count="$(grep -Fc "$sentinel7" "$SUT")"
  sed '/SENTINEL-HERMETICITY-CHECK/{n;s/if \[\[ "\$HERMETICITY_DEGRADED" -eq 0 \]\]; then/if false; then/}' "$SUT" > "$w/run-all.sh"
  if [ "$sentinel7_count" -ne 1 ]; then
    no "teeth-hermeticity: SENTINEL-HERMETICITY-CHECK not found exactly once (count=$sentinel7_count)"
  elif cmp -s "$SUT" "$w/run-all.sh"; then
    no "teeth-hermeticity: detection-condition mutation was a byte-identical no-op"
  else
    mkfix_sh "$w/clean.test.sh" 2 0 0
    { printf '#!/usr/bin/env bash\n'
      printf 'echo oops > stray-teeth.txt\n'
      printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
      printf 'exit 0\n'
    } > "$w/leaky.test.sh"
    _teeth_hv_cwd="$TMP/teeth-hermeticity-cwd"; mkdir -p "$_teeth_hv_cwd"
    mout="$(cd "$_teeth_hv_cwd" && bash "$w/run-all.sh" 2>&1)"; mrc=$?
    _teeth_hv_leaked="$([ -e "$_teeth_hv_cwd/stray-teeth.txt" ] && echo yes || echo no)"
    rm -f "$_teeth_hv_cwd/stray-teeth.txt" 2>/dev/null || true
    if [ "$_teeth_hv_leaked" != yes ]; then
      no "teeth-hermeticity: fixture never created stray-teeth.txt — FALSE-PASS would prove nothing"
    elif [ "$mrc" -eq 0 ] && grep -qF 'Hermeticity violations (new/modified/removed top-level entries in caller cwd): 0' <<<"$mout"; then
      ok "teeth-hermeticity: fixture confirmed to have leaked, neutered detection condition FALSE-PASSES it → hermeticity guard has real teeth"
    else
      no "teeth-hermeticity: mutant still caught the confirmed leak (rc=$mrc) — detection-condition mutation not exercised (THEATER)"
    fi
  fi

  # Mutation 8 (kit issue #1118 review, MEDIUM finding #1): neuter
  # SENTINEL-HERMETICITY-ROLLFORWARD — without it, a suite running AFTER a leak is re-blamed
  # for the SAME stray entry (still "new"/"modified" against the stale baseline), inflating the
  # violation count. z-clean.test.sh (sorts after leaky.test.sh, does nothing itself) must then
  # be wrongly named, and the count must exceed 1 — the exact defect case 23 exists to catch.
  echo "-- teeth: neuter SENTINEL-HERMETICITY-ROLLFORWARD; a later clean suite must be re-blamed --"
  w="$(mut_workdir teeth-hermeticity-rollforward)"
  sentinel8='    # SENTINEL-HERMETICITY-ROLLFORWARD'
  sentinel8_count="$(grep -Fc "$sentinel8" "$SUT")"
  sed '/SENTINEL-HERMETICITY-ROLLFORWARD/{n;s/.*/    : # neutered reset/;n;s/.*/    : # neutered repopulate/}' "$SUT" > "$w/run-all.sh"
  if [ "$sentinel8_count" -ne 1 ]; then
    no "teeth-hermeticity-rollforward: SENTINEL-HERMETICITY-ROLLFORWARD not found exactly once (count=$sentinel8_count)"
  elif cmp -s "$SUT" "$w/run-all.sh"; then
    no "teeth-hermeticity-rollforward: rollforward-removal mutation was a byte-identical no-op"
  else
    mkfix_sh "$w/clean.test.sh" 2 0 0
    { printf '#!/usr/bin/env bash\n'
      printf 'echo oops > stray-rf.txt\n'
      printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
      printf 'exit 0\n'
    } > "$w/leaky.test.sh"
    mkfix_sh "$w/z-clean.test.sh" 1 0 0
    _teeth_rf_cwd="$TMP/teeth-hermeticity-rollforward-cwd"; mkdir -p "$_teeth_rf_cwd"
    mout="$(cd "$_teeth_rf_cwd" && bash "$w/run-all.sh" 2>&1)"; mrc=$?
    _teeth_rf_leaked="$([ -e "$_teeth_rf_cwd/stray-rf.txt" ] && echo yes || echo no)"
    rm -f "$_teeth_rf_cwd/stray-rf.txt" 2>/dev/null || true
    if [ "$_teeth_rf_leaked" != yes ]; then
      no "teeth-hermeticity-rollforward: fixture never created stray-rf.txt — mutant check would prove nothing"
    elif [ "$mrc" -ne 0 ] && grep -qF 'z-clean.test.sh leaked:' <<<"$mout"; then
      ok "teeth-hermeticity-rollforward: neutered rollforward re-blames the later clean suite → attribution guard has real teeth"
    else
      no "teeth-hermeticity-rollforward: mutant did not misattribute z-clean.test.sh (rc=$mrc) — mutation not exercised (THEATER)"
    fi
  fi

  # Mutation 9 (kit issue #1121, #1118 review follow-up): track directories by mtime too
  # (instead of name-only). Case 28's own scenario (git status refreshing .git's mtime via a
  # legitimate lock+rename) must then be misread as a modification, proving case 28 has teeth.
  echo "-- teeth: track directories by mtime (SENTINEL-DIR-NAME-ONLY-TRACKING); case 28's git-status scenario must FALSE-FLAG --"
  # kit issue #1142 review round-2 gate (this session): was a flat "$TMP/name"; mkdir -p "$w"
  # workdir, predating #1144's newdir()/mut_workdir() hardening. A flat (non-nested) workdir makes
  # this mutant's SCRIPT_DIR/../../install/tests climb land OUTSIDE $TMP (in the shared /tmp
  # namespace), which is unstable per newdir()'s own doc comment above. mut_workdir() gives this
  # mutant the same isolated nested-repo-shape + empty-install-sibling guarantee as every other
  # --prove-teeth block in this file.
  w="$(mut_workdir teeth-dir-mtime)"
  sentinel9='      # SENTINEL-DIR-NAME-ONLY-TRACKING'
  sentinel9_count="$(grep -Fc "$sentinel9" "$SUT")"
  sed '/SENTINEL-DIR-NAME-ONLY-TRACKING/{n;s#_target\["\$_name"\]="d"#_target["$_name"]="d:$_mtime"#}' "$SUT" > "$w/run-all.sh"
  if [ "$sentinel9_count" -ne 1 ]; then
    no "teeth-dir-mtime: SENTINEL-DIR-NAME-ONLY-TRACKING not found exactly once (count=$sentinel9_count)"
  elif cmp -s "$SUT" "$w/run-all.sh"; then
    no "teeth-dir-mtime: mtime-tracking mutation was a byte-identical no-op"
  else
    mkfix_sh "$w/a.test.sh" 1 0 0
    { printf '#!/usr/bin/env bash\n'
      printf 'git status --porcelain >/dev/null\n'
      printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
      printf 'exit 0\n'
    } > "$w/gitstatus.test.sh"
    _teeth_dm_cwd="$TMP/teeth-dir-mtime-cwd"; mkdir -p "$_teeth_dm_cwd"
    ( cd "$_teeth_dm_cwd" \
      && git init -q . \
      && git config user.email t@example.com \
      && git config user.name tester \
      && printf x > f.txt \
      && git add -A && git commit -qm init \
      && touch f.txt )
    mout="$(cd "$_teeth_dm_cwd" && bash "$w/run-all.sh" 2>&1)"; mrc=$?
    rm -rf "$_teeth_dm_cwd" 2>/dev/null || true
    if [ "$mrc" -ne 0 ] && grep -qF 'leaked: .git' <<<"$mout"; then
      ok "teeth-dir-mtime: mtime-tracked mutant false-flags .git's legitimate mtime bump → case 28's name-only design has real teeth"
    else
      no "teeth-dir-mtime: mutant did not false-flag .git (rc=$mrc) — mutation not exercised (THEATER) :: out=[$(grep -iF 'hermeticity' <<<"$mout" | tr '\n' '|')]"
    fi
  fi

  # Mutation 10 (kit issue #1121, #1118 review follow-up): neuter the scanner's exit-status
  # check (SENTINEL-SCANNER-RC-CHECK) so a failed scan is treated as a successful empty scan.
  # Case 29's scenario (find rejecting -printf) must then FALSE-PASS as a confident "0
  # violations" instead of a typed DEGRADED state, proving case 29 has teeth.
  echo "-- teeth: neuter SENTINEL-SCANNER-RC-CHECK; case 29's find-rejects--printf scenario must FALSE-PASS --"
  # kit issue #1142 review round-2 gate (this session): a flat "$TMP/name"; mkdir -p "$w" workdir
  # (pre-#1144 shape) made SCRIPT_DIR/../../install/tests climb OUTSIDE $TMP, so the mutant's exit
  # code depended on whatever happened to sit at the shared-/tmp climb target on the host — with
  # that target ABSENT, #1144's own ABSENT-INPUT gate forced rc=1 regardless of this mutation's
  # actual effect, false-FAILING this case's `$mrc -eq 0` assertion for an unrelated reason
  # (verified: full-gate run FAILed here; reproduced standalone; root-caused to this exact
  # flat-vs-nested workdir gap). mut_workdir() gives this mutant an isolated empty install/tests
  # sibling (case 31's non-failing "= 0" state) so rc reflects only the scanner-rc mutation.
  w="$(mut_workdir teeth-scanner-rc)"
  sentinel10='  # SENTINEL-SCANNER-RC-CHECK'
  sentinel10_count="$(grep -Fc "$sentinel10" "$SUT")"
  sed '/SENTINEL-SCANNER-RC-CHECK/{n;n;s/\[\[ \$_rc -eq 0 \]\] || return 1/: # neutered rc check/}' "$SUT" > "$w/run-all.sh"
  if [ "$sentinel10_count" -ne 1 ]; then
    no "teeth-scanner-rc: SENTINEL-SCANNER-RC-CHECK not found exactly once (count=$sentinel10_count)"
  elif cmp -s "$SUT" "$w/run-all.sh"; then
    no "teeth-scanner-rc: rc-check-removal mutation was a byte-identical no-op"
  else
    _teeth_src_realfind="$(command -v find)"
    if [ -z "$_teeth_src_realfind" ]; then
      no "teeth-scanner-rc: no real 'find' on PATH to build the stub from"
    else
      mkfix_sh "$w/a.test.sh" 1 0 0
      # The stub rejects -printf, which only the CALLER-CWD scan uses; the kit-tree scan (kit issue
      # #1156) runs `find -type f -exec sha1sum` and never passes -printf, so it is unaffected and
      # this tooth isolates the cwd scanner's rc check — independent of any path (TMPDIR) naming.
      { printf '#!/usr/bin/env bash\n'
        printf 'for _a in "$@"; do\n'
        printf '  if [ "$_a" = "-printf" ]; then echo "find: unknown primary or operator" >&2; exit 1; fi\n'
        printf 'done\n'
        printf 'exec %s "$@"\n' "$_teeth_src_realfind"
      } > "$TMP/teeth-scanner-rc-bin-find"
      _teeth_src_bin="$TMP/teeth-scanner-rc-bin"; mkdir -p "$_teeth_src_bin"
      mv "$TMP/teeth-scanner-rc-bin-find" "$_teeth_src_bin/find"; chmod +x "$_teeth_src_bin/find"
      _teeth_src_cwd="$TMP/teeth-scanner-rc-cwd"; mkdir -p "$_teeth_src_cwd"
      mout="$(cd "$_teeth_src_cwd" && PATH="$_teeth_src_bin:$PATH" bash "$w/run-all.sh" 2>&1)"; mrc=$?
      rm -rf "$_teeth_src_cwd" "$_teeth_src_bin" 2>/dev/null || true
      if [ "$mrc" -eq 0 ] \
         && grep -qF 'Hermeticity violations (new/modified/removed top-level entries in caller cwd): 0' <<<"$mout" \
         && ! grep -qF 'Hermeticity: DEGRADED' <<<"$mout"; then
        ok "teeth-scanner-rc: neutered rc check FALSE-PASSES a failed scan as a confident 0 → case 29's DEGRADED design has real teeth"
      else
        no "teeth-scanner-rc: mutant still reported DEGRADED (rc=$mrc) — mutation not exercised (THEATER) :: out=[$(grep -iF 'hermeticity' <<<"$mout" | tr '\n' '|')]"
      fi
    fi
  fi

  # Mutation 11 (kit issue #1144 review, BLOCKING finding #1): drop the install-tests arrays from
  # SENTINEL-CORPUS-MERGE's merge loop. Case 30's install-present fixture must then FALSE-PASS on
  # the suite-count assertion — the corpus line still reports "= 1" (that count comes from array
  # size, computed before the merge loop runs) but the install suite is no longer actually
  # EXECUTED, so "Suites run:" drops from 2 to 1 — proving the merge loop itself is load-bearing,
  # separately from discovery.
  echo "-- teeth: neuter SENTINEL-CORPUS-MERGE (drop install suites from the merge loop); case 30 must FALSE-PASS on suite count --"
  w="$(mut_workdir teeth-corpus-merge)"
  sentinel11='# SENTINEL-CORPUS-MERGE'
  sentinel11_count="$(grep -Fc "$sentinel11" "$SUT")"
  sed '/SENTINEL-CORPUS-MERGE/{n;s/.*/for f in "${sh_suites[@]}" "${mjs_suites[@]}"; do/}' "$SUT" > "$w/run-all.sh"
  if [ "$sentinel11_count" -ne 1 ]; then
    no "teeth-corpus-merge: SENTINEL-CORPUS-MERGE not found exactly once (count=$sentinel11_count)"
  elif cmp -s "$SUT" "$w/run-all.sh"; then
    no "teeth-corpus-merge: merge-loop mutation was a byte-identical no-op"
  else
    _tcm_root="$(newdir teeth-corpus-merge-fixtures)"
    cp "$w/run-all.sh" "$_tcm_root/run-all.sh"
    mkfix_sh "$_tcm_root/a.test.sh" 1 0 0
    _tcm_install="$(install_dir_for "$_tcm_root")"
    mkdir -p "$_tcm_install"
    mkfix_sh "$_tcm_install/b.test.sh" 1 0 0
    mout="$(bash "$_tcm_root/run-all.sh" 2>&1)"; mrc=$?
    if grep -qE 'Corpus: install tests \([^)]*\) = 1 suite\(s\)' <<<"$mout" && grep -qF 'Suites run:    1' <<<"$mout"; then
      ok "teeth-corpus-merge: merge-loop-neutered mutant still declares '= 1' but only runs 1 suite → case 30's suite-count assertion has real teeth"
    else
      no "teeth-corpus-merge: mutant did not desync corpus-declared count from suites-run count (rc=$mrc) — mutation not exercised (THEATER) :: out=[$(grep -E 'Corpus:|Suites run' <<<"$mout" | tr '\n' '|')]"
    fi
  fi

  # Mutation 12 (kit issue #1142 review NIT): revert SENTINEL-SCANNER-STDOUT-ONLY's find capture
  # to merge stderr into stdout (2>&1) again. Case 33's stderr-warning-on-success scenario must
  # then misread the warning line as a phantom top-level entry, proving the stdout-only fix has
  # real teeth. Uses the sed r+d idiom (append replacement file, then delete the matched line)
  # to avoid embedding the printf format string's own backslash-tab/newline escapes in a sed -e
  # script, which would collide with sed's own escaping.
  echo "-- teeth: revert SENTINEL-SCANNER-STDOUT-ONLY to 2>&1; case 33's stderr-noise scenario must misread it as a phantom entry --"
  # kit issue #1142 review round-2 gate (this session): same flat-workdir gap as Mutations 9/10
  # above (predates #1144's mut_workdir() hardening) — fixed the same way for isolation, even
  # though this case's own assertion (a grep on $mout, no $mrc check) happened not to be visibly
  # broken by it.
  w="$(mut_workdir teeth-scanner-stdout-only)"
  sentinel12='  # SENTINEL-SCANNER-STDOUT-ONLY'
  sentinel12_count="$(grep -Fc "$sentinel12" "$SUT")"
  repl12="$TMP/teeth-scanner-stdout-only-repl.txt"
  cat <<'REPL12' > "$repl12"
  _out="$(find "$CALLER_CWD" -mindepth 1 -maxdepth 1 -printf '%f\t%y\t%s\t%T@\n' 2>&1)"
REPL12
  sed "/SENTINEL-SCANNER-STDOUT-ONLY/r $repl12" "$SUT" > "$w/run-all.sh"
  sed -i '/SENTINEL-SCANNER-STDOUT-ONLY/{n;n;d}' "$w/run-all.sh"
  if [ "$sentinel12_count" -ne 1 ]; then
    no "teeth-scanner-stdout-only: SENTINEL-SCANNER-STDOUT-ONLY not found exactly once (count=$sentinel12_count)"
  elif cmp -s "$SUT" "$w/run-all.sh"; then
    no "teeth-scanner-stdout-only: 2>&1-revert mutation was a byte-identical no-op"
  else
    _t12realfind="$(command -v find)"
    if [ -z "$_t12realfind" ]; then
      no "teeth-scanner-stdout-only: no real 'find' on PATH to build the stub from"
    else
      mkfix_sh "$w/a.test.sh" 1 0 0
      # The warning includes a changing value (nanosecond timestamp) each invocation: a CONSTANT
      # stderr message would land identically in the baseline scan AND every per-suite scan, so
      # the guard's diff-based check would never see it as new/modified (no violation, THEATER).
      { printf '#!/usr/bin/env bash\n'
        printf 'echo "find: harmless warning $(date +%%s%%N) not an error" >&2\n'
        printf 'exec %s "$@"\n' "$_t12realfind"
      } > "$TMP/teeth-scanner-stdout-only-bin-find"
      _t12bin="$TMP/teeth-scanner-stdout-only-bin"; mkdir -p "$_t12bin"
      mv "$TMP/teeth-scanner-stdout-only-bin-find" "$_t12bin/find"; chmod +x "$_t12bin/find"
      _t12cwd="$TMP/teeth-scanner-stdout-only-cwd"; mkdir -p "$_t12cwd"
      mout="$(cd "$_t12cwd" && PATH="$_t12bin:$PATH" bash "$w/run-all.sh" 2>&1)"; mrc=$?
      rm -rf "$_t12cwd" "$_t12bin" 2>/dev/null || true
      if ! grep -qF 'Hermeticity violations (new/modified/removed top-level entries in caller cwd): 0' <<<"$mout"; then
        ok "teeth-scanner-stdout-only: 2>&1-reverted mutant misreads the stderr warning as a phantom entry → case 33 has real teeth"
      else
        no "teeth-scanner-stdout-only: mutant still reported 0 violations (rc=$mrc) — mutation not exercised (THEATER) :: out=[$(grep -iF 'hermeticity' <<<"$mout" | tr '\n' '|')]"
      fi
    fi
  fi
  # Mutation (kit issue #943): neuter the helper-usage test in SENTINEL-HELPER-USE-TEST; a
  # hand-rolled teeth suite must then vanish from the "not using lib/mutant.sh" line. The mutant
  # is built through the shared helper, which refuses an empty / identical / syntax-broken one.
  echo "-- teeth: neuter SENTINEL-HELPER-USE-TEST; hand-rolled teeth suite must vanish from the list --"
  w="$(mut_workdir teeth-helper-lint)"
  if ! mutant_sed "$SUT" "$w/run-all.sh" '/SENTINEL-HELPER-USE-TEST/,+2s/&& ! awk/\&\& false \&\& ! awk/' 2>"$w/mutant.err"; then
    no "teeth-helper-lint: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mkfix_teeth "$w/hand.test.sh"
    mout="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"
    if grep -qF 'Suites with teeth not using lib/mutant.sh: 0 — []' <<<"$mout"; then
      ok "teeth-helper-lint: neutered lint reports 0 for a hand-rolled teeth suite → lint has real teeth"
    else
      no "teeth-helper-lint: mutant still named the hand-rolled suite — lint mutation not exercised (THEATER) :: $(grep -F 'lib/mutant.sh' <<<"$mout" | tr '\n' '|')"
    fi
  fi
  # Mutation (kit issue #1299 review): drop the variable resolution; a `. "$LIB"` suite must then
  # be listed as a non-user (case 34f).
  echo "-- teeth: drop VAR indirection in SENTINEL-HELPER-USE-TEST; a source of \$LIB must be listed (case 34f) --"
  w="$(mut_workdir teeth-helper-var)"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/isvar\[v\] = 1/isvar[v] = 1; delete isvar[v]/' 2>"$w/mutant.err"; then
    no "teeth-helper-var: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mkfix_teeth "$w/via-var.test.sh"
    printf 'LIB="${MUTANT_LIB:-$HERE/lib/mutant.sh}"\n. "$LIB"\n' >> "$w/via-var.test.sh"
    mout="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"
    if grep -qF 'Suites with teeth not using lib/mutant.sh: 1 — [via-var]' <<<"$mout"; then
      ok "teeth-helper-var: without VAR resolution the \$LIB source is not recognised → indirection has real teeth"
    else
      no "teeth-helper-var: mutant still recognised the \$LIB source — mutation not exercised (THEATER) :: $(grep -F 'lib/mutant.sh' <<<"$mout" | tr '\n' '|')"
    fi
  fi
  # Mutation (kit issue #1299 item 5): drop the comment filter; a suite that only MENTIONS the
  # helper in a comment must then be counted as a helper user (vanish from the list).
  echo "-- teeth: drop the comment filter; a comment-only mention must vanish from the list (case 34d) --"
  w="$(mut_workdir teeth-helper-comment)"
  if ! mutant_sed "$SUT" "$w/run-all.sh" '/^      \/\^\[\[:space:\]\]\*#\/ { next }$/d' 2>"$w/mutant.err"; then
    no "teeth-helper-comment: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mkfix_teeth "$w/cmt-only.test.sh"
    printf '# a; . "$HERE/lib/mutant.sh"\n' >> "$w/cmt-only.test.sh"
    mout="$(bash "$w/run-all.sh" --prove-teeth 2>&1)"
    if grep -qF 'Suites with teeth not using lib/mutant.sh: 0 — []' <<<"$mout"; then
      ok "teeth-helper-comment: without the comment filter a comment-only mention passes the lint → filter has real teeth"
    else
      no "teeth-helper-comment: mutant still named the comment-only suite — mutation not exercised (THEATER) :: $(grep -F 'lib/mutant.sh' <<<"$mout" | tr '\n' '|')"
    fi
  fi
  # Mutation (kit issue #1156): neuter the change test in SENTINEL-KIT-TREE-CHECK; a suite that
  # writes a stray file under research-sdd/ must then FALSE-PASS. The leak is confirmed to have
  # happened (the fixture records it OUTSIDE the tree) so a silent no-leak fixture cannot read as a bite.
  echo "-- teeth: neuter SENTINEL-KIT-TREE-CHECK; a file written under research-sdd/ must FALSE-PASS --"
  w="$(mut_workdir teeth-kit-tree)"; _ktk="${w%/toolbelt/tests}"
  if ! mutant_sed "$SUT" "$w/run-all.sh" '/SENTINEL-KIT-TREE-CHECK/,+16s/elif \[\[ "\$_kit_tree_cur" != "\$_kit_tree_prev" \]\]; then/elif false; then/' 2>"$w/mutant.err"; then
    no "teeth-kit-tree: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    { printf '#!/usr/bin/env bash\n'
      printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
      printf 'printf x > "$k/install/stray-kit-tree.sh" && : > "%s"\n' "$TMP/teeth-kit-tree.leaked"
      printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
    } > "$w/leaky.test.sh"
    mkdir -p "$_ktk/install"
    mout="$(bash "$w/run-all.sh" 2>&1)"; mrc=$?
    if [ ! -e "$TMP/teeth-kit-tree.leaked" ]; then
      no "teeth-kit-tree: fixture never leaked — FALSE-PASS would prove nothing"
    elif [ "$mrc" -eq 0 ] && grep -qF 'violations (new/modified/removed files under research-sdd/): 0' <<<"$mout"; then
      ok "teeth-kit-tree: neutered guard FALSE-PASSES a confirmed leak under research-sdd/ → kit-tree guard has real teeth"
    else
      no "teeth-kit-tree: mutant still caught the leak (rc=$mrc) — mutation not exercised (THEATER)"
    fi
  fi
  # Mutation (kit issue #1299 item 7): make the symlink listing see nothing; a symlink created under
  # research-sdd/ must then FALSE-PASS. The leak is confirmed to have happened.
  echo "-- teeth: blind SENTINEL-KIT-TREE-SYMLINKS; a symlink created under research-sdd/ must FALSE-PASS --"
  w="$(mut_workdir teeth-kit-tree-symlink)"; _ktl="${w%/toolbelt/tests}"
  if ! mutant_sed "$SUT" "$w/run-all.sh" "/SENTINEL-KIT-TREE-SYMLINKS/,+2s/-type l /-type l -name __never__ /" 2>"$w/mutant.err"; then
    no "teeth-kit-tree-symlink: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    { printf '#!/usr/bin/env bash\n'
      printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
      printf 'ln -s nowhere "$k/install/stray.lnk" && : > "%s"\n' "$TMP/teeth-kit-tree-symlink.leaked"
      printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
    } > "$w/linky.test.sh"
    mkdir -p "$_ktl/install"
    mout="$(bash "$w/run-all.sh" 2>&1)"; mrc=$?
    if [ ! -e "$TMP/teeth-kit-tree-symlink.leaked" ]; then
      no "teeth-kit-tree-symlink: fixture never leaked — FALSE-PASS would prove nothing"
    elif [ "$mrc" -eq 0 ] && grep -qF 'violations (new/modified/removed files under research-sdd/): 0' <<<"$mout"; then
      ok "teeth-kit-tree-symlink: symlink-blind guard FALSE-PASSES a confirmed symlink leak → symlink tracking has real teeth"
    else
      no "teeth-kit-tree-symlink: mutant still caught the symlink (rc=$mrc) — mutation not exercised (THEATER)"
    fi
  fi
fi

# --- Mutation controls for the teeth-helper gate and the unreadable-entry reason (kit issue #1299) ---
if [ "${1:-}" = "--prove-teeth" ]; then
  # Each of the four gate conditions in SENTINEL-TEETH-HELPER-EXIT is neutered in turn; the fixture
  # that the condition exists to catch must then FALSE-PASS (exit 0 under --require-teeth).
  _gate_mut(){ # name  sed-condition-fragment  fixture-label  setup-function
    local name="$1" frag="$2" label="$3" setup="$4" mw mout mrc
    echo "-- teeth: neuter the $label condition in SENTINEL-TEETH-HELPER-EXIT; that fixture must FALSE-PASS --"
    mw="$(mut_workdir "teeth-helper-gate-$name")"
    if ! mutant_sed "$SUT" "$mw/run-all.sh" "/SENTINEL-TEETH-HELPER-EXIT/,/; }; then\$/s/$frag/false/" 2>"$mw/mutant.err"; then
      no "teeth-helper-gate-$name: could not build a valid mutant: $(cat "$mw/mutant.err")"
      return
    fi
    "$setup" "$mw"
    bash "$mw/run-all.sh" --require-teeth >/dev/null 2>&1; mrc=$?
    if [ "$mrc" -eq 0 ]; then ok "teeth-helper-gate-$name: neutered $label condition exits 0 on the offending fixture → condition has real teeth"
    else no "teeth-helper-gate-$name: mutant still exited $mrc — mutation not exercised (THEATER)"; fi
  }
  _setup_unwaived(){ mkfix_teeth "$1/hand.test.sh"; }
  _setup_stale(){ mkfix_teeth "$1/helped.test.sh"; printf '. "$HERE/lib/mutant.sh"\n' >> "$1/helped.test.sh"
    printf 'helped stale\n' > "$1/teeth-helper-waivers.txt"; }
  _setup_invalid(){ mkfix_teeth "$1/helped.test.sh"; printf '. "$HERE/lib/mutant.sh"\n' >> "$1/helped.test.sh"
    printf 'noreason\n' > "$1/teeth-helper-waivers.txt"; }
  _gate_mut unwaived '\[\[ \${#_unwaived\[@\]} -gt 0 \]\]' unwaived _setup_unwaived
  _gate_mut stale '\[\[ \${#_stale\[@\]} -gt 0 \]\]' stale _setup_stale
  _setup_unreadable(){ mkfix_teeth "$1/helped.test.sh"; printf '. "$HERE/lib/mutant.sh"\n' >> "$1/helped.test.sh"
    mkdir "$1/teeth-helper-waivers.txt"; }
  _gate_mut invalid '\[\[ \${#_wv_invalid\[@\]} -gt 0 \]\]' invalid _setup_invalid
  _gate_mut unreadable '\[\[ "\$_wv_state" == "unreadable" \]\]' unreadable _setup_unreadable
  # Mutation: nothing counts as waived; the waived fixture (36b) must then FAIL --require-teeth.
  echo "-- teeth: stop matching waivers; a fully waived fixture must then FAIL --"
  w="$(mut_workdir teeth-helper-waive-match)"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/if \[\[ "\${_wv_reason\[\$_n\]+set}" == "set" \]\]; then _waived/if false; then _waived/' 2>"$w/mutant.err"; then
    no "teeth-helper-waive-match: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mkfix_teeth "$w/hand.test.sh"; printf 'hand reason\n' > "$w/teeth-helper-waivers.txt"
    bash "$w/run-all.sh" --require-teeth >/dev/null 2>&1; mrc=$?
    if [ "$mrc" -eq 1 ]; then ok "teeth-helper-waive-match: matching-less mutant fails a waived fixture → waiver matching has real teeth"
    else no "teeth-helper-waive-match: mutant still exited $mrc — mutation not exercised (THEATER)"; fi
  fi
  # Mutation: blind the cross-corpus basename-collision check; the shared-name fixture (36g) must then FALSE-PASS.
  echo "-- teeth: blind the basename-collision check; case 36g's fixture must FALSE-PASS --"
  w="$(mut_workdir teeth-helper-collision)"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/^\(      if \)\[\[ "\${_wv_reason\[\$_n\]+set}" == "set" \]\]; then  # SENTINEL-TEETH-AMBIGUOUS$/\1false; then/' 2>"$w/mutant.err"; then
    no "teeth-helper-collision: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mkfix_teeth "$w/hand.test.sh"
    mkdir -p "$(install_dir_for "$w")"
    mkfix_teeth "$(install_dir_for "$w")/hand.test.sh"; printf 'hand reason\n' > "$w/teeth-helper-waivers.txt"
    if [ -f "$w/hand.test.sh" ] && [ -f "$(install_dir_for "$w")/hand.test.sh" ]; then _fixok=1; else _fixok=0; fi
    bash "$w/run-all.sh" --require-teeth >/dev/null 2>&1; mrc=$?
    if [ "$_fixok" -ne 1 ]; then no "teeth-helper-collision: fixture does not hold two hand.test.sh — a kill would prove nothing"
    elif [ "$mrc" -eq 0 ]; then ok "teeth-helper-collision: collision-blind mutant exits 0 on a shared basename → ambiguity check has real teeth"
    else no "teeth-helper-collision: mutant still exited $mrc — mutation not exercised (THEATER)"; fi
  fi
  # Mutation: blind the unreadable-entry finder; the DEGRADED reason must then fall back to blaming the scanner.
  if [ "$(id -u)" -ne 0 ]; then
    echo "-- teeth: blind SENTINEL-KIT-TREE-UNREADABLE; the reason must revert to blaming the scanner --"
    w="$(mut_workdir teeth-kit-tree-unreadable)"; _tku="${w%/toolbelt/tests}"
    if ! mutant_sed "$SUT" "$w/run-all.sh" '/SENTINEL-KIT-TREE-UNREADABLE/,+4s/-not -readable/-name __never__/' 2>"$w/mutant.err"; then
      no "teeth-kit-tree-unreadable: could not build a valid mutant: $(cat "$w/mutant.err")"
    else
      mkdir -p "$_tku/install"; printf 's\n' > "$_tku/install/locked.sh"
      LOCKED_FILES+=("$_tku/install/locked.sh"); chmod 000 "$_tku/install/locked.sh"
      mkfix_sh "$w/a.test.sh" 1 0 0
      mout="$(bash "$w/run-all.sh" 2>&1)"
      chmod 644 "$_tku/install/locked.sh"
      _tkuline="$(grep -E '^Kit-tree hermeticity: DEGRADED' <<<"$mout")"
      if grep -qF "scanner ('find'" <<<"$_tkuline" && ! grep -qF 'install/locked.sh' <<<"$_tkuline"; then
        ok "teeth-kit-tree-unreadable: finder-blind mutant blames the scanner again → unreadable-entry reason has real teeth"
      else no "teeth-kit-tree-unreadable: mutant still named the entry — mutation not exercised (THEATER)"; fi
    fi
  fi
fi

# --- Mutation controls for -j (kit issue #1463) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ] && [ "$have_gnu_parallel" -eq 1 ]; then
  # Mutation: drop the post-batch kit-tree check; a leak under -j must then FALSE-PASS.
  echo "-- teeth: drop the -j batch kit-tree check; a leak under -j must FALSE-PASS --"
  w="$(mut_workdir teeth-j-leak)"; _tjk="${w%/toolbelt/tests}"; mkdir -p "$_tjk/install"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/^  _check_kit_tree_hermeticity "\$PARALLEL_LABEL"$/  :/' 2>"$w/mutant.err"; then
    no "teeth-j-leak: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    { printf '#!/usr/bin/env bash\n'
      printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
      printf 'printf x > "$k/install/leak.MUTANT.sh" && : > "%s"\n' "$TMP/teeth-j-leak.leaked"
      printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
    } > "$w/leaky.test.sh"
    mout="$(bash "$w/run-all.sh" -j 2 2>&1)"; mrc=$?
    if [ ! -e "$TMP/teeth-j-leak.leaked" ]; then no "teeth-j-leak: fixture never leaked — FALSE-PASS would prove nothing"
    elif [ "$mrc" -eq 0 ]; then ok "teeth-j-leak: batch-check-less mutant FALSE-PASSES a confirmed leak → the -j batch check has real teeth"
    else no "teeth-j-leak: mutant still caught the leak (rc=$mrc) — mutation not exercised (THEATER)"; fi
  fi
  # Mutation: ignore the recorded exit code under -j; a failing fixture must then FALSE-PASS.
  echo "-- teeth: ignore the recorded exit code under -j; a failing fixture must FALSE-PASS --"
  w="$(mut_workdir teeth-j-rc)"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/^      rc="\$(cat "\$PAR_DIR\/\$suite_idx.rc")"$/      rc=0/' 2>"$w/mutant.err"; then
    no "teeth-j-rc: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mkfix_sh "$w/ok.test.sh" 1 0 0; mkfix_sh "$w/bad.test.sh" 0 1 1
    bash "$w/run-all.sh" -j 2 >/dev/null 2>&1; mrc=$?
    if [ "$mrc" -eq 0 ]; then ok "teeth-j-rc: rc-ignoring mutant reports green despite a failing fixture → the -j exit-code replay has real teeth"
    else no "teeth-j-rc: mutant still failed (rc=$mrc) — mutation not exercised (THEATER)"; fi
  fi
  # Mutation: drop the upper cap; -j 7 must then be accepted (not exit 2).
  echo "-- teeth: drop the -j cap; -j 7 must be ACCEPTED --"
  w="$(mut_workdir teeth-j-cap)"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/\[\[ "\$((10#\$1))" -gt "\$MAX_JOBS" \]\]/false/' 2>"$w/mutant.err"; then
    no "teeth-j-cap: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mkfix_sh "$w/ok.test.sh" 1 0 0
    bash "$w/run-all.sh" -j 7 >/dev/null 2>&1; mrc=$?
    if [ "$mrc" -ne 2 ]; then ok "teeth-j-cap: cap-less mutant accepts -j 7 → the cap has real teeth"
    else no "teeth-j-cap: mutant still refused -j 7 — mutation not exercised (THEATER)"; fi
  fi
  # Mutation: let unknown tokens through; a typo after a valid flag must then be silently accepted.
  echo "-- teeth: drop the unknown-flag refusal; '-j 2 --prove-teath' must be ACCEPTED --"
  w="$(mut_workdir teeth-unknown-flag)"
  if ! mutant_sed "$SUT" "$w/run-all.sh" '/unknown flag: \$_a; \$USAGE/{N;s/.*/      :/}' 2>"$w/mutant.err"; then
    no "teeth-unknown-flag: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mkfix_sh "$w/ok.test.sh" 1 0 0
    bash "$w/run-all.sh" -j 2 --prove-teath >/dev/null 2>&1; mrc=$?
    if [ "$mrc" -eq 0 ]; then ok "teeth-unknown-flag: refusal-less mutant accepts a trailing typo → the refusal has real teeth"
    else no "teeth-unknown-flag: mutant still refused (rc=$mrc) — mutation not exercised (THEATER)"; fi
  fi
  # Mutation: break the COUNT LOGIC (not the message): the unmutated runner must print the
  # mismatch line for a worker that dies; the mutant must not.
  echo "-- teeth: break the -j result-count comparison; the mismatch line must disappear --"
  w="$(mut_workdir teeth-j-count)"
  { printf '#!/usr/bin/env bash\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
    printf 'kill -9 "$PPID"\n'
  } > "$w/dies.test.sh"
  cp "$SUT" "$w/run-all.good.sh"
  gout="$(bash "$w/run-all.good.sh" -j 2 2>&1)"
  if ! grep -qF 'recorded 0 result(s) for 1 suite(s)' <<<"$gout"; then
    no "teeth-j-count: UNMUTATED runner did not print the mismatch line — control invalid"
  elif ! mutant_sed "$SUT" "$w/run-all.sh" 's/\[\[ "\$_par_results" -ne "\${#all_suites\[@\]}" \]\]/false/' 2>"$w/mutant.err"; then
    no "teeth-j-count: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mout="$(bash "$w/run-all.sh" -j 2 2>&1)"
    if ! grep -qF 'recorded 0 result(s) for 1 suite(s)' <<<"$mout"; then ok "teeth-j-count: count-logic mutant loses the mismatch line the real runner prints → the check has real teeth"
    else no "teeth-j-count: mutant still reports the mismatch — mutation not exercised (THEATER)"; fi
  fi
  # Mutation (kit issue #1491 item 1): neuter the serial attribution call. The real runner names the
  # leaking suite; the mutant must fall back to the batch label.
  echo "-- teeth: neuter the -j serial attribution re-run; the suite name must disappear --"
  w="$(mut_workdir teeth-j-attr)"; _tjkit="${w%/toolbelt/tests}"; mkdir -p "$_tjkit/install"
  { printf '#!/usr/bin/env bash\n'
    printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
    printf 'printf x > "$k/install/leak.MUTANT.sh"\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  } > "$w/a-leaky.test.sh"
  mkfix_sh "$w/b-clean.test.sh" 1 0 0
  cp "$SUT" "$w/run-all.good.sh"
  gout="$(bash "$w/run-all.good.sh" -j 2 2>&1)"
  rm -f "$_tjkit/install/leak.MUTANT.sh"
  if ! grep -qF 'a-leaky.test.sh leaked: install/leak.MUTANT.sh (new)' <<<"$gout"; then
    no "teeth-j-attr: UNMUTATED runner did not name the suite — control invalid"
  elif ! mutant_sed "$SUT" "$w/run-all.sh" 's/^  _attribute_batch_leaks "\$_hv_before" "\$_kv_before"$/  true/' 2>"$w/mutant.err"; then
    no "teeth-j-attr: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mout="$(bash "$w/run-all.sh" -j 2 2>&1)"
    rm -f "$_tjkit/install/leak.MUTANT.sh"
    if ! grep -qF 'a-leaky.test.sh leaked:' <<<"$mout" && grep -qF -- '-j batch (offender unattributed' <<<"$mout"; then
      ok "teeth-j-attr: attribution-neutered mutant reports only the batch label → the attribution has real teeth"
    else no "teeth-j-attr: mutant still names the suite — mutation not exercised (THEATER)"; fi
  fi
  # Mutation (review R4/R3-002): widen the candidate filter to every suite; the bound must disappear.
  echo "-- teeth: drop the attribution window filter; every suite must then be re-run --"
  w="$(mut_workdir teeth-j-bound)"; _tbkit="${w%/toolbelt/tests}"; mkdir -p "$_tbkit/install"
  { printf '#!/usr/bin/env bash\n'
    printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"\n'
    printf 'printf x > "$k/install/leak.MUTANT.sh"\n'
    printf 'sleep 1\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  } > "$w/a-leaky.test.sh"
  mkfix_sh "$w/b-slow.test.sh" 1 0 0; sed -i 's/^exit 0$/sleep 1; exit 0/' "$w/b-slow.test.sh"
  for n in c1 c2 c3 c4; do mkfix_sh "$w/$n.test.sh" 1 0 0; done
  if ! mutant_sed "$SUT" "$w/run-all.sh" "s/BEGIN { exit !(m + 0 >= s - t \&\& m + 0 <= e + t) }/BEGIN { exit 0 }/" 2>"$w/mutant.err"; then
    no "teeth-j-bound: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mout="$(cd "$TMP" && bash "$w/run-all.sh" -j 2 2>&1)"
    rm -f "$_tbkit/install/leak.MUTANT.sh"
    if grep -qE 'attribution re-run: c[0-9]' <<<"$mout" || grep -qE 'attribution re-run: c[0-9]' "$TMP/teeth-j-bound.err" 2>/dev/null; then
      ok "teeth-j-bound: filter-less mutant re-runs clean suites → the bound has real teeth"
    else no "teeth-j-bound: mutant did not widen the re-run — mutation not exercised (THEATER)"; fi
  fi
  # Mutation (review R3-001): signature = mtime only; the restore-mtime suite must go unnamed.
  echo "-- teeth: drop the content hash from the attribution signature; the mtime-restoring suite must go unnamed --"
  w="$(mut_workdir teeth-j-sig)"; _tskit="${w%/toolbelt/tests}"; mkdir -p "$_tskit/install"
  { printf '#!/usr/bin/env bash\n'
    printf 'k="$(cd "$(dirname "$0")/../.." && pwd)"; f="$k/install/leak.MUTANT.sh"\n'
    printf 'm="$(stat -c %%y "$f" 2>/dev/null)"\n'
    printf 'printf "%%s" "$RANDOM$RANDOM$(date +%%N)" > "$f"\n'
    printf '[ -n "$m" ] && touch -d "$m" "$f"\n'
    printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
  } > "$w/a-restore.test.sh"
  mkfix_sh "$w/b-clean.test.sh" 1 0 0
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/^  \[\[ -f "\$1" \]\] && _h="\$(sha1sum.*$/  :/' 2>"$w/mutant.err"; then
    no "teeth-j-sig: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mout="$(cd "$TMP" && bash "$w/run-all.sh" -j 2 2>&1)"
    rm -f "$_tskit/install/leak.MUTANT.sh"
    if ! grep -qF 'a-restore.test.sh leaked:' <<<"$mout"; then ok "teeth-j-sig: hash-less mutant fails to name the mtime-restoring suite → the content hash has real teeth"
    else no "teeth-j-sig: mutant still names the suite — mutation not exercised (THEATER)"; fi
  fi
  # Mutation (item 2): make the non-GNU cause say 'not on PATH'; the non-GNU case must then lose its reason.
  echo "-- teeth: misname the non-GNU DEGRADED cause; the exact reason must disappear --"
  w="$(mut_workdir teeth-j-reason)"
  mkfix_sh "$w/a.test.sh" 1 0 0
  _trbin="$TMP/teeth-reason-bin"; mkdir -p "$_trbin"
  { printf '#!/bin/sh\n'; printf 'echo "not the real thing"\n'; } > "$_trbin/parallel"; chmod +x "$_trbin/parallel"
  if ! mutant_sed "$SUT" "$w/run-all.sh" 's/is not GNU parallel"/is not on PATH"/' 2>"$w/mutant.err"; then
    no "teeth-j-reason: could not build a valid mutant: $(cat "$w/mutant.err")"
  else
    mout="$(PATH="$_trbin:$PATH" bash "$w/run-all.sh" -j 2 2>&1)"
    if ! grep -qF 'is not GNU parallel' <<<"$mout"; then ok "teeth-j-reason: misnamed-cause mutant loses 'is not GNU parallel' → the reason assertion has real teeth"
    else no "teeth-j-reason: mutant still says 'is not GNU parallel' — mutation not exercised (THEATER)"; fi
  fi
fi

echo "== $pass passed $MID $fail failed =="
[ "$fail" -eq 0 ] || exit 1

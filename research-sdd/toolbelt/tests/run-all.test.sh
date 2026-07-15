#!/usr/bin/env bash
# run-all.test.sh — RED-FIRST harness for run-all.sh, the central toolbelt test runner.
#
# The runner is itself a script under test: it auto-discovers sibling suites, streams+captures
# their output, tracks suite outcome by EXIT CODE (via PIPESTATUS, not tee's code, not the parsed
# count), sums case totals off the `== N passed · N failed ==` line (literal U+00B7 middle dot),
# forwards --prove-teeth to *.test.sh only, and exits 0 iff every suite exited 0.
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
fi

echo "== $pass passed $MID $fail failed =="
[ "$fail" -eq 0 ] || exit 1

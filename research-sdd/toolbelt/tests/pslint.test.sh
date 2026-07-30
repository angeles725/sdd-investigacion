#!/usr/bin/env bash
# pslint.test.sh — test suite for pslint.sh, the PowerShell syntax linter.
#
# Tests 1–3 use a fake pwsh stub and run unconditionally on any machine.
# Tests 4–8 require real pwsh; each emits a per-test SKIP when pwsh is
# absent so the suite is never miscounted as fully green on pwsh-less CI.
# Teeth-1 and teeth-2 run unconditionally.  Tooth-3 is skipped when pwsh
# is absent (it must parse a real malformed .ps1).
#
# SKIP convention (run-all.sh §):
#   Whole-suite skip → "SKIP: reason" at line start, then exit 0.
#   Per-test skip    → "  SKIP  description" (two leading spaces).
#
# Usage:
#   pslint.test.sh                 (run tests)
#   pslint.test.sh --prove-teeth   (run tests + mutation self-tests)
#
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../pslint.sh"
[[ -f "$SUT" ]] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [[ -n "$BASH_BIN" ]] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { printf '  PASS  %-68s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no()   { printf '  FAIL  %-68s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
skip() { printf '  SKIP  %s\n' "$1"; }

# Detect real pwsh availability for tests 4-8 and tooth-3.
PWSH_BIN="$(command -v pwsh 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# Fake pwsh stub.
# Used by tests 1-3 to satisfy the PL-PWSH-CHECK guard without requiring a
# real pwsh installation.  Test 1 (no args → exit 2 before the loop) and
# test 2 (missing file → continue before pwsh call) never actually invoke
# this stub; it exists only so the PATH check in the SUT succeeds.
# ---------------------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/pwsh" << 'PSTUB'
#!/usr/bin/env bash
# Fake pwsh — signals availability only; never parses anything in this suite.
exit 0
PSTUB
chmod +x "$STUB/pwsh"

# ---------------------------------------------------------------------------
# Fixtures (tests 4-8 only; harmless to create on any machine).
# ---------------------------------------------------------------------------
CLEAN_PS1="$TMP/clean.ps1"
BAD_PS1="$TMP/bad.ps1"
EMPTY_PS1="$TMP/empty.ps1"
printf 'Write-Output "hello world"\n' > "$CLEAN_PS1"
printf 'function Broken { $x = }  # missing value after =\n' > "$BAD_PS1"
: > "$EMPTY_PS1"   # empty file — valid PowerShell, zero statements

echo "== pslint.test.sh (SUT: $(basename "$SUT")) =="

# ── Tests 1-3: no real pwsh required ──────────────────────────────────────

# 1 — no args → exit 2 (usage).
rc1=0; PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$SUT" >/dev/null 2>&1 || rc1=$?
[[ "$rc1" -eq 2 ]] \
  && ok "1  no args → exit 2" \
  || no "1  no args → exit 2" "rc=$rc1"

# 2 — missing file → exit 1, MISS in stderr.
# The fake stub satisfies the PL-PWSH-CHECK guard.  The file check fires
# before pwsh is ever invoked, so the stub is never called.
err2="$TMP/err2.txt"
rc2=0; PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$SUT" "$TMP/no-such.ps1" \
  >/dev/null 2>"$err2" || rc2=$?
if [[ "$rc2" -eq 1 ]] && grep -q 'MISS' "$err2"; then
  ok "2  missing file → exit 1, MISS in stderr"
else
  no "2  missing file → exit 1, MISS in stderr" "rc=$rc2 stderr=[$(cat "$err2")]"
fi

# 3 — pwsh not on PATH → exit 3.
# The PATH must be EMPTY of everything, not merely trimmed to system dirs: a
# machine where pwsh lives outside them (e.g. linuxbrew) hides it under
# PATH=/usr/bin:/bin, while CI installs pwsh INTO them and the restriction does
# nothing.  This test previously passed locally and failed in CI for exactly
# that reason.  `command -v` is a bash builtin and PL-PWSH-CHECK exits before
# the script needs any external binary, so an empty PATH is safe here.
#
# Assert the PRECONDITION rather than assuming it: if the restricted PATH can
# still reach a pwsh, the test proves nothing about PL-PWSH-CHECK and must say
# so instead of reporting a pass it did not earn.
NOPATH="$TMP/nopath"; mkdir -p "$NOPATH"
if PATH="$NOPATH" command -v pwsh >/dev/null 2>&1; then
  no "3  pwsh not on PATH → exit 3" "precondition failed: pwsh still resolvable under PATH=$NOPATH"
else
  rc3=0; PATH="$NOPATH" "$BASH_BIN" "$SUT" "$CLEAN_PS1" >/dev/null 2>&1 || rc3=$?
  [[ "$rc3" -eq 3 ]] \
    && ok "3  pwsh not on PATH → exit 3" \
    || no "3  pwsh not on PATH → exit 3" "rc=$rc3"
fi

# ── Tests 4-8: real pwsh required ─────────────────────────────────────────

if [[ -z "$PWSH_BIN" ]]; then
  for n in 4 5 6 7 8; do
    skip "$n  (pwsh not available on this machine — install to run this test)"
  done
else

  # 4 — empty .ps1 → exit 0, OK.
  # An empty file is valid PowerShell (zero statements).  The verifier did
  # look; "OK" is the honest answer (anti-silent-zero, CLAUDE.md §7).
  out4="$TMP/out4.txt"
  rc4=0; "$BASH_BIN" "$SUT" "$EMPTY_PS1" >"$out4" 2>&1 || rc4=$?
  if [[ "$rc4" -eq 0 ]] && grep -q '^OK' "$out4"; then
    ok "4  empty .ps1 → exit 0, OK (0 lines)" "$(cat "$out4")"
  else
    no "4  empty .ps1 → exit 0, OK (0 lines)" "rc=$rc4 out=[$(cat "$out4")]"
  fi

  # 5 — clean .ps1 → exit 0, OK with line count.
  out5="$TMP/out5.txt"
  rc5=0; "$BASH_BIN" "$SUT" "$CLEAN_PS1" >"$out5" 2>&1 || rc5=$?
  if [[ "$rc5" -eq 0 ]] && grep -q '^OK' "$out5"; then
    ok "5  clean .ps1 → exit 0, OK" "$(cat "$out5")"
  else
    no "5  clean .ps1 → exit 0, OK" "rc=$rc5 out=[$(cat "$out5")]"
  fi

  # 6 — malformed .ps1 → exit 1, FAIL in stdout with indented error lines.
  # Uses a real .ps1 with a genuine syntax error to test the full error path.
  out6="$TMP/out6.txt"
  rc6=0; "$BASH_BIN" "$SUT" "$BAD_PS1" >"$out6" 2>&1 || rc6=$?
  if [[ "$rc6" -eq 1 ]] && grep -q '^FAIL' "$out6" && grep -q '^ *L[0-9]' "$out6"; then
    ok "6  malformed .ps1 → exit 1, FAIL + indented error" "$(head -2 "$out6")"
  else
    no "6  malformed .ps1 → exit 1, FAIL + indented error" \
       "rc=$rc6 out=[$(cat "$out6")]"
  fi

  # 7 — path with single quote in name → exit 0, no injection.
  # The quoting fix (env-var passing) must handle O'Brien-style directory
  # names that would break a literal 'ParseFile(''$abs'', ...)' approach.
  QUOTE_DIR="$TMP/O'Brien_probe"
  mkdir -p "$QUOTE_DIR"
  printf 'Write-Output "ok"\n' > "$QUOTE_DIR/script.ps1"
  out7="$TMP/out7.txt"
  rc7=0; "$BASH_BIN" "$SUT" "$QUOTE_DIR/script.ps1" >"$out7" 2>&1 || rc7=$?
  if [[ "$rc7" -eq 0 ]] && grep -q '^OK' "$out7"; then
    ok "7  path with single quote → exit 0, no injection (quoting fix)"
  else
    no "7  path with single quote → exit 0, no injection (quoting fix)" \
       "rc=$rc7 out=[$(cat "$out7")]"
  fi

  # 8 — multiple files, one clean and one bad → exit 1, one OK and one FAIL.
  out8="$TMP/out8.txt"
  rc8=0; "$BASH_BIN" "$SUT" "$CLEAN_PS1" "$BAD_PS1" >"$out8" 2>&1 || rc8=$?
  if [[ "$rc8" -eq 1 ]] && grep -q '^OK' "$out8" && grep -q '^FAIL' "$out8"; then
    ok "8  mixed files → exit 1, one OK and one FAIL" "($(wc -l < "$out8") output lines)"
  else
    no "8  mixed files → exit 1, one OK and one FAIL" \
       "rc=$rc8 out=[$(cat "$out8")]"
  fi

fi  # end pwsh guard

# ── Teeth (--prove-teeth) ──────────────────────────────────────────────────
if [[ "${1:-}" == "--prove-teeth" ]]; then

  # tooth-1: neuter PL-PWSH-CHECK → pwsh absent must NOT give exit 3.
  # Proves that test 3's assertion depends on the real PL-PWSH-CHECK guard.
  echo "-- tooth-1: neuter PL-PWSH-CHECK; pwsh absent must NOT give exit 3 --"
  mut1="$TMP/pslint.M1.sh"
  if grep -q '# PL-PWSH-CHECK' "$SUT"; then
    sed '/# PL-PWSH-CHECK/ s/.*/: # PL-PWSH-CHECK [NEUTERED]/' "$SUT" > "$mut1"
    chmod +x "$mut1"
    if "$BASH_BIN" -n "$mut1" 2>/dev/null; then
      # Same empty-PATH requirement as test 3: under PATH=/usr/bin:/bin a CI box
      # with pwsh in a system dir never removes it, so the mutant would exit
      # non-3 for the WRONG reason and this control would pass without biting.
      mrc1=0; PATH="$NOPATH" "$BASH_BIN" "$mut1" "$CLEAN_PS1" >/dev/null 2>&1 || mrc1=$?
      if [[ "$mrc1" -ne 3 ]]; then
        ok "tooth-1: neutered PL-PWSH-CHECK → pwsh absent no longer gives exit 3 (test 3 bites)" "mrc=$mrc1"
      else
        no "tooth-1: neutered PL-PWSH-CHECK still gives exit 3 → test 3 is THEATER" "mrc=$mrc1"
      fi
    else
      no "tooth-1: mutant failed bash -n (mutant is syntactically invalid)"
    fi
  else
    no "tooth-1: PL-PWSH-CHECK sentinel not found in SUT"
  fi

  # tooth-2: neuter PL-FILE-CHECK → missing file must NOT emit MISS.
  # Proves that test 2's MISS assertion depends on the real file-existence guard.
  # With the guard neutered, the fake stub's pwsh is called, returns OK, so
  # MISS is never emitted even though the file does not exist.
  echo "-- tooth-2: neuter PL-FILE-CHECK; missing file must NOT emit MISS --"
  mut2="$TMP/pslint.M2.sh"
  if grep -q '# PL-FILE-CHECK' "$SUT"; then
    sed '/# PL-FILE-CHECK/ s/.*/: # PL-FILE-CHECK [NEUTERED]/' "$SUT" > "$mut2"
    chmod +x "$mut2"
    if "$BASH_BIN" -n "$mut2" 2>/dev/null; then
      merr2="$TMP/merr2.txt"
      PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$mut2" "$TMP/no-such.ps1" \
        >/dev/null 2>"$merr2" || true
      if ! grep -q 'MISS' "$merr2"; then
        ok "tooth-2: neutered PL-FILE-CHECK → missing file no longer emits MISS (test 2 bites)"
      else
        no "tooth-2: neutered PL-FILE-CHECK still emits MISS → test 2 is THEATER" \
           "merr=[$(cat "$merr2")]"
      fi
    else
      no "tooth-2: mutant failed bash -n (mutant is syntactically invalid)"
    fi
  else
    no "tooth-2: PL-FILE-CHECK sentinel not found in SUT"
  fi

  # tooth-3: neuter PL-ERRORS-CHECK → bad .ps1 must NOT show FAIL in stdout.
  # Proves that test 6's FAIL assertion depends on the real errors-check guard.
  # Requires real pwsh to parse the bad fixture and produce error output.
  echo "-- tooth-3: neuter PL-ERRORS-CHECK; bad .ps1 must NOT show FAIL in stdout --"
  if [[ -z "$PWSH_BIN" ]]; then
    skip "tooth-3  (pwsh not available — cannot run real parse against mutant)"
  else
    mut3="$TMP/pslint.M3.sh"
    if grep -q '# PL-ERRORS-CHECK' "$SUT"; then
      sed '/# PL-ERRORS-CHECK/ s/.*/    if false; then  # PL-ERRORS-CHECK [NEUTERED]/' \
        "$SUT" > "$mut3"
      chmod +x "$mut3"
      if "$BASH_BIN" -n "$mut3" 2>/dev/null; then
        mout3="$TMP/mout3.txt"
        "$BASH_BIN" "$mut3" "$BAD_PS1" >"$mout3" 2>&1 || true
        if ! grep -q '^FAIL' "$mout3"; then
          ok "tooth-3: neutered PL-ERRORS-CHECK → bad .ps1 no longer shows FAIL (test 6 bites)"
        else
          no "tooth-3: neutered PL-ERRORS-CHECK still shows FAIL → test 6 is THEATER" \
             "mout=[$(cat "$mout3")]"
        fi
      else
        no "tooth-3: mutant failed bash -n (mutant is syntactically invalid)"
      fi
    else
      no "tooth-3: PL-ERRORS-CHECK sentinel not found in SUT"
    fi
  fi

fi  # end --prove-teeth

echo "== $pass passed · $fail failed =="
[[ "$fail" -eq 0 ]] || exit 1

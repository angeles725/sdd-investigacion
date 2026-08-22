#!/usr/bin/env bash
# serial-console.test.sh — companion test for serial-console.sh.
# Covers: usage/exit-code contracts, POWERSHELL_BIN stub injection, run
# validations, preservation output, mkdir and tee error paths, and mutation
# proof.
# Exit: 0 all held · 1 regression · 2 harness error
#
# Tests assert CURRENT script behavior; a failing assertion against the live
# script is a potential script bug — it is documented, not worked around.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../serial-console.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== serial-console.test.sh =="

# ---- 1. Existence ------------------------------------------------------------
[ -f "$SUT" ] \
  && ok "1 serial-console.sh exists at $SUT" \
  || no "1 serial-console.sh NOT found at $SUT"

if [ ! -f "$SUT" ]; then
  for n in 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
    no "$n (skipped: SUT missing)"
  done
  echo "== $pass passed · $fail failed =="
  exit 2
fi

# ---- Temp workspace ----------------------------------------------------------
TMP="$(mktemp -d)"
trap 'chmod -R 755 "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# Path guaranteed not to exist — simulates an absent POWERSHELL_BIN.
ABSENT="$TMP/no-such-powershell"

# make_stub <dir> <exit_code> <text>
# Creates an executable stub at <dir>/stub-pwsh.sh that ignores all arguments
# (PowerShell flags), prints <text> to stdout, and exits <exit_code>.
# Returns (prints) the stub's absolute path.
# Assumption: <text> contains no single-quote characters.
make_stub() {
  local dir="$1" rc="$2" txt="$3" stub
  mkdir -p -- "$dir"
  stub="$dir/stub-pwsh.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    # Ignore all positional args; emit the canned output line.
    printf '%s\n' "printf '%s\\n' '$txt'"
    printf 'exit %s\n' "$rc"
  } > "$stub"
  chmod +x "$stub"
  printf '%s' "$stub"
}

# ---- 2. No mode → usage + exit 2 --------------------------------------------
OUT="$(bash "$SUT" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'usage' \
  && ok "2 no mode → exit 2 + usage on stderr" \
  || no "2 no mode → expected exit 2 + usage, got exit=$RC out=[$OUT]"

# ---- 3. Unknown mode → usage + exit 2 + "unknown mode" message --------------
OUT="$(bash "$SUT" frobble 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'unknown mode' \
  && ok "3 unknown mode → exit 2 + unknown-mode message" \
  || no "3 unknown mode → expected exit 2 + unknown-mode, got exit=$RC out=[$OUT]"

# ---- 4. list + absent POWERSHELL_BIN → exit 3 + interop message -------------
OUT="$(POWERSHELL_BIN="$ABSENT" bash "$SUT" list 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && printf '%s\n' "$OUT" | grep -qF 'cannot reach' \
  && ok "4 list + absent bin → exit 3 + interop message" \
  || no "4 list + absent bin → expected exit 3 + interop msg, got exit=$RC out=[$OUT]"

# ---- 5. check + absent POWERSHELL_BIN → exit 3 ------------------------------
OUT="$(POWERSHELL_BIN="$ABSENT" bash "$SUT" check 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
  && ok "5 check + absent bin → exit 3" \
  || no "5 check + absent bin → expected exit 3, got exit=$RC out=[$OUT]"

# ---- 6. check + stub printing "OK" → exit 0 + "interop: OK" ----------------
STUB6="$(make_stub "$TMP/t6" 0 "OK")"
OUT="$(POWERSHELL_BIN="$STUB6" bash "$SUT" check 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF 'interop: OK' \
  && ok "6 check + OK stub → exit 0 + 'interop: OK'" \
  || no "6 check + OK stub → expected exit 0 + interop: OK, got exit=$RC out=[$OUT]"

# ---- 7. check + stub printing non-OK output → exit 3 -----------------------
STUB7="$(make_stub "$TMP/t7" 0 "FAIL_OUTPUT")"
OUT="$(POWERSHELL_BIN="$STUB7" bash "$SUT" check 2>&1)"; RC=$?
[ "$RC" -eq 3 ] \
  && ok "7 check + non-OK stub output → exit 3" \
  || no "7 check + non-OK stub → expected exit 3, got exit=$RC out=[$OUT]"

# ---- 8. run: too few args → exit 2 + usage ----------------------------------
OUT="$(bash "$SUT" run /tmp COM3 9600 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'usage' \
  && ok "8 run: too few args → exit 2 + usage" \
  || no "8 run: too few args → expected exit 2 + usage, got exit=$RC out=[$OUT]"

# ---- 9. run: too many args → exit 2 + usage ---------------------------------
OUT="$(bash "$SUT" run /tmp COM3 9600 cmd extra 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'usage' \
  && ok "9 run: too many args → exit 2 + usage" \
  || no "9 run: too many args → expected exit 2 + usage, got exit=$RC out=[$OUT]"

# ---- 10. run: dash-leading target-dir → exit 2 ------------------------------
# no_dash() rejects paths that start with '-'; the error message says
# "must not start with '-'".
OUT="$(bash "$SUT" run -bad-dir COM3 9600 "show ver" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF "must not start with" \
  && ok "10 run: dash-leading target-dir → exit 2 + must-not-start-with message" \
  || no "10 run: dash-leading target-dir → expected exit 2, got exit=$RC out=[$OUT]"

# ---- 11. run: bad COM port (lowercase) → exit 2 + com-port message ----------
OUT="$(bash "$SUT" run "$TMP" com3 9600 "show ver" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'com-port' \
  && ok "11 run: bad COM port (lowercase) → exit 2 + com-port message" \
  || no "11 run: bad COM port → expected exit 2 + com-port msg, got exit=$RC out=[$OUT]"

# ---- 12. run: non-numeric baud → exit 2 + baud message ---------------------
OUT="$(bash "$SUT" run "$TMP" COM3 fast "show ver" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'baud' \
  && ok "12 run: non-numeric baud → exit 2 + baud message" \
  || no "12 run: non-numeric baud → expected exit 2 + baud msg, got exit=$RC out=[$OUT]"

# ---- 13. run: empty command → exit 2 + empty message -----------------------
OUT="$(bash "$SUT" run "$TMP" COM3 9600 "" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'empty' \
  && ok "13 run: empty command → exit 2 + empty message" \
  || no "13 run: empty command → expected exit 2 + empty msg, got exit=$RC out=[$OUT]"

# ---- 14. run + absent POWERSHELL_BIN (all args valid) → exit 3 + interop ---
# The have() check is after validation; pass all valid args to reach it.
OUT="$(POWERSHELL_BIN="$ABSENT" bash "$SUT" run "$TMP" COM3 9600 "show ver" 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && printf '%s\n' "$OUT" | grep -qF 'cannot reach' \
  && ok "14 run + absent bin → exit 3 + interop message" \
  || no "14 run + absent bin → expected exit 3 + interop msg, got exit=$RC out=[$OUT]"

# ---- 15. run OK (stub rc=0) → file created + preserved: [CERT-hw] + exit 0 -
TDIR15="$TMP/t15-target"
mkdir -p -- "$TDIR15"
STUB15="$(make_stub "$TMP/t15-stub" 0 "hw output line")"
OUT15="$(POWERSHELL_BIN="$STUB15" bash "$SUT" run "$TDIR15" COM3 9600 "show version" 2>&1)"
RC15=$?
FILE15="$(find "$TDIR15/sources/probes" -name 'serial-COM3-*.txt' 2>/dev/null | head -1)"
[ "$RC15" -eq 0 ] \
  && printf '%s\n' "$OUT15" | grep -qF 'preserved:' \
  && printf '%s\n' "$OUT15" | grep -qF '[CERT-hw]' \
  && [ -n "$FILE15" ] && [ -f "$FILE15" ] \
  && ok "15 run OK (rc=0) → file created + 'preserved: [CERT-hw]' in output + exit 0" \
  || no "15 run OK → expected exit 0 + preserved file + preserved: [CERT-hw], got exit=$RC15 file=[$FILE15] out=[$OUT15]"

# ---- 16. run: stub exits non-zero → SUT mirrors that rc --------------------
TDIR16="$TMP/t16-target"
mkdir -p -- "$TDIR16"
STUB16="$(make_stub "$TMP/t16-stub" 7 "hw error text")"
OUT16="$(POWERSHELL_BIN="$STUB16" bash "$SUT" run "$TDIR16" COM3 9600 "show ver" 2>&1)"
RC16=$?
[ "$RC16" -eq 7 ] \
  && ok "16 run: stub exits 7 → SUT mirrors rc=7" \
  || no "16 run: stub exits 7 → expected exit 7, got exit=$RC16 out=[$OUT16]"

# ---- 17. mkdir failure → exit 4 + error message ----------------------------
# Pre-create TDIR with mode 555 so mkdir cannot create sources/probes inside.
# POWERSHELL_BIN must be present to pass the have() check before mkdir.
TDIR17="$TMP/t17-nowrite"
mkdir -p -- "$TDIR17"
chmod 555 "$TDIR17"
STUB17="$(make_stub "$TMP/t17-stub" 0 "hw")"
OUT17="$(POWERSHELL_BIN="$STUB17" bash "$SUT" run "$TDIR17" COM3 9600 "show ver" 2>&1)"
RC17=$?
chmod 755 "$TDIR17"
[ "$RC17" -eq 4 ] && printf '%s\n' "$OUT17" | grep -qF 'cannot create preservation dir' \
  && ok "17 mkdir failure → exit 4 + cannot-create-preservation-dir message" \
  || no "17 mkdir failure → expected exit 4 + cannot create preservation dir, got exit=$RC17 out=[$OUT17]"

# ---- 18. tee failure → exit 5 + error message -------------------------------
# Pre-create OUTDIR with mode 555 so mkdir -p succeeds (dir already exists)
# but tee cannot create the output file inside.
TDIR18="$TMP/t18-target"
OUTDIR18="$TDIR18/sources/probes"
mkdir -p -- "$OUTDIR18"
chmod 555 "$OUTDIR18"
STUB18="$(make_stub "$TMP/t18-stub" 0 "hw output")"
OUT18="$(POWERSHELL_BIN="$STUB18" bash "$SUT" run "$TDIR18" COM3 9600 "show ver" 2>&1)"
RC18=$?
chmod 755 "$OUTDIR18"
[ "$RC18" -eq 5 ] && printf '%s\n' "$OUT18" | grep -qF 'preservation FAILED' \
  && ok "18 tee failure → exit 5 + preservation-failed message" \
  || no "18 tee failure → expected exit 5 + preservation FAILED, got exit=$RC18 out=[$OUT18]"

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutants of serial-console.sh must be caught by specific assertions --"

  # Tooth A: delete the 'preserved:' echo line entirely so the 'preserved:'
  # string never appears in stdout.  Test 15's grep for 'preserved:' must
  # catch this → assertion goes RED.
  sed '/echo "preserved:/d' "$SUT" > "$TMP/mutant-a.sh"
  chmod +x "$TMP/mutant-a.sh"
  TDIR_A="$TMP/teeth-a-target"
  mkdir -p -- "$TDIR_A"
  STUB_A="$(make_stub "$TMP/teeth-a-stub" 0 "hw")"
  MUTANT_A_OUT="$(POWERSHELL_BIN="$STUB_A" bash "$TMP/mutant-a.sh" run \
    "$TDIR_A" COM3 9600 "show ver" 2>&1)"
  if ! printf '%s\n' "$MUTANT_A_OUT" | grep -qF 'preserved:'; then
    ok "teeth A: 'preserved:' removed → test 15 assertion catches it (RED)"
  else
    no "teeth A: mutant still emits 'preserved:' — sed did not take effect, check mutation"
  fi

  # Tooth B: replace 'exit 5' (preservation-fail guard) with 'exit 0'.
  # Test 18's exit-code check for 5 must catch this → assertion goes RED.
  sed 's/exit 5$/exit 0/' "$SUT" > "$TMP/mutant-b.sh"
  chmod +x "$TMP/mutant-b.sh"
  TDIR_B="$TMP/teeth-b-target"
  OUTDIR_B="$TDIR_B/sources/probes"
  mkdir -p -- "$OUTDIR_B"
  chmod 555 "$OUTDIR_B"
  STUB_B="$(make_stub "$TMP/teeth-b-stub" 0 "hw")"
  MUTANT_B_RC=0
  { POWERSHELL_BIN="$STUB_B" bash "$TMP/mutant-b.sh" run \
    "$TDIR_B" COM3 9600 "show ver" >/dev/null 2>&1; } || MUTANT_B_RC=$?
  chmod 755 "$OUTDIR_B"
  if [ "$MUTANT_B_RC" -ne 5 ]; then
    ok "teeth B: exit 5 → exit 0 mutant → test 18 assertion catches it (RED)"
  else
    no "teeth B: mutant still exits 5 — sed did not take effect, check mutation"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

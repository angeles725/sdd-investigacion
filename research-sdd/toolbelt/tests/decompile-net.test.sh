#!/usr/bin/env bash
# decompile-net.test.sh — RED-FIRST harness for decompile-net.sh.
#
# B1 REGRESSION: `--list` mode used `--list-types` (rejected by ilspycmd 8.2.0).
# The correct flag is `-l c`. This suite stubs ilspycmd to record its arguments
# and asserts the stub receives `-l c`, not `--list-types`.
#
# Usage: decompile-net.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../decompile-net.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== decompile-net.test.sh (SUT: $(basename "$SUT")) =="

# Stub ilspycmd: records all arguments one per line, then exits 0.
STUB="$TMP/ilspycmd"; RECORD="$TMP/args.txt"; DLL="$TMP/test.dll"
cat > "$STUB" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$RECORD"
SH
chmod +x "$STUB"
: > "$DLL"   # dummy DLL file so the -x guard passes

# B1 CORE — --list mode must pass -l c, NOT --list-types.
ILSPYCMD="$STUB" RECORD="$RECORD" bash "$SUT" --list "$DLL" >/dev/null 2>&1
if [ "$(sed -n '1p' "$RECORD")" = "-l" ] && [ "$(sed -n '2p' "$RECORD")" = "c" ]; then
  ok "B1: --list passes -l c to ilspycmd (not --list-types)"
else
  no "B1: --list flag wrong — got '$(head -2 "$RECORD" | tr '\n' ' ')' (want '-l c')"
fi

# Negative control — verify the stub itself works (--list-types would land on line 1 as one token)
ILSPYCMD="$STUB" RECORD="$TMP/negctrl.txt" bash "$SUT" --list "$DLL" >/dev/null 2>&1
if ! grep -qxF -- '--list-types' "$TMP/negctrl.txt" 2>/dev/null; then
  ok "B1 neg-ctrl: --list-types absent from recorded args"
else
  no "B1 neg-ctrl: --list-types still present — fix not applied"
fi

# ilspycmd missing → exit 3 (guard check).
ILSPYCMD="$TMP/nonexistent" bash "$SUT" --list "$DLL" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 3 ]; then ok "missing ilspycmd → exit 3"
else no "missing ilspycmd: got exit $rc (want 3)"; fi

# --il mode is unrelated (passes --il) — sanity test.
ILSPYCMD="$STUB" RECORD="$TMP/il.txt" bash "$SUT" --il "$DLL" "$TMP/out-il" >/dev/null 2>&1
if grep -qxF -- '--il' "$TMP/il.txt" 2>/dev/null; then
  ok "--il mode still passes --il (unrelated to B1)"
else
  no "--il mode flag check failed"
fi

# TEETH — prove that the B1 assertion fails against the old --list-types flag.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutate stub check to expect --list-types; expect B1 to now fail --"
  # Run with a stub that uses the OLD flag
  MUTANT_SUT="$TMP/decompile-net.MUTANT.sh"
  sed 's/-l c/--list-types/' "$SUT" > "$MUTANT_SUT"
  if ! grep -q -- '--list-types' "$MUTANT_SUT"; then
    no "teeth: could not build mutant (old flag not found — did the SUT already not have it?)"
  else
    RECORD2="$TMP/mutant.args.txt"
    ILSPYCMD="$STUB" RECORD="$RECORD2" bash "$MUTANT_SUT" --list "$DLL" >/dev/null 2>&1
    if [ "$(sed -n '1p' "$RECORD2")" != "-l" ]; then
      ok "teeth: mutant uses --list-types (not -l c) → B1 check would fail on mutant"
    else
      no "teeth: mutant still emits -l c — B1 does NOT depend on the fix (THEATER)"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SOURCE="$HERE/../decompile-native.sh"
[ -x "$SOURCE" ] || { echo "FATAL: SUT not found: $SOURCE" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
mkdir -p "$ROOT/toolbelt/lib" "$ROOT/gh/support" "$ROOT/jdk" "$ROOT/bin" "$ROOT/out"
cp "$SOURCE" "$ROOT/toolbelt/decompile-native.sh"
cat >"$ROOT/toolbelt/lib/tool-env.sh" <<'SH'
rsdd_resolve_java_home(){ printf '%s\n' "$TEST_ROOT/jdk"; }
rsdd_resolve_ghidra_home(){ printf '%s\n' "$TEST_ROOT/gh"; }
SH
cat >"$ROOT/toolbelt/corroborate-ghidra.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$RECORD"
SH
cat >"$ROOT/gh/support/analyzeHeadless" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$RECORD"
SH
cat >"$ROOT/bin/r2" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$RECORD"
SH
chmod +x "$ROOT/toolbelt/corroborate-ghidra.sh" "$ROOT/gh/support/analyzeHeadless" "$ROOT/bin/r2"
SUT="$ROOT/toolbelt/decompile-native.sh"; INPUT="$ROOT/input with spaces.bin"; : >"$INPUT"

if TEST_ROOT="$ROOT" RECORD="$ROOT/evidence.args" "$SUT" ghidra-evidence "$INPUT" "$ROOT/out/evidence" \
  && [ "$(sed -n '1p' "$ROOT/evidence.args")" = --input ] && [ "$(sed -n '2p' "$ROOT/evidence.args")" = "$INPUT" ] \
  && [ "$(sed -n '3p' "$ROOT/evidence.args")" = --output ] && [ "$(sed -n '4p' "$ROOT/evidence.args")" = "$ROOT/out/evidence" ] \
  && [ "$(wc -l <"$ROOT/evidence.args")" -eq 4 ]; then ok 'evidence route forwards only safe input/output arguments'; else no 'evidence route forwarding'; fi
rm "$ROOT/toolbelt/corroborate-ghidra.sh"
TEST_ROOT="$ROOT" "$SUT" ghidra-evidence "$INPUT" "$ROOT/out/missing" 2>"$ROOT/missing.err"; rc=$?
if [ "$rc" -eq 3 ] && grep -q 'evidence adapter not found' "$ROOT/missing.err"; then ok 'missing evidence adapter fails explicitly'; else no 'missing adapter failure'; fi
if TEST_ROOT="$ROOT" RECORD="$ROOT/raw.args" "$SUT" ghidra "$INPUT" "$ROOT/out/raw" \
  && grep -Fxq -- '-import' "$ROOT/raw.args" && grep -Fxq -- "$INPUT" "$ROOT/raw.args"; then ok 'raw ghidra mode remains distinct'; else no 'raw ghidra mode'; fi
# B2 — Ghidra project dir must NOT start with a dot (Ghidra 12.1.2 rejects leading-dot path elements).
# The project dir is the FIRST argument to analyzeHeadless (from raw.args, line 1).
_proj_dir="$(head -1 "$ROOT/raw.args" 2>/dev/null)"
_proj_base="${_proj_dir##*/}"   # basename via parameter expansion (no external command — safe inside clean-PATH teeth run)
if [ "${_proj_base:-x}" = "ghidra-proj" ]; then
  ok "B2: ghidra project dir is 'ghidra-proj' (no leading dot — Ghidra 12.1.2 rejects dots)"
else
  no "B2: ghidra project dir is '${_proj_base:-<empty>}' (want 'ghidra-proj', not '.ghidra-proj')"
fi
if TEST_ROOT="$ROOT" PATH="$ROOT/bin:$PATH" RECORD="$ROOT/r2.args" "$SUT" r2 "$INPUT" \
  && grep -Fxq -- "$INPUT" "$ROOT/r2.args"; then ok 'r2 mode still dispatches'; else no 'r2 mode'; fi
if ! command -v file >/dev/null 2>&1 || ! command -v strings >/dev/null 2>&1; then
  echo "  SKIP  quick mode (missing: file or strings)"
else
  if "$SOURCE" quick /bin/true >/dev/null; then ok 'quick mode still dispatches'; else no 'quick mode'; fi
fi

# TEETH — prove the guard is per-test, not suite-level.
# Run inner call with a clean PATH that omits file and strings; the host-independent
# tests must still produce ≥4 passes. A suite-level guard produces 0 (exits early).
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: per-test guard must not collapse into a suite-level skip --"
  _clean="$ROOT/clean-bin"; mkdir -p "$_clean"
  for _c in bash mktemp rm mkdir cp chmod cat sed grep wc dirname head; do
    _p="$(builtin command -v "$_c" 2>/dev/null)"
    [ -n "$_p" ] && ln -s "$_p" "$_clean/$_c"
  done
  _out="$(PATH="$_clean" bash "$HERE/decompile-native.test.sh" 2>&1)"
  _np="$(printf '%s\n' "$_out" | grep -oE '^== [0-9]+' | grep -oE '[0-9]+')"
  if [ "${_np:-0}" -ge 5 ]; then
    ok "teeth: per-test guard keeps ≥5 host-independent tests with file/strings absent (${_np} passed)"
  else
    no "teeth: per-test guard collapsed; ${_np:-0} tests ran without file/strings (want ≥5)"
  fi
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]

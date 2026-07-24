#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SOURCE="$HERE/../decompile-native.sh"
[ -x "$SOURCE" ] || { echo "FATAL: SUT not found: $SOURCE" >&2; exit 2; }
# Tool-availability guard — skip gracefully when required tools are absent.
if ! command -v file >/dev/null 2>&1 || ! command -v strings >/dev/null 2>&1; then
  echo "SKIP: decompile-native tests (missing: file or strings)"
  echo "== 0 passed · 0 failed =="
  exit 0
fi
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
if TEST_ROOT="$ROOT" PATH="$ROOT/bin:$PATH" RECORD="$ROOT/r2.args" "$SUT" r2 "$INPUT" \
  && grep -Fxq -- "$INPUT" "$ROOT/r2.args"; then ok 'r2 mode still dispatches'; else no 'r2 mode'; fi
if "$SOURCE" quick /bin/true >/dev/null; then ok 'quick mode still dispatches'; else no 'quick mode'; fi
echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]

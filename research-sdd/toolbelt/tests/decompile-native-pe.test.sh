#!/usr/bin/env bash
# decompile-native-pe.test.sh — `decompile-native.sh quick` on a PE binary (MZ magic) skips readelf
# (ELF only) and still prints its strings; an ELF binary still goes through readelf.
# Kept apart from decompile-native.test.sh so that suite does not grow further.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SOURCE="$HERE/../decompile-native.sh"
[ -x "$SOURCE" ] || { echo "FATAL: SUT not found: $SOURCE" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
mkdir -p "$ROOT/toolbelt/lib" "$ROOT/stub"
cp "$SOURCE" "$ROOT/toolbelt/decompile-native.sh"
: >"$ROOT/toolbelt/lib/tool-env.sh"
SUT="$ROOT/toolbelt/decompile-native.sh"

# A synthetic PE: the DOS "MZ" magic, padding, then a printable string for the strings section.
PE="$ROOT/sample.exe"
{ printf 'MZ'; head -c 62 /dev/zero; printf 'PE_MARKER_STRING_42\n'; } >"$PE"
# Stub readelf: records each call and fails, as the real readelf does on a PE ("Not an ELF file").
cat >"$ROOT/stub/readelf" <<'SH'
#!/bin/sh
echo called >>"$READELF_LOG"
echo "readelf: Error: Not an ELF file - it has the wrong magic bytes at the start" >&2
exit 1
SH
chmod +x "$ROOT/stub/readelf"

# run_quick SUT BIN — quick mode with the stub readelf first on PATH; prints PE_FACT for the teeth.
run_quick() {
  local log="$ROOT/readelf.$$.$RANDOM.log" rc
  env READELF_LOG="$log" PATH="$ROOT/stub:$PATH" bash "$1" quick "$2" >"$ROOT/out" 2>"$ROOT/err"; rc=$?
  cat "$ROOT/out" "$ROOT/err"
  printf 'PE_FACT=rc:%s readelf:%s strings:%s\n' "$rc" "$([ -s "$log" ] && echo called || echo skipped)" \
    "$(grep -q 'PE_MARKER_STRING_42' "$ROOT/out" && echo shown || echo absent)"
  return "$rc"
}

if ! command -v file >/dev/null 2>&1 || ! command -v strings >/dev/null 2>&1; then
  echo "  SKIP  PE quick mode (missing: file or strings)"
else
  # P1 — a PE binary: exit 0, readelf never called, strings printed, the skip is named.
  _p1="$(run_quick "$SUT" "$PE")"
  if <<<"$_p1" grep -qx 'PE_FACT=rc:0 readelf:skipped strings:shown' \
     && <<<"$_p1" grep -q 'readelf skipped: PE binary'; then
    ok "P1: quick on a PE binary skips readelf and prints strings (exit 0)"
  else
    no "P1: quick on a PE binary — $(<<<"$_p1" grep '^PE_FACT=' || echo 'no PE_FACT')"
  fi
  # P2 — previous behaviour: an ELF binary still runs readelf, and its failure still surfaces.
  _p2="$(run_quick "$SUT" /bin/true)"
  if <<<"$_p2" grep -q '^PE_FACT=rc:1 readelf:called ' && <<<"$_p2" grep -q 'readelf failed (rc=1)'; then
    ok "P2: quick on an ELF binary still runs readelf and surfaces its failure"
  else
    no "P2: quick on an ELF binary — $(<<<"$_p2" grep '^PE_FACT=' || echo 'no PE_FACT')"
  fi
fi

if [ "${1:-}" = "--prove-teeth" ] && command -v file >/dev/null 2>&1 && command -v strings >/dev/null 2>&1; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_tooth mutant_chain_or_count mutant_crash_re || exit 2
  CRASH_RE="$(mutant_crash_re bash)" || exit 2
  echo "-- teeth PE1: the MZ check never matches → P1 must go red --"
  mkdir -p "$ROOT/mut/pe1/lib" && cp "$ROOT/toolbelt/lib/tool-env.sh" "$ROOT/mut/pe1/lib/tool-env.sh"
  if mutant_chain_or_count fail "PE1 teeth: build" "$SOURCE" "$ROOT/mut/pe1/decompile-native.sh" \
       's/\[ "\$_magic" = MZ \]/[ "$_magic" = NOT_MZ ]/'; then
    if mutant_tooth "PE1-killed: mutant runs readelf on a PE and fails — P1 detection confirmed" 0 1 \
         "$ROOT/mut/pe1/decompile-native.sh" --orig "$SUT" \
         --good-has '^PE_FACT=rc:0 readelf:skipped strings:shown$' \
         --bad-has '^PE_FACT=rc:1 readelf:called strings:absent$' --bad-lacks "$CRASH_RE" \
         -- run_quick @SUT@ "$PE"; then pass=$((pass+1)); else fail=$((fail+1)); fi
  fi
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]

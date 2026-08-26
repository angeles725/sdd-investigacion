#!/usr/bin/env bash
# tests/scan-firmware.test.sh — scan-firmware.sh dispatcher
#
# Cases:
#   S1: unknown mode → exit 2 with diagnostic
#   S2: extract mode → exit 2 with removal message (legacy safety gate)
#   S3: scan with absent binwalk → exit 3 with 'binwalk not installed'
#   S4: genuine binwalk entropy failure (non-0/non-141) → surfaces error (§7 fix)
#   --prove-teeth M1: revert entropy guard to || true → S4 goes RED
#
# All stub-based cases (S1–S4) run without real binwalk; they never SKIP on CI.
# If a future case needs the real binwalk binary, guard it with:
#   command -v binwalk >/dev/null || { echo "  SKIP  <case> (binwalk absent)"; }
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; SOURCE="$HERE/../scan-firmware.sh"
[ -x "$SOURCE" ] || { echo "FATAL: SUT not found: $SOURCE" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
: >"$ROOT/firmware.bin"

# S1 — unknown mode exits 2 with diagnostic
"$SOURCE" unknown 2>"$ROOT/s1.err"; _s1rc=$?
if [ "$_s1rc" -eq 2 ] && grep -q 'unknown mode' "$ROOT/s1.err"; then
  ok "S1: unknown mode exits 2 with diagnostic"
else
  no "S1: unknown mode: exit=$_s1rc (want 2) or no 'unknown mode' in stderr"
fi

# S2 — extract mode exits 2 with removal message (legacy extraction safety gate)
"$SOURCE" extract 2>"$ROOT/s2.err"; _s2rc=$?
if [ "$_s2rc" -eq 2 ] && grep -q 'extract was removed' "$ROOT/s2.err"; then
  ok "S2: extract mode exits 2 with 'extract was removed' message"
else
  no "S2: extract mode: exit=$_s2rc (want 2) or no 'extract was removed' in stderr"
fi

# S3 — scan exits 3 when binwalk is absent
# Build a minimal PATH: bash only (needed for shebang /usr/bin/env bash), no binwalk.
# Replacing PATH entirely means /usr/bin/env can find bash only if we put it there.
_s3_nobin="$ROOT/s3-nobin"; mkdir -p "$_s3_nobin"
_bash_path="$(command -v bash 2>/dev/null)"; [ -n "$_bash_path" ] && ln -sf "$_bash_path" "$_s3_nobin/bash"
PATH="$_s3_nobin" "$SOURCE" scan "$ROOT/firmware.bin" 2>"$ROOT/s3.err"; _s3rc=$?
if [ "$_s3rc" -eq 3 ] && grep -q 'binwalk not installed' "$ROOT/s3.err"; then
  ok "S3: scan exits 3 with 'binwalk not installed' when binwalk absent"
else
  no "S3: absent binwalk: exit=$_s3rc (want 3) or no 'binwalk not installed' in stderr"
fi

# S4 — genuine binwalk failure on the entropy step must NOT be silently swallowed.
# Stub binwalk exits 2 on the entropy invocation (-E flag), exits 0 on signatures.
# The fix surfaces the entropy failure; bare '|| true' swallows it silently.
# Mutation M1 (--prove-teeth) confirms S4 catches that.
_stubdir_s4="$ROOT/stub-s4"; mkdir -p "$_stubdir_s4"
cat >"$_stubdir_s4/binwalk" <<'SH'
#!/bin/sh
# Entropy invocation carries the -E flag; signatures invocation does not.
case "$*" in
  *-E*) echo "binwalk: stub: entropy failed" >&2; exit 2 ;;
  *) printf '0\t0x0\tstub signature\n'; exit 0 ;;
esac
SH
chmod +x "$_stubdir_s4/binwalk"
PATH="$_stubdir_s4:$PATH" "$SOURCE" scan "$ROOT/firmware.bin" \
  >"$ROOT/s4.out" 2>"$ROOT/s4.err"; _s4rc=$?
if [ "$_s4rc" -ne 0 ] || grep -q 'binwalk entropy scan failed' "$ROOT/s4.err"; then
  ok "S4: genuine binwalk entropy failure surfaces (rc=$_s4rc, not silently swallowed)"
else
  no "S4: genuine binwalk entropy failure silently swallowed (rc=0, no diagnostic)"
fi

# --prove-teeth: mutation controls
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: M1 mutation: revert binwalk entropy guard to || true → S4 must go red --"
  _m1="$ROOT/scan-firmware.M1.sh"
  # Revert the PIPESTATUS-guarded form back to bare '|| true'.
  sed 's/|| { _sp=.*/|| true   # entropy/' "$SOURCE" > "$_m1"
  chmod +x "$_m1"
  # Confirm the mutant has || true and no PIPESTATUS (scan-firmware has only one guard).
  if grep -qF '|| true' "$_m1" && ! grep -qF 'PIPESTATUS' "$_m1"; then
    _stubdir_m1="$ROOT/stub-m1"; mkdir -p "$_stubdir_m1"
    cat >"$_stubdir_m1/binwalk" <<'SH'
#!/bin/sh
case "$*" in
  *-E*) echo "binwalk: stub: entropy failed" >&2; exit 2 ;;
  *) printf '0\t0x0\tstub signature\n'; exit 0 ;;
esac
SH
    chmod +x "$_stubdir_m1/binwalk"
    # Mutant: entropy step swallowed (|| true); signatures step succeeds (stub exits 0).
    # So the mutant exits 0 with no 'binwalk entropy scan failed' diagnostic.
    PATH="$_stubdir_m1:$PATH" "$_m1" scan "$ROOT/firmware.bin" \
      >/dev/null 2>"$ROOT/m1.err"; _m1rc=$?
    if [ "$_m1rc" -eq 0 ] && ! grep -q 'binwalk entropy scan failed' "$ROOT/m1.err"; then
      ok "M1-killed: || true mutant swallows binwalk entropy failure (rc=0, no diagnostic) — S4 detection confirmed"
    else
      no "M1-killed: || true mutant did not swallow failure (rc=$_m1rc) — M1 survived (THEATER)"
    fi
  else
    no "M1 setup: mutant not as expected (missing || true or still has PIPESTATUS)"
  fi
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]

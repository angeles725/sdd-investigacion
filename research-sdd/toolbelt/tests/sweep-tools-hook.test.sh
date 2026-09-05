#!/usr/bin/env bash
# sweep-tools-hook.test.sh — red-first harness for sweep-tools-hook.sh.
# Covers: existence, silent-when-clean, surface-when-unrecorded, error-when-failed,
# anti-silent-zero (missing Summary line), PARTIAL WARN passthrough, and mutation proof.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-tools-hook.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== sweep-tools-hook.test.sh =="

# 1. Existence
[ -f "$SUT" ] \
  && ok "1 hook exists at $SUT" \
  || no "1 hook NOT found at $SUT"

# 2. Executable
[ -f "$SUT" ] && [ -x "$SUT" ] \
  && ok "2 hook is executable" \
  || no "2 hook NOT executable (missing +x bit)"

if [ ! -f "$SUT" ]; then
  for n in 3 4 5 6 7; do no "$n (skipped: hook missing)"; done
  echo "== $pass passed · $fail failed =="; exit 1
fi

# ---- Temp workspace ---------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# write_stub <exit_code> <output_text> — creates TMP/sweep-tools.sh + refreshes hook copy.
write_stub() {
  local rc="$1" txt="$2"
  printf '%s\n' "$txt" > "$TMP/stub-out.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit %s\n' "$TMP/stub-out.txt" "$rc" \
    > "$TMP/sweep-tools.sh"
  chmod +x "$TMP/sweep-tools.sh"
  cp "$SUT" "$TMP/sweep-tools-hook.sh"
  chmod +x "$TMP/sweep-tools-hook.sh"
}

# 3. Silent when all tools are ledgered (0 unrecorded).
write_stub 0 "Summary: 5 tool(s) across 3 target(s) · 5 recorded · 0 unrecorded."
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
[ -z "$OUT" ] && [ "$RC" -eq 0 ] \
  && ok "3 all-ledgered (0 unrecorded) → silent, exit 0" \
  || no "3 all-ledgered → expected silence, got exit=$RC out=[$OUT]"

# 4. Emits summary when unrecorded > 0.
write_stub 0 "$(printf 'TARGET  demo\n        tools: 3 found\n        recorded (T-rows): 1  ·  unrecorded: 2  ·  no retro has a tools table\n\nSummary: 3 tool(s) across 1 target(s) · 1 recorded · 2 unrecorded.')"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'unrecorded' \
  && printf '%s\n' "$OUT" | grep -qi 'Summary' \
  && ok "4 unrecorded > 0 → emits summary line" \
  || no "4 unrecorded > 0 → expected summary in output (exit=$RC out=[$OUT])"

# 5. Operational failure (sweep exits non-zero) → error banner, not silence.
write_stub 1 "sweep-tools: cannot find TARGETS.md"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'could not run\|error\|exit 1' \
  && ok "5 sweep failure (rc=1) → error banner emitted" \
  || no "5 sweep failure → expected error banner (exit=$RC out=[$OUT])"

# 6. Anti-silent-zero: sweep exits 0 but emits no Summary line → warning surfaced.
write_stub 0 "TARGET  demo"$'\n'"        no tools directory"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'missing summary\|unexpected' \
  && ok "6 missing Summary line → anti-silent-zero warning emitted" \
  || no "6 missing Summary line → expected warning, got exit=$RC out=[$OUT]"

# 7. PARTIAL WARN passthrough: WARN line from sweep included when unrecorded > 0.
write_stub 0 "$(printf 'Summary: 1 tool(s) across 2 target(s) · 0 recorded · 1 unrecorded.\nWARN: 1 target(s) skipped — truncated path; sweep is PARTIAL: some-target')"
OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -q 'WARN' \
  && ok "7 PARTIAL WARN included when unrecorded > 0" \
  || no "7 PARTIAL WARN → expected WARN in output (exit=$RC out=[$OUT])"

# 8. WARN-line extraction grep error (exit ≥2) must append failure notice; never silently empty warn_line.
#    Stubs grep so any call for '^WARN:' (the extraction call in the hook) exits 2.
_sth_real_grep=/usr/bin/grep
_stub_sth8="$TMP/stub-bin-sth8"; mkdir -p "$_stub_sth8"
cat > "$_stub_sth8/grep" << STUB_STH8
#!/usr/bin/env bash
[ "\$1" = '^WARN:' ] && exit 2
exec "${_sth_real_grep}" "\$@"
STUB_STH8
chmod +x "$_stub_sth8/grep"
write_stub 0 "$(printf 'Summary: 1 tool(s) across 1 target(s) · 0 recorded · 1 unrecorded.')"
OUT_STH8="$(PATH="$_stub_sth8:$PATH" bash "$TMP/sweep-tools-hook.sh" 2>&1)"; RC_STH8=$?
printf '%s\n' "$OUT_STH8" | grep -qiE 'WARN-line extraction failed|grep exit' \
  && ok "8 WARN-line extraction grep exit-2 → failure notice in output" \
  || no "8 WARN-line extraction grep exit-2 not reported (exit=$RC_STH8 out=[$OUT_STH8])"

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: hook must go red when silence is broken --"

  # Tooth A: mutant hook always exits 0 without output (ignores unrecorded count).
  # Test 4 (unrecorded > 0 → emits summary) must catch this and go RED.
  sed 's/\[ "\${unrecorded:-0}" = "0" \] && exit 0/exit 0/' \
    "$SUT" > "$TMP/mutant-hook.sh"
  chmod +x "$TMP/mutant-hook.sh"
  write_stub 0 "$(printf 'Summary: 3 tool(s) across 1 target(s) · 1 recorded · 2 unrecorded.')"
  cp "$TMP/stub-out.txt" "$TMP/stub-out-teeth.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit 0\n' "$TMP/stub-out-teeth.txt" \
    > "$TMP/sweep-tools.sh"
  cp "$TMP/mutant-hook.sh" "$TMP/sweep-tools-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-tools-hook.sh" 2>&1)"
  if [ -z "$MUTANT_OUT" ]; then
    ok "teeth A: always-silent mutant produces no output → test 4 would catch it (RED)"
  else
    no "teeth A: mutant still emits output — mutation did not silence correctly, check mutant"
  fi

  # Tooth B: neutralize _sth_warn_rc so WARN-line extraction error passes silently → test 8 goes red.
  echo "-- teeth B: neutralize _sth_warn_rc; extraction exit-2 must pass silently → test 8 goes red --"
  mutant_sth_b="$TMP/mutant-hook-b.sh"
  sed 's/_sth_warn_rc=\$?/_sth_warn_rc=0/' "$SUT" > "$mutant_sth_b"
  write_stub 0 "$(printf 'Summary: 1 tool(s) across 1 target(s) · 0 recorded · 1 unrecorded.')"
  cp "$TMP/stub-out.txt" "$TMP/stub-out-sth8.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit 0\n' "$TMP/stub-out-sth8.txt" > "$TMP/sweep-tools.sh"
  cp "$mutant_sth_b" "$TMP/sweep-tools-hook.sh"
  out_sth8m="$(PATH="$_stub_sth8:$PATH" bash "$TMP/sweep-tools-hook.sh" 2>&1)"
  printf '%s\n' "$out_sth8m" | grep -qiE 'WARN-line extraction failed|grep exit' \
    && no "teeth B: rc-zeroed mutant still emitted notice — test 8 is THEATER" \
    || ok "teeth B: rc-zeroed mutant passes silently — extraction guard has teeth"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

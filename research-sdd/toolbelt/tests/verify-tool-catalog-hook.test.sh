#!/usr/bin/env bash
# verify-tool-catalog-hook.test.sh — red-first harness for verify-tool-catalog-hook.sh.
# Covers: existence, silent-when-clean, surface-when-drift, error-when-failed,
# anti-silent-zero (missing Summary line), empty-input passthrough, and mutation proof.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-tool-catalog-hook.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== verify-tool-catalog-hook.test.sh =="

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

# write_stub <exit_code> <output_text> — creates TMP/verify-tool-catalog.sh + refreshes hook copy.
write_stub() {
  local rc="$1" txt="$2"
  printf '%s\n' "$txt" > "$TMP/stub-out.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit %s\n' "$TMP/stub-out.txt" "$rc" \
    > "$TMP/verify-tool-catalog.sh"
  chmod +x "$TMP/verify-tool-catalog.sh"
  cp "$SUT" "$TMP/verify-tool-catalog-hook.sh"
  chmod +x "$TMP/verify-tool-catalog-hook.sh"
}

# 3. Silent when every logged tool is cataloged (0 not cataloged).
write_stub 0 "Summary: 5 distinct tool(s) logged in INSTALLED-TOOLS.md · 5 cataloged · 0 not cataloged."
OUT="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; RC=$?
[ -z "$OUT" ] && [ "$RC" -eq 0 ] \
  && ok "3 all-cataloged (0 not cataloged) → silent, exit 0" \
  || no "3 all-cataloged → expected silence, got exit=$RC out=[$OUT]"

# 4. Emits drift when not-cataloged > 0.
write_stub 0 "$(printf 'WARN  installed-but-not-cataloged: '\''typst'\'' is logged...\n\nSummary: 3 distinct tool(s) logged in INSTALLED-TOOLS.md · 2 cataloged · 1 not cataloged.')"
OUT="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'not cataloged' \
  && printf '%s\n' "$OUT" | grep -qi 'Summary' \
  && ok "4 not-cataloged > 0 → emits drift summary" \
  || no "4 not-cataloged > 0 → expected drift summary (exit=$RC out=[$OUT])"

# 5. Operational failure (guard exits non-zero) → error banner, not silence.
write_stub 1 "verify-tool-catalog: ERROR — cannot find INSTALLED-TOOLS.md (absent-input)"
OUT="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'could not run\|error\|exit 1' \
  && ok "5 guard failure (rc=1) → error banner emitted" \
  || no "5 guard failure → expected error banner (exit=$RC out=[$OUT])"

# 6. Anti-silent-zero: guard exits 0 but emits no Summary AND no empty-input sentence → warning.
write_stub 0 "some unexpected garbage with no Summary line"
OUT="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'missing summary\|unexpected' \
  && ok "6 missing Summary line (not empty-input) → anti-silent-zero warning emitted" \
  || no "6 missing Summary line → expected warning, got exit=$RC out=[$OUT]"

# 7. Empty-input passthrough: guard's explicit empty-input sentence → silent, not surfaced as an error.
write_stub 0 "verify-tool-catalog: INSTALLED-TOOLS.md has no tool log rows (empty-input) — nothing to reconcile."
OUT="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; RC=$?
[ -z "$OUT" ] && [ "$RC" -eq 0 ] \
  && ok "7 empty-input sentence → silent (legitimate, not an anomaly), exit 0" \
  || no "7 empty-input → expected silence, got exit=$RC out=[$OUT]"

# 8. WARN-line extraction grep error (exit ≥2) must append failure notice; never silently empty warn_lines.
#    Stubs grep so any call for '^WARN' (the extraction call in the hook) exits 2.
_vtch_real_grep=/usr/bin/grep
_stub_vtch8="$TMP/stub-bin-vtch8"; mkdir -p "$_stub_vtch8"
cat > "$_stub_vtch8/grep" << STUB_VTCH8
#!/usr/bin/env bash
[ "\$1" = '^WARN' ] && exit 2
exec "${_vtch_real_grep}" "\$@"
STUB_VTCH8
chmod +x "$_stub_vtch8/grep"
write_stub 0 "$(printf 'Summary: 1 distinct tool(s) logged in INSTALLED-TOOLS.md · 0 cataloged · 1 not cataloged.')"
OUT_VTCH8="$(PATH="$_stub_vtch8:$PATH" bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; RC_VTCH8=$?
printf '%s\n' "$OUT_VTCH8" | grep -qiE 'WARN-line extraction failed|grep exit' \
  && ok "8 WARN-line extraction grep exit-2 → failure notice in output" \
  || no "8 WARN-line extraction grep exit-2 not reported (exit=$RC_VTCH8 out=[$OUT_VTCH8])"

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: hook must go red when silence is broken --"

  # Tooth A: mutant hook always exits 0 without output (ignores not-cataloged count).
  # Test 4 (not-cataloged > 0 → emits drift summary) must catch this and go RED.
  sed 's/\[ "\${missing:-0}" = "0" \] && exit 0/exit 0/' \
    "$SUT" > "$TMP/mutant-hook.sh"
  chmod +x "$TMP/mutant-hook.sh"
  write_stub 0 "$(printf 'Summary: 3 distinct tool(s) logged in INSTALLED-TOOLS.md · 2 cataloged · 1 not cataloged.')"
  cp "$TMP/stub-out.txt" "$TMP/stub-out-teeth.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit 0\n' "$TMP/stub-out-teeth.txt" \
    > "$TMP/verify-tool-catalog.sh"
  cp "$TMP/mutant-hook.sh" "$TMP/verify-tool-catalog-hook.sh"
  MUTANT_OUT="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"
  if [ -z "$MUTANT_OUT" ]; then
    ok "teeth A: always-silent mutant produces no output → test 4 would catch it (RED)"
  else
    no "teeth A: mutant still emits output — mutation did not silence correctly, check mutant"
  fi

  # Tooth B: neutralize _vtch_warn_rc so WARN-line extraction error passes silently → test 8 goes red.
  echo "-- teeth B: neutralize _vtch_warn_rc; extraction exit-2 must pass silently → test 8 goes red --"
  mutant_vtch_b="$TMP/mutant-hook-vtch-b.sh"
  sed 's/_vtch_warn_rc=\$?/_vtch_warn_rc=0/' "$SUT" > "$mutant_vtch_b"
  write_stub 0 "$(printf 'Summary: 1 distinct tool(s) logged in INSTALLED-TOOLS.md · 0 cataloged · 1 not cataloged.')"
  cp "$TMP/stub-out.txt" "$TMP/stub-out-vtch8.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit 0\n' "$TMP/stub-out-vtch8.txt" \
    > "$TMP/verify-tool-catalog.sh"
  cp "$mutant_vtch_b" "$TMP/verify-tool-catalog-hook.sh"
  out_vtch8m="$(PATH="$_stub_vtch8:$PATH" bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"
  printf '%s\n' "$out_vtch8m" | grep -qiE 'WARN-line extraction failed|grep exit' \
    && no "teeth B: rc-zeroed mutant still emitted notice — test 8 is THEATER" \
    || ok "teeth B: rc-zeroed mutant passes silently — extraction guard has teeth"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

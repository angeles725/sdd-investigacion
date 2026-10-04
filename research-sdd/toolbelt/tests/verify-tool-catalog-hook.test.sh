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

# 3. Declared-clean sentinel when every logged tool is cataloged (0 not cataloged).
#    A silent clean run is the defect (#380 precedent) — sentinel MUST be emitted.
write_stub 0 "Summary: 5 distinct tool(s) logged in INSTALLED-TOOLS.md · 5 cataloged · 0 not cataloged."
OUT="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -q 'Research-SDD tool catalog: clean (5 logged tools, 0 uncataloged).' \
  && ok "3 all-cataloged (0 not cataloged) → declared-clean sentinel emitted" \
  || no "3 all-cataloged → expected clean sentinel, got exit=$RC out=[$OUT]"

# 4. Emits drift when not-cataloged > 0.
write_stub 0 "$(printf 'WARN  installed-but-not-cataloged: '\''typst'\'' is logged...\n\nSummary: 3 distinct tool(s) logged in INSTALLED-TOOLS.md · 2 cataloged · 1 not cataloged.')"
OUT="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -qi 'not cataloged' \
  && <<<"$OUT" grep -qi 'Summary' \
  && ok "4 not-cataloged > 0 → emits drift summary" \
  || no "4 not-cataloged > 0 → expected drift summary (exit=$RC out=[$OUT])"

# 5. Operational failure (guard exits non-zero) → error banner, not silence.
write_stub 1 "verify-tool-catalog: ERROR — cannot find INSTALLED-TOOLS.md (absent-input)"
OUT="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -qi 'could not run\|error\|exit 1' \
  && ok "5 guard failure (rc=1) → error banner emitted" \
  || no "5 guard failure → expected error banner (exit=$RC out=[$OUT])"

# 6. Anti-silent-zero: guard exits 0 but emits no Summary AND no empty-input sentence → warning.
write_stub 0 "some unexpected garbage with no Summary line"
OUT="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -qi 'missing summary\|unexpected' \
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
<<<"$OUT_VTCH8" grep -qiE 'WARN-line extraction failed|grep exit' \
  && ok "8 WARN-line extraction grep exit-2 → failure notice in output" \
  || no "8 WARN-line extraction grep exit-2 not reported (exit=$RC_VTCH8 out=[$OUT_VTCH8])"

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # Mutants are built by lib/mutant.sh (kit #1299), sourced ONLY on this path. It refuses an empty,
  # byte-identical, syntax-broken or live-tree mutant; mutant_chain also refuses a sed stage that matches
  # nothing. A refused build is counted exactly once (mk_mut) and its tooth is skipped.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  declare -F mutant_chain >/dev/null || { echo "FATAL: lib/mutant.sh did not define mutant_chain" >&2; exit 2; }
  mk_mut(){ rm -f -- "$3"; mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  echo "-- teeth: hook must go red when silence is broken --"

  # Each tooth resets the hook copy (rm here, write_stub restores the pristine SUT) and is skipped when its
  # mutant build is refused (already counted once by mk_mut), so a previous tooth's mutant can never run in its place.

  # Tooth A: mutant hook always exits 0 without output (ignores not-cataloged count).
  # Test 4 (not-cataloged > 0 → emits drift summary) must catch this and go RED.
  # Mutant: insert unconditional exit 0 right after the missing= parse line — hook exits
  # silently regardless of the not-cataloged count, so drift goes unreported.
  rm -f "$TMP/verify-tool-catalog-hook.sh"
  if mk_mut "teeth A: always-silent" "$SUT" "$TMP/mutant-hook.sh" '/missing.*not cataloged/a\  exit 0'; then
    chmod +x "$TMP/mutant-hook.sh"
    write_stub 0 "$(printf 'Summary: 3 distinct tool(s) logged in INSTALLED-TOOLS.md · 2 cataloged · 1 not cataloged.')"
    cp "$TMP/stub-out.txt" "$TMP/stub-out-teeth.txt"
    printf '#!/usr/bin/env bash\ncat "%s"\nexit 0\n' "$TMP/stub-out-teeth.txt" \
      > "$TMP/verify-tool-catalog.sh"
    cp "$TMP/mutant-hook.sh" "$TMP/verify-tool-catalog-hook.sh"
    MUTANT_OUT="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; MRC=$?
    if [ "$MRC" = 0 ] && [ -z "$MUTANT_OUT" ]; then
      ok "teeth A: always-silent mutant produces no output → test 4 would catch it (RED)"
    else
      no "teeth A: mutant rc=$MRC out=[$MUTANT_OUT] — want rc 0 and no output (mutation did not silence correctly, or crashed)"
    fi
  fi

  # Tooth C: mutant makes the clean state silent (reverts to old exit-0 idiom) → test 3 goes RED.
  # Mutant: replace sentinel emission with bare exit 0 (no jq call, no output).
  echo "-- teeth C: clean-silent mutant → test 3 (declared-clean sentinel) must catch it --"
  rm -f "$TMP/verify-tool-catalog-hook.sh"
  if mk_mut "teeth C: clean-silent" "$SUT" "$TMP/mutant-hook-c.sh" '/CLEAN-SENTINEL/c\  exit 0'; then
    chmod +x "$TMP/mutant-hook-c.sh"
    write_stub 0 "$(printf 'Summary: 5 distinct tool(s) logged in INSTALLED-TOOLS.md · 5 cataloged · 0 not cataloged.')"
    cp "$TMP/mutant-hook-c.sh" "$TMP/verify-tool-catalog-hook.sh"
    MUTANT_OUT_C="$(bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; MRC_C=$?
    if [ "$MRC_C" = 0 ] && ! <<<"$MUTANT_OUT_C" grep -q 'Research-SDD tool catalog: clean'; then
      ok "teeth C: clean-silent mutant omits sentinel → test 3 would catch it (RED)"
    else
      no "teeth C: mutant rc=$MRC_C out=[$MUTANT_OUT_C] — want rc 0 and no clean sentinel (a crash is no bite)"
    fi
  fi

  # Tooth B: neutralize _vtch_warn_rc so WARN-line extraction error passes silently → test 8 goes red.
  echo "-- teeth B: neutralize _vtch_warn_rc; extraction exit-2 must pass silently → test 8 goes red --"
  rm -f "$TMP/verify-tool-catalog-hook.sh"
  mutant_vtch_b="$TMP/mutant-hook-vtch-b.sh"
  if mk_mut "teeth B: rc-zeroed" "$SUT" "$mutant_vtch_b" 's/_vtch_warn_rc=\$?/_vtch_warn_rc=0/'; then
    write_stub 0 "$(printf 'Summary: 1 distinct tool(s) logged in INSTALLED-TOOLS.md · 0 cataloged · 1 not cataloged.')"
    cp "$TMP/stub-out.txt" "$TMP/stub-out-vtch8.txt"
    printf '#!/usr/bin/env bash\ncat "%s"\nexit 0\n' "$TMP/stub-out-vtch8.txt" \
      > "$TMP/verify-tool-catalog.sh"
    cp "$mutant_vtch_b" "$TMP/verify-tool-catalog-hook.sh"
    out_vtch8m="$(PATH="$_stub_vtch8:$PATH" bash "$TMP/verify-tool-catalog-hook.sh" 2>&1)"; MRC_B=$?
    # The mutant still prints the Summary-derived notice; only the extraction-failure notice must vanish, and it must not crash.
    if [ "$MRC_B" = 0 ] && ! <<<"$out_vtch8m" grep -qiE 'WARN-line extraction failed|grep exit|syntax error|command not found'; then
      ok "teeth B: rc-zeroed mutant passes silently — extraction guard has teeth"
    else
      no "teeth B: mutant rc=$MRC_B out=[$out_vtch8m] — want rc 0 and no extraction-failure notice (still emitted, or crashed)"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

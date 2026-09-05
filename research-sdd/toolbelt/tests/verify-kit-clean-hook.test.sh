#!/usr/bin/env bash
# verify-kit-clean-hook.test.sh — red-first harness for verify-kit-clean-hook.sh.
# Covers: existence, executable, clean-kit → silent, dirty-kit → banner, rc=2 → error banner,
# plus mutation proof.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-kit-clean-hook.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== verify-kit-clean-hook.test.sh =="

# 1. Existence
[ -f "$SUT" ] \
  && ok "1 hook exists at $SUT" \
  || no "1 hook NOT found at $SUT"

# 2. Executable
[ -f "$SUT" ] && [ -x "$SUT" ] \
  && ok "2 hook is executable" \
  || no "2 hook NOT executable (missing +x bit)"

if [ ! -f "$SUT" ]; then
  for n in 3 4 5; do no "$n (skipped: hook missing)"; done
  echo "== $pass passed · $fail failed =="; exit 2
fi

# ---- Temp workspace ---------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# write_stub <exit_code> <output_text> — creates a stub verify-kit-clean.sh + refreshes hook copy.
write_stub() {
  local rc="$1" txt="$2"
  printf '%s\n' "$txt" > "$TMP/stub-out.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit %s\n' "$TMP/stub-out.txt" "$rc" \
    > "$TMP/verify-kit-clean.sh"
  chmod +x "$TMP/verify-kit-clean.sh"
  cp "$SUT" "$TMP/verify-kit-clean-hook.sh"
  # Patch the copy to call the stub instead of the real verify-kit-clean.sh.
  sed "s|here/verify-kit-clean.sh|here/verify-kit-clean.sh\nhere=\"$TMP\"|" \
    "$SUT" > "$TMP/verify-kit-clean-hook.sh" 2>/dev/null || cp "$SUT" "$TMP/verify-kit-clean-hook.sh"
  # Simpler: just override via PATH — place stub first.
  mkdir -p "$TMP/bin"
  cp "$TMP/verify-kit-clean.sh" "$TMP/bin/verify-kit-clean.sh"
  chmod +x "$TMP/bin/verify-kit-clean.sh"
  chmod +x "$TMP/verify-kit-clean-hook.sh"
}

# Helper: run hook from TMP/bin with stub on PATH.
run_hook_with_stub() {
  local stub_rc="$1" stub_out="$2"
  printf '%s\n' "$stub_out" > "$TMP/stub-out.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit %s\n' "$TMP/stub-out.txt" "$stub_rc" \
    > "$TMP/verify-kit-clean.sh"
  chmod +x "$TMP/verify-kit-clean.sh"
  # The hook calls: "$here/verify-kit-clean.sh" — we cannot override that path directly.
  # Use a hook copy that uses a stub by rewriting the inner call.
  sed "s|\"\$here/verify-kit-clean.sh\"|\"$TMP/verify-kit-clean.sh\"|g" \
    "$SUT" > "$TMP/hook-under-test.sh"
  chmod +x "$TMP/hook-under-test.sh"
  bash "$TMP/hook-under-test.sh" 2>&1
}

# 3. Clean kit (rc=0) → hook exits 0 and emits nothing (silent).
OUT="$(run_hook_with_stub 0 "== verify-kit-clean: kit (branch: main) ==
   working tree : CLEAN
   verdict      : clean — safe to stage a retro / start clean kit work
== exit 0 ==")"
RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] \
  && ok "3 clean kit (rc=0) → hook silent (exit 0, no output)" \
  || no "3 clean kit → expected exit 0 + no output (exit=$RC out=[$OUT])"

# 4. Dirty kit (rc=1) → hook emits banner containing "NOT clean".
OUT="$(run_hook_with_stub 1 "== verify-kit-clean: kit (branch: main) ==
   working tree : DIRTY — uncommitted: 0 staged · 2 unstaged · 5 untracked
   verdict      : NOT clean — commit/stash + push before staging a retro (else mixed history)
== exit 1 ==")"
printf '%s\n' "$OUT" | grep -qi 'NOT clean\|commit/stash\|not clean' \
  && ok "4 dirty kit (rc=1) → banner containing 'NOT clean' emitted" \
  || no "4 dirty kit → expected 'NOT clean' banner (out=[$OUT])"

# 5. Gate-error (rc=2) → hook emits error banner containing "could not run" or similar.
OUT="$(run_hook_with_stub 2 "verify-kit-clean: not a git repo: /bad/path")"
printf '%s\n' "$OUT" | grep -qi 'could not run\|exit 2\|misconfigured' \
  && ok "5 gate error (rc=2) → error banner emitted" \
  || no "5 gate error → expected error banner (out=[$OUT])"

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neutered rc-check must lose the dirty banner (test 4 goes RED) --"

  # Tooth A: rc-check neutered (always takes clean path) → dirty banner disappears → test 4 would fail.
  sed 's/rc=\$?/rc=0/' "$SUT" > "$TMP/mutant-hook.sh" 2>/dev/null \
    || cp "$SUT" "$TMP/mutant-hook.sh"
  sed -i "s|\"\$here/verify-kit-clean.sh\"|\"$TMP/verify-kit-clean.sh\"|g" "$TMP/mutant-hook.sh"
  chmod +x "$TMP/mutant-hook.sh"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit 1\n' "$TMP/stub-out.txt" > "$TMP/verify-kit-clean.sh"
  printf '%s\n' "   working tree : DIRTY — uncommitted: 0 staged · 2 unstaged · 5 untracked
   verdict      : NOT clean" > "$TMP/stub-out.txt"
  chmod +x "$TMP/verify-kit-clean.sh"
  MUTANT_OUT="$(bash "$TMP/mutant-hook.sh" 2>&1)"
  if ! printf '%s\n' "$MUTANT_OUT" | grep -qi 'NOT clean\|not clean'; then
    ok "teeth A: rc-neutered mutant silences dirty banner → test 4 would catch it (RED)"
  else
    no "teeth A: mutant still emits dirty banner — tooth has no bite (sed pattern may not match)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

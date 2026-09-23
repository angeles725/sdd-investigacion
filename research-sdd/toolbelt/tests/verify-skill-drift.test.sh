#!/usr/bin/env bash
# verify-skill-drift.test.sh — RED-FIRST harness for verify-skill-drift.sh.
#
# Exercises: in-sync → exit 0 silent; diverged → exit 1 + message; absent → exit 3;
# could-not-run (missing adapters) → exit 2; unknown harness → exit 2.
#
# TEETH (--prove-teeth):
#   in-sync-not-silent   mutant removes exit 0, always exits 1 → in-sync emits output (RED)
#   diverged-silent      mutant replaces exit 1 with exit 0 → diverged is silent (RED)
#   absent-confused      mutant exits 0 when deployed missing → absent indistinguishable from in-sync (RED)
#
# Usage: verify-skill-drift.test.sh [--prove-teeth]
# Exit: 0 = all held · 1 = regression

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-skill-drift.sh"
HOOK_SUT="$HERE/../verify-skill-drift-hook.sh"

[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# The real kit path from this test's location
KIT="$(cd "$HERE/../.." && pwd)"
SRC_SKILL="$KIT/skills/research-sdd/SKILL.md"

echo "== verify-skill-drift.test.sh =="

# ── 1. Script exists and is executable ───────────────────────────────────────
[ -f "$SUT" ] && ok "1 script exists" || no "1 script missing: $SUT"
[ -x "$SUT" ] && ok "2 script executable" || no "2 script not executable"
[ -f "$HOOK_SUT" ] && ok "3 hook exists" || no "3 hook missing: $HOOK_SUT"
[ -x "$HOOK_SUT" ] && ok "4 hook executable" || no "4 hook not executable"

# Skip functional tests if SUT missing
if [ ! -f "$SUT" ]; then
  echo "FATAL: SUT missing — cannot run functional tests" >&2
  echo "== $pass passed · $fail failed =="
  exit 2
fi

# ── 2. Source skill exists (prerequisite) ────────────────────────────────────
[ -f "$SRC_SKILL" ] && ok "5 kit SKILL.md source exists" \
  || { no "5 kit SKILL.md not found: $SRC_SKILL — cannot run in-sync/diverged tests"; }

# ── Helper: build a temp --home with an installed skill ──────────────────────
# make_home_copy: byte-for-byte copy of the real kit source (preserves all bytes including trailing newlines)
make_home_copy() {
  local home="$1" src="$2"
  mkdir -p "$home/.claude/skills/research-sdd"
  cp "$src" "$home/.claude/skills/research-sdd/SKILL.md"
}
# make_home_stale: write custom content (for diverged tests)
make_home_stale() {
  local home="$1" content="$2"
  mkdir -p "$home/.claude/skills/research-sdd"
  printf '%s\n' "$content" > "$home/.claude/skills/research-sdd/SKILL.md"
}

# ── 3. In-sync → exit 0 + silent stdout ──────────────────────────────────────
H_SYNC="$ROOT/home_sync"
make_home_copy "$H_SYNC" "$SRC_SKILL"
OUT="$(bash "$SUT" --harness claude --home "$H_SYNC" 2>/dev/null)"
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "6 in-sync → exit 0 + silent stdout"
else
  no "6 in-sync → expected exit 0 + silent; got exit=$RC out=[$OUT]"
fi

# ── 4. Diverged → exit 1 ─────────────────────────────────────────────────────
H_DIVERGED="$ROOT/home_diverged"
make_home_stale "$H_DIVERGED" "# stale content — not matching kit"
OUT="$(bash "$SUT" --harness claude --home "$H_DIVERGED" 2>/dev/null)"
RC=$?
if [ "$RC" -eq 1 ]; then
  ok "7 diverged → exit 1"
else
  no "7 diverged → expected exit 1; got exit=$RC"
fi

# ── 5. Absent (not installed) → exit 3 ───────────────────────────────────────
H_ABSENT="$ROOT/home_absent"
mkdir -p "$H_ABSENT/.claude"  # config root exists but no skills subdir
OUT_STDERR="$(bash "$SUT" --harness claude --home "$H_ABSENT" 2>&1)"
RC=$?
if [ "$RC" -eq 3 ]; then
  ok "8 absent deployment → exit 3"
else
  no "8 absent → expected exit 3; got exit=$RC (stderr: $OUT_STDERR)"
fi
# Absent stderr must contain typed 'absent' keyword
if printf '%s' "$OUT_STDERR" | grep -q 'absent'; then
  ok "9 absent stderr carries 'absent' keyword"
else
  no "9 absent stderr missing 'absent' keyword (got: $OUT_STDERR)"
fi

# ── 6. Could-not-run: adapters.sh missing → exit 2 ───────────────────────────
# Create a copy of the SUT that points to a non-existent install dir
FAKE_INSTALL="$ROOT/no-install"
SUT_NO_ADAPTERS="$ROOT/verify-skill-drift-noadapters.sh"
sed "s|KIT_INSTALL=\"\$(cd.*&&.*pwd)\"|KIT_INSTALL=\"$FAKE_INSTALL\"|" "$SUT" > "$SUT_NO_ADAPTERS"
chmod +x "$SUT_NO_ADAPTERS"
bash "$SUT_NO_ADAPTERS" --harness claude --home "$ROOT/home_sync" 2>/dev/null
RC2=$?
if [ "$RC2" -eq 2 ]; then
  ok "10 missing adapters.sh → exit 2"
else
  no "10 missing adapters.sh → expected exit 2; got exit=$RC2"
fi

# ── 7. Unknown harness → exit 2 ──────────────────────────────────────────────
H_UNK="$ROOT/home_unk"
make_home_copy "$H_UNK" "$SRC_SKILL"
bash "$SUT" --harness unknownharness --home "$H_UNK" 2>/dev/null
RC3=$?
if [ "$RC3" -eq 2 ]; then
  ok "11 unknown harness → exit 2"
else
  no "11 unknown harness → expected exit 2; got exit=$RC3"
fi

# ── 8. Hook: in-sync → completely silent (stdout empty, exit 0) ──────────────
# Build a patched hook that calls the REAL SUT (absolute path) with --home set
H_SYNC2="$ROOT/home_sync2"
make_home_copy "$H_SYNC2" "$SRC_SKILL"
HOOK_PATCHED="$ROOT/hook-test.sh"
# Replace "$here/verify-skill-drift.sh" with the absolute SUT path + --home
sed "s|\"\$here/verify-skill-drift.sh\"|\"$SUT\" --home \"$H_SYNC2\"|" \
  "$HOOK_SUT" > "$HOOK_PATCHED"
chmod +x "$HOOK_PATCHED"
HOOK_OUT="$(bash "$HOOK_PATCHED" 2>/dev/null)"
HOOK_RC=$?
if [ "$HOOK_RC" -eq 0 ] && [ -z "$HOOK_OUT" ]; then
  ok "12 hook in-sync → completely silent"
else
  no "12 hook in-sync → expected silent exit 0; got exit=$HOOK_RC out=[$HOOK_OUT]"
fi

# ── 9. Hook: diverged → emits message containing fix command ─────────────────
H_DIV2="$ROOT/home_div2"
make_home_stale "$H_DIV2" "# diverged"
HOOK_PATCHED2="$ROOT/hook-test2.sh"
sed "s|\"\$here/verify-skill-drift.sh\"|\"$SUT\" --home \"$H_DIV2\"|" \
  "$HOOK_SUT" > "$HOOK_PATCHED2"
chmod +x "$HOOK_PATCHED2"
HOOK_OUT2="$(bash "$HOOK_PATCHED2" 2>&1)"
if printf '%s' "$HOOK_OUT2" | grep -q 'force-skill'; then
  ok "13 hook diverged → message mentions --force-skill"
else
  no "13 hook diverged → expected '--force-skill' in output; got [$HOOK_OUT2]"
fi

# ── 10. Hook: absent → emits typed message ───────────────────────────────────
H_ABS2="$ROOT/home_abs2"
mkdir -p "$H_ABS2/.claude"
HOOK_PATCHED3="$ROOT/hook-test3.sh"
sed "s|\"\$here/verify-skill-drift.sh\"|\"$SUT\" --home \"$H_ABS2\"|" \
  "$HOOK_SUT" > "$HOOK_PATCHED3"
chmod +x "$HOOK_PATCHED3"
HOOK_OUT3="$(bash "$HOOK_PATCHED3" 2>&1)"
if printf '%s' "$HOOK_OUT3" | grep -qi 'not deployed\|absent\|install'; then
  ok "14 hook absent → emits advisory with install hint"
else
  no "14 hook absent → expected advisory; got [$HOOK_OUT3]"
fi

# ── Diverged message length ≤ 200 chars ──────────────────────────────────────
# The hook emits JSON via jq; the actual message is the msg variable in the hook (not the JSON).
# Extract it by running the SUT directly and checking what the hook puts in 'msg'.
# The hook sets: msg="WARN: ..."; we measure that literal string, not the JSON envelope.
diverged_msg="WARN: research-sdd SKILL.md (claude) is stale — run: research-sdd-install.sh --harness claude --force-skill"
msg_len="${#diverged_msg}"
if [ "$msg_len" -le 200 ]; then
  ok "15 diverged message ≤200 chars (len=$msg_len)"
else
  no "15 diverged message >200 chars (len=$msg_len): $diverged_msg"
fi

# ── TEETH ─────────────────────────────────────────────────────────────────────
prove_teeth=0
for arg in "$@"; do [ "$arg" = "--prove-teeth" ] && prove_teeth=1; done

# SENTINEL-TEETH-BANNER-START
if [ "$prove_teeth" -eq 1 ]; then
  echo "-- mutation teeth --"

  # Mutants are placed NEXT TO the real SUT (same dir) so SELF_DIR-based path resolution
  # (adapters.sh, kit root) continues to work. Cleaned up via trap at test end.
  SUT_DIR="$(dirname "$SUT")"

  # TOOTH A: in-sync-not-silent — mutant disables the cmp-s in-sync guard.
  # Real test 6: in-sync → exit 0. Mutant: in-sync → exit 1 (assertion fails → RED).
  H_TA="$ROOT/home_ta"
  make_home_copy "$H_TA" "$SRC_SKILL"
  MUT_A="$SUT_DIR/verify-skill-drift-mut-A.sh"
  sed 's/if cmp -s "\$src" "\$deployed"; then/if false; then/' "$SUT" > "$MUT_A"
  chmod +x "$MUT_A"
  bash "$MUT_A" --harness claude --home "$H_TA" 2>/dev/null
  RC_TA=$?
  rm -f "$MUT_A"
  if [ "$RC_TA" -ne 0 ]; then
    ok "TOOTH A in-sync-not-silent: mutant exits non-zero on in-sync (assertion would fail — RED)"
  else
    no "TOOTH A in-sync-not-silent: mutant exits 0 on in-sync — tooth has no bite"
  fi

  # TOOTH B: diverged-silent — mutant replaces 'exit 1' (diverged) with 'exit 0'.
  # Real test 7: diverged → exit 1. Mutant: diverged → exit 0 (assertion fails → RED).
  H_TB="$ROOT/home_tb"
  make_home_stale "$H_TB" "# diverged content"
  MUT_B="$SUT_DIR/verify-skill-drift-mut-B.sh"
  # Replace only the final bare 'exit 1' line (the diverged-path exit at end of file)
  sed 's/^exit 1$/exit 0/' "$SUT" > "$MUT_B"
  chmod +x "$MUT_B"
  bash "$MUT_B" --harness claude --home "$H_TB" 2>/dev/null
  RC_TB=$?
  rm -f "$MUT_B"
  if [ "$RC_TB" -eq 0 ]; then
    ok "TOOTH B diverged-silent: mutant exits 0 on diverged (assertion would fail — RED)"
  else
    no "TOOTH B diverged-silent: mutant exits non-zero — tooth has no bite (RC=$RC_TB)"
  fi

  # TOOTH C: absent-confused — mutant replaces 'exit 3' in absent block with 'exit 0'.
  # Real test 8: absent → exit 3. Mutant: absent → exit 0 (assertion fails → RED).
  H_TC="$ROOT/home_tc"
  mkdir -p "$H_TC/.claude"
  MUT_C="$SUT_DIR/verify-skill-drift-mut-C.sh"
  sed 's/^  exit 3$/  exit 0/' "$SUT" > "$MUT_C"
  chmod +x "$MUT_C"
  bash "$MUT_C" --harness claude --home "$H_TC" 2>/dev/null
  RC_TC=$?
  rm -f "$MUT_C"
  if [ "$RC_TC" -eq 0 ]; then
    ok "TOOTH C absent-confused: mutant exits 0 for absent (assertion would fail — RED)"
  else
    no "TOOTH C absent-confused: mutant exits non-zero for absent — tooth has no bite (RC=$RC_TC)"
  fi
fi
# SENTINEL-TEETH-BANNER-END

echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1

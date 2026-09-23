#!/usr/bin/env bash
# verify-skill-drift.test.sh — RED-FIRST harness for verify-skill-drift.sh.
#
# Exercises: in-sync → exit 0 silent; diverged → exit 1 + message; absent → exit 3;
# could-not-run (missing adapters) → exit 2; unknown harness → exit 2.
#
# TEETH (--prove-teeth):
#   A  in-sync-not-silent    mutant disables cmp-s guard → in-sync exits 1 (RED)
#   B  diverged-silent       mutant replaces exit 1 → diverged exits 0 (RED)
#   C  absent-confused       mutant exits 0 for absent → absent indistinguishable from in-sync (RED)
#   D  all-last-skipped      mutant skips last harness in loop → diverged at last is missed (RED)
# Mutants live in $ROOT/toolbelt/ (never the live tree); verified by git-status before/after.
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

# ── 11b/c. Missing value for --harness / --home → exit 2 immediately (no hang) ─
# Both flags require a non-empty value; a missing value previously caused an
# infinite loop (shift 2 with $#=1 returns 1 without advancing → while $#>0 hangs).
timeout 5 bash "$SUT" --harness 2>/dev/null; RC_5B=$?
if [ "$RC_5B" -eq 2 ]; then
  ok "11b --harness without value → exit 2 (no hang)"
else
  no "11b --harness without value → expected exit 2; got $RC_5B (124=timeout=hang)"
fi
timeout 5 bash "$SUT" --home 2>/dev/null; RC_5C=$?
if [ "$RC_5C" -eq 2 ]; then
  ok "11c --home without value → exit 2 (no hang)"
else
  no "11c --home without value → expected exit 2; got $RC_5C (124=timeout=hang)"
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

# ── 10. Hook: single claude absent → silent (hook uses --all; absent is normal) ─
# The hook now checks all harnesses via --all; an absent harness is normal and not surfaced.
H_ABS2_SINGLE="$ROOT/home_abs2_single"
mkdir -p "$H_ABS2_SINGLE"  # no harness dirs at all
HOOK_PATCHED3_SINGLE="$ROOT/hook-test3-single.sh"
sed 's|"$here/verify-skill-drift.sh" --all|"'"$SUT"'" --all --home "'"$H_ABS2_SINGLE"'"|' \
  "$HOOK_SUT" > "$HOOK_PATCHED3_SINGLE"
chmod +x "$HOOK_PATCHED3_SINGLE"
HOOK_OUT3_SINGLE="$(bash "$HOOK_PATCHED3_SINGLE" 2>&1)"
HOOK_RC3_SINGLE=$?
if [ "$HOOK_RC3_SINGLE" -eq 0 ] && [ -z "$HOOK_OUT3_SINGLE" ]; then
  ok "14 hook absent → completely silent (absent is normal under --all)"
else
  no "14 hook absent → expected silent exit 0; got exit=$HOOK_RC3_SINGLE out=[$HOOK_OUT3_SINGLE]"
fi

# ── 15/15b. Hook output line lengths ≤ 200 chars (measured from real hook run) ──
# Uses HOOK_OUT2 (diverged home → hook emits real WARN header + per-harness fix line).
# When jq is present the hook emits JSON; extract additionalContext to get the plain lines.
# Checking real output catches a regression in the message text; a hardcoded literal never changes.
if command -v jq >/dev/null 2>&1; then
  _hook_text="$(printf '%s' "$HOOK_OUT2" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
else
  _hook_text="$HOOK_OUT2"
fi
_actual_header="$(printf '%s' "$_hook_text" | head -1)"
_actual_header_len="${#_actual_header}"
if [ "$_actual_header_len" -gt 0 ] && [ "$_actual_header_len" -le 200 ]; then
  ok "15 hook WARN header ≤200 chars in real output (len=$_actual_header_len)"
elif [ "$_actual_header_len" -eq 0 ]; then
  no "15 hook WARN header — header line empty (hook did not emit on diverged?)"
else
  no "15 hook WARN header >200 chars (len=$_actual_header_len): $_actual_header"
fi
_actual_fix="$(printf '%s' "$_hook_text" | grep 'force-skill' | head -1)"
_actual_fix_len="${#_actual_fix}"
if [ "$_actual_fix_len" -gt 0 ] && [ "$_actual_fix_len" -le 200 ]; then
  ok "15b per-harness fix line ≤200 chars in real output (len=$_actual_fix_len)"
elif [ "$_actual_fix_len" -eq 0 ]; then
  no "15b per-harness fix line — no force-skill line in hook output (unexpected)"
else
  no "15b per-harness fix line >200 chars (len=$_actual_fix_len): $_actual_fix"
fi

# ── --all mode: iterate every registered harness ─────────────────────────────
# Setup for --all tests:
#   H_ALL: claude in-sync, opencode absent, codex absent, reasonix diverged (LAST)
#   — tests the list-edge rule: drift in the last harness in RESEARCH_SDD_HARNESSES order
H_ALL="$ROOT/home_all"
mkdir -p "$H_ALL/.claude/skills/research-sdd"
cp "$SRC_SKILL" "$H_ALL/.claude/skills/research-sdd/SKILL.md"      # claude: in-sync
mkdir -p "$H_ALL/.reasonix/skills/research-sdd"
printf 'stale content — not matching kit\n' > "$H_ALL/.reasonix/skills/research-sdd/SKILL.md"  # reasonix: diverged
# opencode (.config/opencode) and codex (.codex) not created → absent

# AN1: --all with last harness diverged → exit 1
bash "$SUT" --all --home "$H_ALL" 2>/dev/null
RC_AN1=$?
if [ "$RC_AN1" -eq 1 ]; then
  ok "AN1 --all last-harness-diverged → exit 1"
else
  no "AN1 --all last-harness-diverged → expected exit 1; got exit=$RC_AN1"
fi

# AN2: --all diverged → stderr contains fix command for the diverged harness
ERR_AN2="$(bash "$SUT" --all --home "$H_ALL" 2>&1 >/dev/null)"
if printf '%s' "$ERR_AN2" | grep -q 'fix:.*--harness reasonix.*--force-skill'; then
  ok "AN2 --all diverged → fix command for reasonix in stderr"
else
  no "AN2 --all diverged → expected fix command; got: $ERR_AN2"
fi

# AN3: --all diverged → summary shows diverged=1
if printf '%s' "$ERR_AN2" | grep -q 'diverged=1'; then
  ok "AN3 --all diverged → summary diverged=1"
else
  no "AN3 --all diverged → expected 'diverged=1' in summary; got: $ERR_AN2"
fi

# AN4: --all diverged → summary shows absent=2 (opencode + codex not installed)
if printf '%s' "$ERR_AN2" | grep -q 'absent=2'; then
  ok "AN4 --all diverged → summary absent=2"
else
  no "AN4 --all diverged → expected 'absent=2' in summary; got: $ERR_AN2"
fi

# AN5: --all all-absent → exit 0 (not installing is normal)
H_ALL_ABSENT="$ROOT/home_all_absent"
mkdir -p "$H_ALL_ABSENT"
bash "$SUT" --all --home "$H_ALL_ABSENT" 2>/dev/null
RC_AN5=$?
if [ "$RC_AN5" -eq 0 ]; then
  ok "AN5 --all all-absent → exit 0 (normal)"
else
  no "AN5 --all all-absent → expected exit 0; got exit=$RC_AN5"
fi

# AN6: --all in-sync → exit 0 + stdout silent
H_ALL_SYNC="$ROOT/home_all_sync"
mkdir -p "$H_ALL_SYNC/.claude/skills/research-sdd"
cp "$SRC_SKILL" "$H_ALL_SYNC/.claude/skills/research-sdd/SKILL.md"
# Only claude is installed; opencode/codex/reasonix absent
ALL_SYNC_OUT="$(bash "$SUT" --all --home "$H_ALL_SYNC" 2>/dev/null)"
ALL_SYNC_RC=$?
if [ "$ALL_SYNC_RC" -eq 0 ] && [ -z "$ALL_SYNC_OUT" ]; then
  ok "AN6 --all in-sync (one installed) → exit 0 + silent stdout"
else
  no "AN6 --all in-sync → expected exit 0 silent; got exit=$ALL_SYNC_RC out=[$ALL_SYNC_OUT]"
fi

# AN7: --all and --harness are mutually exclusive → exit 2
bash "$SUT" --all --harness claude --home "$H_ALL" 2>/dev/null
RC_AN7=$?
if [ "$RC_AN7" -eq 2 ]; then
  ok "AN7 --all + --harness → exit 2 (mutually exclusive)"
else
  no "AN7 --all + --harness → expected exit 2; got exit=$RC_AN7"
fi

# ── Hook: --all mode (hook calls verify-skill-drift.sh --all) ─────────────────

# Test AN-hook-1: hook --all in-sync → completely silent
H_SYNC_ALL="$ROOT/home_sync_all"
mkdir -p "$H_SYNC_ALL/.claude/skills/research-sdd"
cp "$SRC_SKILL" "$H_SYNC_ALL/.claude/skills/research-sdd/SKILL.md"
HOOK_PATCHED_ALL="$ROOT/hook-test-all.sh"
sed 's|"$here/verify-skill-drift.sh" --all|"'"$SUT"'" --all --home "'"$H_SYNC_ALL"'"|' \
  "$HOOK_SUT" > "$HOOK_PATCHED_ALL"
chmod +x "$HOOK_PATCHED_ALL"
HOOK_OUT_ALL="$(bash "$HOOK_PATCHED_ALL" 2>/dev/null)"
HOOK_RC_ALL=$?
if [ "$HOOK_RC_ALL" -eq 0 ] && [ -z "$HOOK_OUT_ALL" ]; then
  ok "AN-hook-1 hook --all in-sync → completely silent"
else
  no "AN-hook-1 hook --all in-sync → expected silent exit 0; got exit=$HOOK_RC_ALL out=[$HOOK_OUT_ALL]"
fi

# Test AN-hook-2: hook --all diverged (reasonix last) → fix command in output
H_DIV_ALL="$ROOT/home_div_all"
mkdir -p "$H_DIV_ALL/.claude/skills/research-sdd"
cp "$SRC_SKILL" "$H_DIV_ALL/.claude/skills/research-sdd/SKILL.md"     # claude in-sync
mkdir -p "$H_DIV_ALL/.reasonix/skills/research-sdd"
printf 'diverged\n' > "$H_DIV_ALL/.reasonix/skills/research-sdd/SKILL.md"  # reasonix diverged
HOOK_PATCHED2_ALL="$ROOT/hook-test2-all.sh"
sed 's|"$here/verify-skill-drift.sh" --all|"'"$SUT"'" --all --home "'"$H_DIV_ALL"'"|' \
  "$HOOK_SUT" > "$HOOK_PATCHED2_ALL"
chmod +x "$HOOK_PATCHED2_ALL"
HOOK_OUT2_ALL="$(bash "$HOOK_PATCHED2_ALL" 2>&1)"
if printf '%s' "$HOOK_OUT2_ALL" | grep -q 'force-skill'; then
  ok "AN-hook-2 hook --all diverged → output mentions --force-skill"
else
  no "AN-hook-2 hook --all diverged → expected '--force-skill' in output; got [$HOOK_OUT2_ALL]"
fi

# Test AN-hook-3: hook --all all-absent → completely silent (absent is normal)
H_ABS_ALL="$ROOT/home_abs_all"
mkdir -p "$H_ABS_ALL"   # no harness dirs
HOOK_PATCHED3_ALL="$ROOT/hook-test3-all.sh"
sed 's|"$here/verify-skill-drift.sh" --all|"'"$SUT"'" --all --home "'"$H_ABS_ALL"'"|' \
  "$HOOK_SUT" > "$HOOK_PATCHED3_ALL"
chmod +x "$HOOK_PATCHED3_ALL"
HOOK_OUT3_ALL="$(bash "$HOOK_PATCHED3_ALL" 2>&1)"
HOOK_RC3_ALL=$?
if [ "$HOOK_RC3_ALL" -eq 0 ] && [ -z "$HOOK_OUT3_ALL" ]; then
  ok "AN-hook-3 hook --all all-absent → completely silent (absent is normal)"
else
  no "AN-hook-3 hook --all all-absent → expected silent exit 0; got exit=$HOOK_RC3_ALL out=[$HOOK_OUT3_ALL]"
fi

# ── TEETH ─────────────────────────────────────────────────────────────────────
prove_teeth=0
for arg in "$@"; do [ "$arg" = "--prove-teeth" ] && prove_teeth=1; done

# SENTINEL-TEETH-BANNER-START
if [ "$prove_teeth" -eq 1 ]; then
  echo "-- mutation teeth --"

  # Mutant sandbox: mirrors the kit directory structure so SELF_DIR-based path resolution
  # (adapters.sh, kit root, opencode/SKILL.md) works without writing into the live tree.
  # Layout: $ROOT/toolbelt/ (mutants) + $ROOT/install/ + $ROOT/skills/ + $ROOT/toolbelt/opencode/
  # The EXIT trap (set at test start) cleans up $ROOT including all mutants.
  mkdir -p "$ROOT/install" "$ROOT/skills/research-sdd" "$ROOT/toolbelt/opencode"
  cp "$HERE/../../install/adapters.sh"       "$ROOT/install/adapters.sh"
  cp "$SRC_SKILL"                            "$ROOT/skills/research-sdd/SKILL.md"
  cp "$HERE/../opencode/SKILL.md"            "$ROOT/toolbelt/opencode/SKILL.md"
  MUT_DIR="$ROOT/toolbelt"

  # git-status snapshot before any mutant creation (proves no live-tree leakage after)
  _GIT_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
  _GIT_BEFORE="$(git -C "$_GIT_ROOT" status --porcelain 2>/dev/null || true)"

  # TOOTH A: in-sync-not-silent — mutant disables the cmp-s in-sync guard.
  # Real test 6: in-sync → exit 0. Mutant: in-sync → exit 1 (assertion fails → RED).
  H_TA="$ROOT/home_ta"
  make_home_copy "$H_TA" "$SRC_SKILL"
  MUT_A="$MUT_DIR/verify-skill-drift-mut-A.sh"
  sed 's/if cmp -s "\$src" "\$deployed"; then/if false; then/' "$SUT" > "$MUT_A"
  chmod +x "$MUT_A"
  bash "$MUT_A" --harness claude --home "$H_TA" 2>/dev/null
  RC_TA=$?
  if [ "$RC_TA" -ne 0 ]; then
    ok "TOOTH A in-sync-not-silent: mutant exits non-zero on in-sync (assertion would fail — RED)"
  else
    no "TOOTH A in-sync-not-silent: mutant exits 0 on in-sync — tooth has no bite"
  fi

  # TOOTH B: diverged-silent — mutant replaces 'exit 1' (diverged) with 'exit 0'.
  # Real test 7: diverged → exit 1. Mutant: diverged → exit 0 (assertion fails → RED).
  H_TB="$ROOT/home_tb"
  make_home_stale "$H_TB" "# diverged content"
  MUT_B="$MUT_DIR/verify-skill-drift-mut-B.sh"
  # Replace only the final bare 'exit 1' line (the diverged-path exit at end of file)
  sed 's/^exit 1$/exit 0/' "$SUT" > "$MUT_B"
  chmod +x "$MUT_B"
  bash "$MUT_B" --harness claude --home "$H_TB" 2>/dev/null
  RC_TB=$?
  if [ "$RC_TB" -eq 0 ]; then
    ok "TOOTH B diverged-silent: mutant exits 0 on diverged (assertion would fail — RED)"
  else
    no "TOOTH B diverged-silent: mutant exits non-zero — tooth has no bite (RC=$RC_TB)"
  fi

  # TOOTH C: absent-confused — mutant replaces 'exit 3' in absent block with 'exit 0'.
  # Real test 8: absent → exit 3. Mutant: absent → exit 0 (assertion fails → RED).
  H_TC="$ROOT/home_tc"
  mkdir -p "$H_TC/.claude"
  MUT_C="$MUT_DIR/verify-skill-drift-mut-C.sh"
  sed 's/^  exit 3$/  exit 0/' "$SUT" > "$MUT_C"
  chmod +x "$MUT_C"
  bash "$MUT_C" --harness claude --home "$H_TC" 2>/dev/null
  RC_TC=$?
  if [ "$RC_TC" -eq 0 ]; then
    ok "TOOTH C absent-confused: mutant exits 0 for absent (assertion would fail — RED)"
  else
    no "TOOTH C absent-confused: mutant exits non-zero for absent — tooth has no bite (RC=$RC_TC)"
  fi

  # TOOTH D: all-last-skipped — mutant replaces the --all loop to skip the last harness.
  # Real test AN1: reasonix (last in RESEARCH_SDD_HARNESSES) diverged → exit 1.
  # Mutant: loop iterates all-but-last (${RESEARCH_SDD_HARNESSES% *}) → misses reasonix → exit 0.
  # The for-loop sentinel is the literal 'for h in $RESEARCH_SDD_HARNESSES' line in the SUT.
  H_TD="$ROOT/home_td"
  mkdir -p "$H_TD/.claude/skills/research-sdd"
  cp "$SRC_SKILL" "$H_TD/.claude/skills/research-sdd/SKILL.md"
  mkdir -p "$H_TD/.reasonix/skills/research-sdd"
  printf 'stale content\n' > "$H_TD/.reasonix/skills/research-sdd/SKILL.md"
  MUT_D="$MUT_DIR/verify-skill-drift-mut-D.sh"
  # Mutant: change loop to skip the last harness
  sed 's/for h in \$RESEARCH_SDD_HARNESSES; do/for h in ${RESEARCH_SDD_HARNESSES% *}; do/' \
    "$SUT" > "$MUT_D"
  chmod +x "$MUT_D"

  # Pre-check: confirm the sed actually changed the file (sentinel exists in SUT)
  if diff -q "$SUT" "$MUT_D" >/dev/null 2>&1; then
    no "TOOTH D pre-check: mutant = SUT — sed did not match 'for h in \$RESEARCH_SDD_HARNESSES; do'"
  else
    ok "TOOTH D pre-check: mutant differs from SUT (sentinel found)"
  fi

  # Sabotage check: if the sentinel were renamed, the sed would not match and the tooth
  # would correctly report failure (mutant = SUT → no change detected).
  SUT_SAB="$ROOT/sut-sabotaged-D.sh"
  MUT_D_SAB="$ROOT/mut-D-sabotaged.sh"
  # Rename loop variable from 'h' to 'hh' to break the sentinel pattern
  sed 's/for h in \$RESEARCH_SDD_HARNESSES; do/for hh in $RESEARCH_SDD_HARNESSES; do/' \
    "$SUT" > "$SUT_SAB"
  sed 's/for h in \$RESEARCH_SDD_HARNESSES; do/for h in ${RESEARCH_SDD_HARNESSES% *}; do/' \
    "$SUT_SAB" > "$MUT_D_SAB"
  if diff -q "$SUT_SAB" "$MUT_D_SAB" >/dev/null 2>&1; then
    ok "TOOTH D sabotage: renamed sentinel → sed finds no match → tooth would report failure"
  else
    no "TOOTH D sabotage: renamed sentinel → mutant differs — sabotage check inconclusive"
  fi

  # Actual tooth: mutant misses last harness (reasonix) diverged → exits 0 → RED
  bash "$MUT_D" --all --home "$H_TD" 2>/dev/null
  RC_TD=$?
  if [ "$RC_TD" -eq 0 ]; then
    ok "TOOTH D all-last-skipped: mutant exits 0 with reasonix (last) diverged — RED as expected"
  else
    no "TOOTH D all-last-skipped: mutant exits non-zero — tooth has no bite (RC=$RC_TD)"
  fi
  # git-status after all teeth: confirm no files leaked into the live tree
  _GIT_AFTER="$(git -C "$_GIT_ROOT" status --porcelain 2>/dev/null || true)"
  if [ "$_GIT_BEFORE" = "$_GIT_AFTER" ]; then
    ok "TEETH git-clean: no files leaked into live tree"
  else
    no "TEETH git-clean: live tree changed! Before: [$_GIT_BEFORE] After: [$_GIT_AFTER]"
  fi
fi
# SENTINEL-TEETH-BANNER-END

echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1

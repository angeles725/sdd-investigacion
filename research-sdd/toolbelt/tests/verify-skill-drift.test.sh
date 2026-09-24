#!/usr/bin/env bash
# verify-skill-drift.test.sh — RED-FIRST harness for verify-skill-drift.sh.
#
# Exercises: in-sync → exit 0 silent; diverged → exit 1 + message; absent → exit 3;
# could-not-run (missing adapters, dangling symlink, HOME unset) → exit 2; unknown harness → exit 2.
#
# TEETH (--prove-teeth):
#   A  in-sync-not-silent    mutant disables cmp-s guard → in-sync exits 1 (RED)
#   B  diverged-silent       mutant replaces exit 1 → diverged exits 0 (RED)
#   C  absent-confused       mutant exits 0 for absent → absent indistinguishable from in-sync (RED)
#   D  all-last-skipped      mutant skips last harness in loop → diverged at last is missed (RED)
#   E  fixture-src           mutant hardcodes src_relkit=source_a for all → harness_b in-sync falsely diverged (RED)
#   F  dangling-symlink-single  mutant removes SENTINEL-DANGLING-SINGLE block → AX1 regresses exit 2→3 (RED)
#   G  dangling-symlink-all    mutant removes SENTINEL-DANGLING-ALL block → AX2 regresses exit 2→0 (RED)
#   H  HOME-check-deleted    mutant removes SENTINEL-HOME-CHECK block → AX6 regresses exit 2→3 (RED)
#   I  unconditional-summary mutant removes SENTINEL-SUMMARY-GUARD condition → AX5 regresses empty stderr (RED)
#   J  drop-all-err-exit2    mutant removes SENTINEL-ERR-EXIT2 block → AX2 regresses exit 2→0 (RED)
#   K  also-diverged-names   mutant removes SENTINEL-ALSO-DIVERGED → REM1 loses harness names (RED)
# Mutants live in $ROOT/toolbelt/ (never the live tree); verified by git-status before/after.
#
# Usage: verify-skill-drift.test.sh [--prove-teeth]
# Exit: 0 = all held · 1 = regression

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-skill-drift.sh"
HOOK_SUT="$HERE/../verify-skill-drift-hook.sh"
FIXTURES_DIR="$HERE/fixtures"

[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; MUT_F3LEAK=""; MUT_F3COMP=""
trap 'rm -rf "$ROOT"; [ -n "$MUT_F3LEAK" ] && rm -f "$MUT_F3LEAK"; [ -n "$MUT_F3COMP" ] && rm -f "$MUT_F3COMP"' EXIT
pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP  %s\n' "$1"; }

# The real kit path from this test's location
KIT="$(cd "$HERE/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test-driver SUT-locating derivation, never reached through a render (kit issue #1024 round 4)
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
#   H_ALL: claude in-sync, codex absent, reasonix diverged (LAST)
#   — tests the list-edge rule: drift in the last harness in RESEARCH_SDD_HARNESSES order
H_ALL="$ROOT/home_all"
mkdir -p "$H_ALL/.claude/skills/research-sdd"
cp "$SRC_SKILL" "$H_ALL/.claude/skills/research-sdd/SKILL.md"      # claude: in-sync
mkdir -p "$H_ALL/.reasonix/skills/research-sdd"
printf 'stale content — not matching kit\n' > "$H_ALL/.reasonix/skills/research-sdd/SKILL.md"  # reasonix: diverged
# codex (.codex) not created → absent

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

# AN4: --all diverged → summary shows absent=1 (codex not installed)
if printf '%s' "$ERR_AN2" | grep -q 'absent=1'; then
  ok "AN4 --all diverged → summary absent=1"
else
  no "AN4 --all diverged → expected 'absent=1' in summary; got: $ERR_AN2"
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
# Only claude is installed; codex/reasonix absent
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

# ── SRC: per-harness source lookup — verified with two-source fixture ──────────
# No real harness after OpenCode removal has a source distinct from
# skills/research-sdd/SKILL.md, so we prove the per-harness lookup with a
# synthetic two-source fixture (adapters-two-sources.sh): harness_a uses
# skills/source_a/SKILL.md and harness_b uses skills/source_b/SKILL.md.
TWO_KIT="$ROOT/two-src-kit"
mkdir -p "$TWO_KIT/install" "$TWO_KIT/toolbelt" "$TWO_KIT/skills/source_a" "$TWO_KIT/skills/source_b"
# Install the two-source fixture as adapters.sh for this mini-kit
cp "$FIXTURES_DIR/adapters-two-sources.sh" "$TWO_KIT/install/adapters.sh"
# SUT copy inside mini-kit toolbelt (SELF_DIR-based path resolution finds $TWO_KIT)
SUT_SRC="$TWO_KIT/toolbelt/verify-skill-drift.sh"
cp "$SUT" "$SUT_SRC"
chmod +x "$SUT_SRC"
# source_a = real kit SKILL.md
cp "$SRC_SKILL" "$TWO_KIT/skills/source_a/SKILL.md"
# source_b = SKILL.md with an extra comment line (distinct bytes; same logical content)
{ cat "$SRC_SKILL"; printf '# source-b-marker\n'; } > "$TWO_KIT/skills/source_b/SKILL.md"

if [ -f "$SRC_SKILL" ]; then
  # SRC1: harness_a deployed=source_a, harness_b deployed=source_b → both in-sync → exit 0
  H_SRC1="$ROOT/home_src1"
  mkdir -p "$H_SRC1/.harness_a/skills/research-sdd" "$H_SRC1/.harness_b/skills/research-sdd"
  cp "$TWO_KIT/skills/source_a/SKILL.md" "$H_SRC1/.harness_a/skills/research-sdd/SKILL.md"
  cp "$TWO_KIT/skills/source_b/SKILL.md" "$H_SRC1/.harness_b/skills/research-sdd/SKILL.md"
  bash "$SUT_SRC" --all --home "$H_SRC1" 2>/dev/null
  RC_SRC1=$?
  if [ "$RC_SRC1" -eq 0 ]; then
    ok "SRC1 two-source fixture --all both-in-sync → exit 0"
  else
    no "SRC1 two-source fixture --all both-in-sync → expected exit 0; got exit=$RC_SRC1"
  fi

  # SRC2: harness_b deployed=source_a (wrong source) → harness_b diverged → exit 1
  H_SRC2="$ROOT/home_src2"
  mkdir -p "$H_SRC2/.harness_a/skills/research-sdd" "$H_SRC2/.harness_b/skills/research-sdd"
  cp "$TWO_KIT/skills/source_a/SKILL.md" "$H_SRC2/.harness_a/skills/research-sdd/SKILL.md"
  cp "$TWO_KIT/skills/source_a/SKILL.md" "$H_SRC2/.harness_b/skills/research-sdd/SKILL.md"  # wrong source
  bash "$SUT_SRC" --all --home "$H_SRC2" 2>/dev/null
  RC_SRC2=$?
  if [ "$RC_SRC2" -eq 1 ]; then
    ok "SRC2 two-source fixture --all harness_b wrong-source → exit 1"
  else
    no "SRC2 two-source fixture --all harness_b wrong-source → expected exit 1; got exit=$RC_SRC2"
  fi
else
  no "SRC1 SRC2 — kit SKILL.md source not found; skipping two-source fixture tests"
  no "SRC2 — see above"
fi

# ── AX: Additional checks — dangling symlink, unreadable, HOME unset, --all exit 2 ──

# AX1: dangling symlink at deployed path in single mode → exit 2 (not exit 3 for absent)
H_AX1="$ROOT/home_ax1"
mkdir -p "$H_AX1/.claude/skills/research-sdd"
DANGLE_AX1="$H_AX1/.claude/skills/research-sdd/SKILL.md"
ln -s "$ROOT/nonexistent-target-for-ax1" "$DANGLE_AX1"
bash "$SUT" --harness claude --home "$H_AX1" 2>/dev/null
RC_AX1=$?
if [ "$RC_AX1" -eq 2 ]; then
  ok "AX1 dangling symlink single → exit 2 (not exit 3 for absent)"
else
  no "AX1 dangling symlink single → expected exit 2; got exit=$RC_AX1"
fi

# AX2: dangling symlink at deployed path in --all mode → exit 2 (not exit 0)
H_AX2="$ROOT/home_ax2"
mkdir -p "$H_AX2/.claude/skills/research-sdd"
DANGLE_AX2="$H_AX2/.claude/skills/research-sdd/SKILL.md"
ln -s "$ROOT/nonexistent-target-for-ax2" "$DANGLE_AX2"
bash "$SUT" --all --home "$H_AX2" 2>/dev/null
RC_AX2=$?
if [ "$RC_AX2" -eq 2 ]; then
  ok "AX2 dangling symlink --all → exit 2 (not exit 0)"
else
  no "AX2 dangling symlink --all → expected exit 2; got exit=$RC_AX2"
fi

# AX3: --all unreadable-deployed → exit 2 (skip if running as root; chmod has no effect)
if [ "$(id -u)" -ne 0 ]; then
  H_AX3="$ROOT/home_ax3"
  mkdir -p "$H_AX3/.claude/skills/research-sdd"
  printf 'deployed\n' > "$H_AX3/.claude/skills/research-sdd/SKILL.md"
  chmod 000 "$H_AX3/.claude/skills/research-sdd/SKILL.md"
  bash "$SUT" --all --home "$H_AX3" 2>/dev/null
  RC_AX3=$?
  chmod 644 "$H_AX3/.claude/skills/research-sdd/SKILL.md"  # restore so EXIT trap can delete
  if [ "$RC_AX3" -eq 2 ]; then
    ok "AX3 --all unreadable-deployed → exit 2"
  else
    no "AX3 --all unreadable-deployed → expected exit 2; got exit=$RC_AX3"
  fi
else
  skip "AX3 --all unreadable-deployed → SKIP (running as root; chmod 000 has no effect)"
fi

# AX4: --all src-missing → exit 2 (kit source file not present for a harness)
# Uses a mini-kit under $ROOT/ax4-kit/ that has adapters.sh but no SKILL.md source.
AX4_KIT="$ROOT/ax4-kit"
AX4_INSTALL="$AX4_KIT/install"
mkdir -p "$AX4_INSTALL" "$AX4_KIT/toolbelt"
cp "$KIT/install/adapters.sh" "$AX4_INSTALL/adapters.sh"
# Deliberately omit $AX4_KIT/skills/research-sdd/SKILL.md → src missing for claude
SUT_AX4="$AX4_KIT/toolbelt/verify-skill-drift.sh"
cp "$SUT" "$SUT_AX4"
chmod +x "$SUT_AX4"
H_AX4="$ROOT/home_ax4"
mkdir -p "$H_AX4/.claude/skills/research-sdd"
cp "$SRC_SKILL" "$H_AX4/.claude/skills/research-sdd/SKILL.md"  # claude deployed
bash "$SUT_AX4" --all --home "$H_AX4" 2>/dev/null
RC_AX4=$?
if [ "$RC_AX4" -eq 2 ]; then
  ok "AX4 --all src-missing → exit 2 (could-not-run)"
else
  no "AX4 --all src-missing → expected exit 2; got exit=$RC_AX4"
fi

# AX5: --all in-sync → stderr is empty (not just stdout silent)
# Uses the AN6 home (claude only, in-sync). AN6 already checks exit 0 + stdout silent.
ALL_SYNC_STDERR="$(bash "$SUT" --all --home "$H_ALL_SYNC" 2>&1 1>/dev/null)"
if [ -z "$ALL_SYNC_STDERR" ]; then
  ok "AX5 --all in-sync → stderr empty (summary suppressed on clean run)"
else
  no "AX5 --all in-sync → expected empty stderr; got: $ALL_SYNC_STDERR"
fi

# AX6: HOME unset → exit 2 with typed could-not-run message (not stale / abort)
AX6_ERR="$(env -u HOME bash "$SUT" 2>&1)"
RC_AX6=$?
if [ "$RC_AX6" -eq 2 ] && printf '%s' "$AX6_ERR" | grep -q 'could-not-run.*HOME'; then
  ok "AX6 HOME unset → exit 2 + typed 'could-not-run: HOME is unset'"
else
  no "AX6 HOME unset → expected exit 2 + could-not-run; got exit=$RC_AX6 err=[$AX6_ERR]"
fi

# AX7: hook HOME unset → output contains ERROR (not WARN for stale)
# The hook captures SUT's output including stderr; a could-not-run (exit 2) maps to ERROR.
HOOK_AX7="$ROOT/hook-ax7.sh"
sed 's|"$here/verify-skill-drift.sh" --all|env -u HOME "'"$SUT"'" --all|' \
  "$HOOK_SUT" > "$HOOK_AX7"
chmod +x "$HOOK_AX7"
AX7_OUT="$(bash "$HOOK_AX7" 2>&1)"
if printf '%s' "$AX7_OUT" | grep -qi 'ERROR'; then
  ok "AX7 hook HOME unset → output contains ERROR (not WARN)"
else
  no "AX7 hook HOME unset → expected ERROR in output; got: $AX7_OUT"
fi

# AX8: --home given without $HOME in env → exit 0 (--home overrides missing $HOME)
# Reuses H_SYNC (claude in-sync). Redirect stdout; check only exit code.
env -u HOME bash "$SUT" --harness claude --home "$H_SYNC" >/dev/null 2>/dev/null
RC_AX8=$?
if [ "$RC_AX8" -eq 0 ]; then
  ok "AX8 HOME unset + --home given → exit 0 (--home overrides)"
else
  no "AX8 HOME unset + --home given → expected exit 0; got exit=$RC_AX8"
fi

# AX9: --help without $HOME in env → exit 0 (--help does not need HOME)
# --help writes to stdout; redirect it so we capture only the exit code.
env -u HOME bash "$SUT" --help >/dev/null 2>/dev/null
RC_AX9=$?
if [ "$RC_AX9" -eq 0 ]; then
  ok "AX9 HOME unset + --help → exit 0 (--help works without HOME)"
else
  no "AX9 HOME unset + --help → expected exit 0; got exit=$RC_AX9"
fi

# ── BDG: SessionStart budget tests ────────────────────────────────────────────
# The hook's output chars count toward the 8,000-char total aggregate budget.
# Other 7 hooks measured at 7,458 chars → headroom = 542 chars for this hook.
# in-sync: hook must be completely silent (0 chars).
# 1 diverged: hook output must be compact (< 542 chars, within aggregate headroom).
# all diverged: even worst-case (all 4 harnesses diverged) must stay < 542 chars.

# BDG1: in-sync → hook output is exactly 0 chars (reuse HOOK_OUT_ALL which was empty)
# (AN-hook-1 already checks this but we want a named budget assertion)
H_BDG1="$ROOT/home_bdg1"
mkdir -p "$H_BDG1/.claude/skills/research-sdd"
cp "$SRC_SKILL" "$H_BDG1/.claude/skills/research-sdd/SKILL.md"
HOOK_BDG1="$ROOT/hook-bdg1.sh"
sed 's|"$here/verify-skill-drift.sh" --all|"'"$SUT"'" --all --home "'"$H_BDG1"'"|' \
  "$HOOK_SUT" > "$HOOK_BDG1"
chmod +x "$HOOK_BDG1"
BDG1_OUT="$(bash "$HOOK_BDG1" 2>&1)"
BDG1_LEN="${#BDG1_OUT}"
if [ "$BDG1_LEN" -eq 0 ]; then
  ok "BDG1 hook in-sync → 0 chars output (budget: 0)"
else
  no "BDG1 hook in-sync → expected 0 chars; got $BDG1_LEN chars: $BDG1_OUT"
fi

# BDG2: 1 diverged → hook output < 542 chars (aggregate budget headroom = 8000 - 7458)
# Uses home with one diverged harness (claude).
H_BDG2="$ROOT/home_bdg2"
make_home_stale "$H_BDG2" "# diverged content for budget test"
HOOK_BDG2="$ROOT/hook-bdg2.sh"
sed 's|"$here/verify-skill-drift.sh" --all|"'"$SUT"'" --all --home "'"$H_BDG2"'"|' \
  "$HOOK_SUT" > "$HOOK_BDG2"
chmod +x "$HOOK_BDG2"
BDG2_OUT="$(bash "$HOOK_BDG2" 2>&1)"
BDG2_LEN="${#BDG2_OUT}"
if [ "$BDG2_LEN" -gt 0 ] && [ "$BDG2_LEN" -lt 542 ]; then
  ok "BDG2 hook 1-diverged → ${BDG2_LEN} chars output (budget: < 542)"
elif [ "$BDG2_LEN" -eq 0 ]; then
  no "BDG2 hook 1-diverged → 0 chars (expected non-zero; diverged should emit)"
else
  no "BDG2 hook 1-diverged → ${BDG2_LEN} chars output (≥ 542 — aggregate budget exceeded)"
fi

# BDG3: all 3 harnesses diverged → hook output < 542 chars (worst-case budget test)
# cap in SUT (max_fix_lines=1) limits output even when all harnesses diverge.
H_BDG3="$ROOT/home_bdg3"
mkdir -p "$H_BDG3/.claude/skills/research-sdd"
printf '# stale claude\n' > "$H_BDG3/.claude/skills/research-sdd/SKILL.md"
mkdir -p "$H_BDG3/.codex/skills/research-sdd"
printf '# stale codex\n' > "$H_BDG3/.codex/skills/research-sdd/SKILL.md"
mkdir -p "$H_BDG3/.reasonix/skills/research-sdd"
printf '# stale reasonix\n' > "$H_BDG3/.reasonix/skills/research-sdd/SKILL.md"
HOOK_BDG3="$ROOT/hook-bdg3.sh"
sed 's|"$here/verify-skill-drift.sh" --all|"'"$SUT"'" --all --home "'"$H_BDG3"'"|' \
  "$HOOK_SUT" > "$HOOK_BDG3"
chmod +x "$HOOK_BDG3"
BDG3_OUT="$(bash "$HOOK_BDG3" 2>&1)"
BDG3_LEN="${#BDG3_OUT}"
if [ "$BDG3_LEN" -gt 0 ] && [ "$BDG3_LEN" -lt 542 ]; then
  ok "BDG3 hook all-diverged → ${BDG3_LEN} chars output (budget: < 542)"
elif [ "$BDG3_LEN" -eq 0 ]; then
  no "BDG3 hook all-diverged → 0 chars (expected non-zero; diverged should emit)"
else
  no "BDG3 hook all-diverged → ${BDG3_LEN} chars output (≥ 542 — aggregate budget exceeded)"
fi

# REM1: ≥2 harnesses diverged → every diverged harness name appears in stderr
# H_BDG3 (set up above) has all 3 harnesses diverged; max_fix_lines=1 → claude gets
# the detailed fix line, codex/reasonix must appear in "also diverged" line.
REM1_OUT="$(bash "$SUT" --all --home "$H_BDG3" 2>&1)"
if printf '%s\n' "$REM1_OUT" | grep -qF 'claude' && \
   printf '%s\n' "$REM1_OUT" | grep -qF 'codex' && \
   printf '%s\n' "$REM1_OUT" | grep -qF 'reasonix'; then
  ok "REM1 3-diverged → all harness names appear in output"
else
  no "REM1 3-diverged → some harness names missing from output: $REM1_OUT"
fi

# ── PD: profile-aware drift detection (kit issue #993 WU2) ────────────────────
# PD1: install "general" for reasonix (its per-harness default — adapters.sh _RSDD_DEFAULT_PROFILE)
#      with the REAL installer, then verify-skill-drift re-renders that SAME profile into a
#      throwaway temp dir and compares against it: in-sync on the untouched install, diverged
#      after a hand-edit. Exercises the real render-profile.sh end-to-end, never a mutant.
INSTALLER_PD="$KIT/install/research-sdd-install.sh"
if [ ! -f "$INSTALLER_PD" ]; then
  no "PD1 setup: installer not found: $INSTALLER_PD"
else
  H_PD1="$ROOT/home_pd1"
  bash "$INSTALLER_PD" --home "$H_PD1" --harness reasonix >/dev/null 2>&1
  DEPLOYED_PD1="$H_PD1/.reasonix/skills/research-sdd/SKILL.md"
  if [ ! -f "$DEPLOYED_PD1" ]; then
    no "PD1 setup: install did not produce a deployed skill at $DEPLOYED_PD1"
  else
    bash "$SUT" --harness reasonix --home "$H_PD1" >/dev/null 2>&1
    RC_PD1_SYNC=$?
    if [ "$RC_PD1_SYNC" -eq 0 ]; then
      ok "PD1a: fresh general-profile install is in-sync (exit 0)"
    else
      no "PD1a: fresh general-profile install reported drift (exit $RC_PD1_SYNC) — expected in-sync"
    fi

    printf '\n<!-- hand-edited by an operator -->\n' >> "$DEPLOYED_PD1"
    ERR_PD1_DIV="$(bash "$SUT" --harness reasonix --home "$H_PD1" 2>&1)"
    RC_PD1_DIV=$?
    if [ "$RC_PD1_DIV" -eq 1 ] && printf '%s' "$ERR_PD1_DIV" | grep -q 'diverged'; then
      ok "PD1b: hand-edited general-profile skill is detected as diverged (exit 1)"
    else
      no "PD1b: hand-edit not detected (rc=$RC_PD1_DIV, out=$ERR_PD1_DIV)"
    fi
  fi
fi

# PD2: --profile claude stays byte-exact against the kit source (regression guard — the profile
#      flag must not perturb the default comparison path at all).
H_PD2="$ROOT/home_pd2"
make_home_copy "$H_PD2" "$SRC_SKILL"
bash "$SUT" --harness claude --home "$H_PD2" --profile claude >/dev/null 2>&1
RC_PD2=$?
[ "$RC_PD2" -eq 0 ] && ok "PD2: --profile claude stays byte-exact (in-sync on an untouched copy)" \
  || no "PD2: --profile claude regressed (exit $RC_PD2)"

# PD3: an unknown --profile is could-not-run (exit 2) — never a false in-sync/diverged verdict.
H_PD3="$ROOT/home_pd3"
make_home_copy "$H_PD3" "$SRC_SKILL"
ERR_PD3="$(bash "$SUT" --harness claude --home "$H_PD3" --profile bogus-profile-xyz 2>&1)"
RC_PD3=$?
if [ "$RC_PD3" -eq 2 ] && printf '%s' "$ERR_PD3" | grep -qi 'unknown profile'; then
  ok "PD3: unknown --profile is could-not-run (exit 2), not a false verdict"
else
  no "PD3: unknown --profile: wrong exit/message (rc=$RC_PD3, out=$ERR_PD3)"
fi

# ── kit issue #1024 round 4, MEDIUM: symlinked toolbelt (render dir) ──────────
# SELF_DIR/KIT_INSTALL/KIT used to be derived via plain (logical) `cd`/`pwd`. Invoked directly,
# that is harmless — but this script's OWN F1-completed render dir (kit issue #993 WU2 + #1024
# F1) symlinks toolbelt/ (and install/, profiles/, etc.) straight into the real kit, so a
# non-claude harness's deployed skill_path check ends up running THIS script through that
# symlink. Reproduced against the pre-fix SUT: KIT collapsed onto the render dir itself, so
# _vsd_resolve_src's re-render call ("$KIT/toolbelt/render-profile.sh") tried to re-render the
# render's OWN already-rendered (marker-free) files and failed loudly with "zero slot markers
# found in sources" — exit 2 (could-not-run) for every reasonix/general check, every time, single-
# harness AND --all. This uses the REAL installer against a REAL kit (the established TOOTH-PD
# pattern above — this script's own resolution chain needs a REAL render-profile.sh, REAL
# profiles/*.slots.md and REAL slot-marker-bearing sources to reach the exact failure mode; a
# synthetic mini-kit would have to reimplement render-profile.sh's own behaviour to reproduce it),
# with only a THROWAWAY --home — never the real fleet, never real ~/.claude/~/.codex config.
if [ -f "$INSTALLER_PD" ]; then
  H_SYM="$ROOT/home_symlink_toolbelt"
  bash "$INSTALLER_PD" --home "$H_SYM" --harness reasonix >/dev/null 2>&1
  RENDER_TB_SYM="$H_SYM/.reasonix/research-sdd/profile/general/toolbelt/verify-skill-drift.sh"
  if [ -x "$RENDER_TB_SYM" ]; then
    OUT_SYM_SINGLE="$(bash "$RENDER_TB_SYM" --harness reasonix --home "$H_SYM" 2>&1)"; RC_SYM_SINGLE=$?
    OUT_SYM_ALL="$(bash "$RENDER_TB_SYM" --all --home "$H_SYM" 2>&1)"; RC_SYM_ALL=$?
    if [ "$RC_SYM_SINGLE" -eq 0 ] && [ "$RC_SYM_ALL" -eq 0 ] \
       && ! printf '%s%s' "$OUT_SYM_SINGLE" "$OUT_SYM_ALL" | grep -qi 'zero slot markers'; then
      ok "SYMLINK-TOOLBELT: invoked through a symlinked toolbelt/, resolves the real kit root (single: rc=$RC_SYM_SINGLE, --all: rc=$RC_SYM_ALL)"
    else
      no "SYMLINK-TOOLBELT: invoked through a symlinked toolbelt/ failed (single rc=$RC_SYM_SINGLE out=[$OUT_SYM_SINGLE]; --all rc=$RC_SYM_ALL out=[$OUT_SYM_ALL])"
    fi
  else
    no "SYMLINK-TOOLBELT setup: rendered toolbelt/verify-skill-drift.sh not found or not executable at $RENDER_TB_SYM"
  fi
else
  no "SYMLINK-TOOLBELT setup: installer not found — cannot exercise this test"
fi

# ── kit issue #1024 review round 2, F3 (MEDIUM) ───────────────────────────────
# _vsd_resolve_src used to be called as `src="$(_vsd_resolve_src ...)"`, running the WHOLE
# function in a subshell; its `_VSD_RENDER_TMPDIRS+=()` append only ever mutated that subshell's
# own copy of the array, so the EXIT trap in the PARENT shell never saw the entry and leaked one
# tmp dir per --all run (per SessionStart). Fixed via named-output parameters (printf -v) and a
# DIRECT call. Separately, a missing or hand-edited PERSISTED render dir used to be invisible —
# only the deployed skill_path was ever compared — so "in sync" could be reported while
# "Kit path:" pointed at nothing; fixed by _vsd_check_render_completeness.

# F3-leak: no tmp dir survives under a DEDICATED TMPDIR, for both single-harness and --all modes.
if [ -f "$INSTALLER_PD" ]; then
  H_F3LEAK="$ROOT/home_f3leak"
  bash "$INSTALLER_PD" --home "$H_F3LEAK" --harness reasonix >/dev/null 2>&1
  F3_TMPDIR="$ROOT/f3-dedicated-tmpdir"; mkdir -p "$F3_TMPDIR"
  TMPDIR="$F3_TMPDIR" bash "$SUT" --harness reasonix --home "$H_F3LEAK" >/dev/null 2>&1
  TMPDIR="$F3_TMPDIR" bash "$SUT" --all --home "$H_F3LEAK" >/dev/null 2>&1
  F3_LEFTOVER="$(find "$F3_TMPDIR" -mindepth 1 -maxdepth 1 2>/dev/null)"
  if [ -z "$F3_LEFTOVER" ]; then
    ok "F3-leak: no tmp dir survives under a dedicated TMPDIR (single-harness + --all)"
  else
    no "F3-leak: tmp dir(s) leaked under a dedicated TMPDIR: $F3_LEFTOVER"
  fi
else
  no "F3-leak: installer not found — cannot exercise this test"
fi

# F3-missing: a MISSING persisted render dir is reported LOUDLY (could-not-run, exit 2) — never
# silently folded into "in sync" just because the deployed skill_path happens to match a fresh
# render's bytes.
if [ -f "$INSTALLER_PD" ]; then
  H_F3MISS="$ROOT/home_f3miss"
  bash "$INSTALLER_PD" --home "$H_F3MISS" --harness reasonix >/dev/null 2>&1
  rm -rf "$H_F3MISS/.reasonix/research-sdd/profile/general"
  ERR_F3MISS="$(bash "$SUT" --harness reasonix --home "$H_F3MISS" 2>&1)"; RC_F3MISS=$?
  if [ "$RC_F3MISS" -eq 2 ] && printf '%s' "$ERR_F3MISS" | grep -qi 'render dir missing'; then
    ok "F3-missing: a missing persisted render dir is could-not-run (exit 2), never in-sync"
  else
    no "F3-missing: missing render dir not detected (rc=$RC_F3MISS, out=$ERR_F3MISS)"
  fi
else
  no "F3-missing: installer not found — cannot exercise this test"
fi

# F3-handedit: a hand-edited PERSISTED render file (PROMPT-LOOP.md, not the deployed SKILL.md) is
# detected — the deployed skill_path can still byte-match a fresh render while the render dir
# it depends on at runtime has been tampered with.
if [ -f "$INSTALLER_PD" ]; then
  H_F3HE="$ROOT/home_f3he"
  bash "$INSTALLER_PD" --home "$H_F3HE" --harness reasonix >/dev/null 2>&1
  echo "tampered" >> "$H_F3HE/.reasonix/research-sdd/profile/general/PROMPT-LOOP.md"
  ERR_F3HE="$(bash "$SUT" --harness reasonix --home "$H_F3HE" 2>&1)"; RC_F3HE=$?
  if [ "$RC_F3HE" -eq 2 ] && printf '%s' "$ERR_F3HE" | grep -qi 'render dir diverged'; then
    ok "F3-handedit: a hand-edited persisted PROMPT-LOOP.md is detected (could-not-run, not in-sync)"
  else
    no "F3-handedit: hand-edited render dir not detected (rc=$RC_F3HE, out=$ERR_F3HE)"
  fi
else
  no "F3-handedit: installer not found — cannot exercise this test"
fi

# ── TEETH ─────────────────────────────────────────────────────────────────────
prove_teeth=0
for arg in "$@"; do [ "$arg" = "--prove-teeth" ] && prove_teeth=1; done

# SENTINEL-TEETH-BANNER-START
if [ "$prove_teeth" -eq 1 ]; then
  echo "-- mutation teeth --"

  # Mutant sandbox: mirrors the kit directory structure so SELF_DIR-based path resolution
  # (adapters.sh, kit root) works without writing into the live tree.
  # Layout: $ROOT/toolbelt/ (mutants) + $ROOT/install/ + $ROOT/skills/
  # The EXIT trap (set at test start) cleans up $ROOT including all mutants.
  mkdir -p "$ROOT/install" "$ROOT/skills/research-sdd" "$ROOT/toolbelt"
  cp "$HERE/../../install/adapters.sh"       "$ROOT/install/adapters.sh"
  cp "$SRC_SKILL"                            "$ROOT/skills/research-sdd/SKILL.md"
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

  # TOOTH E: fixture-src — hardcoded src_relkit=source_a for all → harness_b in-sync falsely diverged.
  # Proves SENTINEL-SRC-RELKIT-LOOKUP is actually used (not hardcoded).
  # Uses the two-src-kit (already built above): harness_a→source_a, harness_b→source_b.
  # Mutant MUST live in $TWO_KIT/toolbelt/ so its SELF_DIR resolves to the two-src adapters
  # (not the real kit adapters, which would fail to find skills/source_{a,b}/SKILL.md).
  # Mutant: replace the skill_src_relkit lookup with hardcoded "skills/source_a/SKILL.md".
  MUT_E="$TWO_KIT/toolbelt/verify-skill-drift-mut-E.sh"
  # Sentinel: the --all loop line that reads skill_src_relkit dynamically (with $home as 3rd arg)
  sed 's/src_relkit="\$(rsdd_field "\$h" skill_src_relkit "\$home")"/src_relkit="skills\/source_a\/SKILL.md"/' \
    "$SUT_SRC" > "$MUT_E"
  chmod +x "$MUT_E"

  # Pre-check: confirm sed matched (mutant differs from SUT_SRC)
  if diff -q "$SUT_SRC" "$MUT_E" >/dev/null 2>&1; then
    no "TOOTH E pre-check: mutant = SUT — sed did not match skill_src_relkit lookup line"
  else
    ok "TOOTH E pre-check: mutant differs from SUT (sentinel found)"
  fi

  # bash -n: mutant must parse cleanly
  if bash -n "$MUT_E" 2>/dev/null; then
    ok "TOOTH E pre-check: mutant parses (bash -n)"
  else
    no "TOOTH E pre-check: mutant has syntax error (bash -n failed)"
  fi

  # Control: harness_a in-sync only (harness_b absent); mutant hardcodes source_a → harness_a still in-sync
  H_TE_CTRL="$ROOT/home_te_ctrl"
  mkdir -p "$H_TE_CTRL/.harness_a/skills/research-sdd"
  cp "$TWO_KIT/skills/source_a/SKILL.md" "$H_TE_CTRL/.harness_a/skills/research-sdd/SKILL.md"
  bash "$MUT_E" --all --home "$H_TE_CTRL" 2>/dev/null
  RC_TE_CTRL=$?
  if [ "$RC_TE_CTRL" -eq 0 ]; then
    ok "TOOTH E control: harness_a in-sync (source_a) → exit 0 (mutant does not break harness_a)"
  else
    no "TOOTH E control: harness_a in-sync → expected exit 0; got exit=$RC_TE_CTRL (bad mutant)"
  fi

  # Actual tooth: SRC1 home (harness_b deployed=source_b) → mutant hardcodes source_a → mismatch → exit 1
  bash "$MUT_E" --all --home "$H_SRC1" 2>/dev/null
  RC_TE=$?
  if [ "$RC_TE" -eq 1 ]; then
    ok "TOOTH E fixture-src: mutant exits 1 for harness_b in-sync (wrong src) — RED as expected"
  else
    no "TOOTH E fixture-src: mutant exits $RC_TE for harness_b in-sync — tooth has no bite"
  fi

  # TOOTH F: dangling-symlink-single — remove SENTINEL-DANGLING-SINGLE block.
  # Real test AX1: dangling symlink single → exit 2. Mutant: → exit 3 (absent path) → RED.
  MUT_F="$MUT_DIR/verify-skill-drift-mut-F.sh"
  # Delete: # SENTINEL-DANGLING-SINGLE + next 4 lines (if/printf/exit 2/fi)
  sed '/# SENTINEL-DANGLING-SINGLE/{N;N;N;N;d}' "$SUT" > "$MUT_F"
  chmod +x "$MUT_F"

  # Pre-check
  if diff -q "$SUT" "$MUT_F" >/dev/null 2>&1; then
    no "TOOTH F pre-check: mutant = SUT — SENTINEL-DANGLING-SINGLE not found"
  else
    ok "TOOTH F pre-check: mutant differs (SENTINEL-DANGLING-SINGLE removed)"
  fi

  # Actual tooth: dangling symlink in single mode → without guard exits 3 (absent) not 2 → RED
  bash "$MUT_F" --harness claude --home "$H_AX1" 2>/dev/null
  RC_TF=$?
  if [ "$RC_TF" -ne 2 ]; then
    ok "TOOTH F dangling-symlink-single: mutant exits $RC_TF (not 2) — RED as expected"
  else
    no "TOOTH F dangling-symlink-single: mutant still exits 2 — tooth has no bite"
  fi

  # TOOTH G: dangling-symlink-all — remove SENTINEL-DANGLING-ALL block.
  # Real test AX2: dangling symlink --all → exit 2. Mutant: → exit 0 (counted as absent) → RED.
  MUT_G="$MUT_DIR/verify-skill-drift-mut-G.sh"
  # Delete: # SENTINEL-DANGLING-ALL + next 5 lines (if/err_count++/printf/continue/fi)
  sed '/# SENTINEL-DANGLING-ALL/{N;N;N;N;N;d}' "$SUT" > "$MUT_G"
  chmod +x "$MUT_G"

  # Pre-check
  if diff -q "$SUT" "$MUT_G" >/dev/null 2>&1; then
    no "TOOTH G pre-check: mutant = SUT — SENTINEL-DANGLING-ALL not found"
  else
    ok "TOOTH G pre-check: mutant differs (SENTINEL-DANGLING-ALL removed)"
  fi

  # Actual tooth: dangling symlink in --all → without guard counts as absent → exit 0 → RED
  bash "$MUT_G" --all --home "$H_AX2" 2>/dev/null
  RC_TG=$?
  if [ "$RC_TG" -ne 2 ]; then
    ok "TOOTH G dangling-symlink-all: mutant exits $RC_TG (not 2) — RED as expected"
  else
    no "TOOTH G dangling-symlink-all: mutant still exits 2 — tooth has no bite"
  fi

  # TOOTH H: HOME-check-deleted — remove SENTINEL-HOME-CHECK block.
  # Real test AX6: HOME unset → exit 2 + typed message. Mutant: → exit 3 (absent) → RED.
  MUT_H="$MUT_DIR/verify-skill-drift-mut-H.sh"
  # Delete: # SENTINEL-HOME-CHECK + next 4 lines (if/printf/exit 2/fi)
  sed '/# SENTINEL-HOME-CHECK/{N;N;N;N;d}' "$SUT" > "$MUT_H"
  chmod +x "$MUT_H"

  # Pre-check
  if diff -q "$SUT" "$MUT_H" >/dev/null 2>&1; then
    no "TOOTH H pre-check: mutant = SUT — SENTINEL-HOME-CHECK not found"
  else
    ok "TOOTH H pre-check: mutant differs (SENTINEL-HOME-CHECK removed)"
  fi

  # Actual tooth: HOME unset → without check, home="" → rsdd_field resolves under "" → absent → exit 3 → RED
  env -u HOME bash "$MUT_H" 2>/dev/null
  RC_TH=$?
  if [ "$RC_TH" -ne 2 ]; then
    ok "TOOTH H HOME-check-deleted: mutant exits $RC_TH (not 2) — RED as expected"
  else
    no "TOOTH H HOME-check-deleted: mutant still exits 2 — tooth has no bite"
  fi

  # TOOTH I: unconditional-summary — make SENTINEL-SUMMARY-GUARD condition always true.
  # Real test AX5: --all in-sync → stderr empty. Mutant: summary always prints → stderr non-empty → RED.
  MUT_I="$MUT_DIR/verify-skill-drift-mut-I.sh"
  # Replace the guarded condition with 'if true; then' (summary always runs)
  sed '/# SENTINEL-SUMMARY-GUARD/{n; s/if \[ .* -gt 0 .*/if true; then/}' "$SUT" > "$MUT_I"
  chmod +x "$MUT_I"

  # Pre-check
  if diff -q "$SUT" "$MUT_I" >/dev/null 2>&1; then
    no "TOOTH I pre-check: mutant = SUT — SENTINEL-SUMMARY-GUARD not found or sed did not match"
  else
    ok "TOOTH I pre-check: mutant differs (SENTINEL-SUMMARY-GUARD condition removed)"
  fi

  # Actual tooth: in-sync home → without guard, summary always prints → stderr non-empty → RED
  TOOTH_I_STDERR="$(bash "$MUT_I" --all --home "$H_ALL_SYNC" 2>&1 1>/dev/null)"
  if [ -n "$TOOTH_I_STDERR" ]; then
    ok "TOOTH I unconditional-summary: in-sync run emits stderr (summary unconditional) — RED as expected"
  else
    no "TOOTH I unconditional-summary: in-sync run still silent — tooth has no bite"
  fi

  # TOOTH J: drop-all-err-exit2 — remove SENTINEL-ERR-EXIT2 block.
  # Real test AX2: dangling symlink --all → exit 2 (err_count=1, no diverged → exit via err guard).
  # Mutant: err guard deleted → exits 0 (no diverged_count) → RED.
  MUT_J="$MUT_DIR/verify-skill-drift-mut-J.sh"
  # Delete: # SENTINEL-ERR-EXIT2 + next line (if [ "$err_count" ... ]; then exit 2; fi)
  sed '/# SENTINEL-ERR-EXIT2/{N;d}' "$SUT" > "$MUT_J"
  chmod +x "$MUT_J"

  # Pre-check
  if diff -q "$SUT" "$MUT_J" >/dev/null 2>&1; then
    no "TOOTH J pre-check: mutant = SUT — SENTINEL-ERR-EXIT2 not found"
  else
    ok "TOOTH J pre-check: mutant differs (SENTINEL-ERR-EXIT2 removed)"
  fi

  # Actual tooth: dangling symlink --all → err_count=1, diverged_count=0 → without err guard → exit 0 → RED
  bash "$MUT_J" --all --home "$H_AX2" 2>/dev/null
  RC_TJ=$?
  if [ "$RC_TJ" -ne 2 ]; then
    ok "TOOTH J drop-all-err-exit2: mutant exits $RC_TJ (not 2) — RED as expected"
  else
    no "TOOTH J drop-all-err-exit2: mutant still exits 2 — tooth has no bite"
  fi

  # TOOTH K: also-diverged-names — remove SENTINEL-ALSO-DIVERGED block.
  # Real test REM1: all 3 diverged → codex/reasonix must appear in also-diverged line.
  # Mutant: accumulator deleted → also_names stays empty → guard blocks print → names absent → RED.
  MUT_K="$MUT_DIR/verify-skill-drift-mut-K.sh"
  # Delete: # SENTINEL-ALSO-DIVERGED + next line (also_names=...)
  sed '/# SENTINEL-ALSO-DIVERGED/{N;d}' "$SUT" > "$MUT_K"
  chmod +x "$MUT_K"

  # Pre-check
  if diff -q "$SUT" "$MUT_K" >/dev/null 2>&1; then
    no "TOOTH K pre-check: mutant = SUT — SENTINEL-ALSO-DIVERGED not found"
  else
    ok "TOOTH K pre-check: mutant differs (SENTINEL-ALSO-DIVERGED removed)"
  fi

  # Actual tooth: all 3 diverged, but also_names missing → codex absent from output → RED
  MUT_K_OUT="$(bash "$MUT_K" --all --home "$H_BDG3" 2>&1)"
  if ! printf '%s\n' "$MUT_K_OUT" | grep -qF 'codex'; then
    ok "TOOTH K also-diverged-names: mutant hides codex — RED as expected"
  else
    no "TOOTH K also-diverged-names: mutant still shows codex — tooth has no bite"
  fi

  echo "-- teeth: force _vsd_resolve_src to always use the kit source (ignore profile); expect PD1a to fail --"
  # Neuters the profile branch so a NON-claude profile is silently compared against the kit
  # source instead of a fresh render — a general-profile install (which legitimately differs
  # from the kit source) would then be misreported as diverged even when untouched.
  MUT_PD="$MUT_DIR/verify-skill-drift-mut-PD.sh"
  sed 's/if \[ "\$profile" = "claude" \]; then/if true; then/' "$SUT" > "$MUT_PD"
  chmod +x "$MUT_PD"
  # The mini-kit sandbox above never needed a profiles/ dir before (TOOTH A-K don't touch
  # profiles); rsdd_valid_profile needs $ROOT/profiles/general.slots.md to accept "general".
  mkdir -p "$ROOT/profiles"
  cp "$HERE/../../profiles/general.slots.md" "$ROOT/profiles/general.slots.md" 2>/dev/null
  if diff -q "$SUT" "$MUT_PD" >/dev/null 2>&1; then
    no "TOOTH PD pre-check: mutant = SUT — profile branch line not found"
  else
    ok "TOOTH PD pre-check: mutant differs (profile branch forced true)"
  fi
  if [ -f "$INSTALLER_PD" ]; then
    H_PD_TEETH="$ROOT/home_pd_teeth"
    bash "$INSTALLER_PD" --home "$H_PD_TEETH" --harness reasonix >/dev/null 2>&1
    bash "$MUT_PD" --harness reasonix --home "$H_PD_TEETH" >/dev/null 2>&1
    RC_MUT_PD=$?
    if [ "$RC_MUT_PD" -eq 1 ]; then
      ok "TOOTH PD: mutant (profile ignored) reports a fresh general install as diverged — RED as expected"
    else
      no "TOOTH PD: mutant still reports exit $RC_MUT_PD (expected 1) — profile-aware comparison check has no bite"
    fi
  else
    no "TOOTH PD: installer not found — cannot exercise this tooth"
  fi

  # F3-leak/F3-completeness mutants live BESIDE the REAL SUT (never in $MUT_DIR's mini-kit
  # sandbox, which has no render-profile.sh/profiles/): both need an ACTUAL successful render
  # against the REAL kit to reach the code under test, unlike TOOTH PD's mutation above, which
  # takes a fast path that skips rendering entirely.
  echo "-- teeth: disable tmp-dir tracking append; expect F3-leak to fail --"
  MUT_F3LEAK="$HERE/../verify-skill-drift-mut-f3leak.$$.sh"
  sed 's/\[ -n "\$_vsd_tmp" \] && _VSD_RENDER_TMPDIRS+=("\$_vsd_tmp")/false/' "$SUT" > "$MUT_F3LEAK"
  chmod +x "$MUT_F3LEAK"
  if diff -q "$SUT" "$MUT_F3LEAK" >/dev/null 2>&1; then
    no "TOOTH F3-leak pre-check: mutant = SUT — tracking-append line not found"
  else
    ok "TOOTH F3-leak pre-check: mutant differs (tmp-dir tracking disabled)"
  fi
  if [ -f "$INSTALLER_PD" ]; then
    H_TF3L="$ROOT/home_tf3leak"
    bash "$INSTALLER_PD" --home "$H_TF3L" --harness reasonix >/dev/null 2>&1
    MUT_F3LEAK_TMPDIR="$ROOT/mut-f3leak-tmpdir"; mkdir -p "$MUT_F3LEAK_TMPDIR"
    TMPDIR="$MUT_F3LEAK_TMPDIR" bash "$MUT_F3LEAK" --harness reasonix --home "$H_TF3L" >/dev/null 2>&1
    LEFTOVER_TF3L="$(find "$MUT_F3LEAK_TMPDIR" -mindepth 1 -maxdepth 1 2>/dev/null)"
    if [ -n "$LEFTOVER_TF3L" ]; then
      ok "TOOTH F3-leak: mutant (tracking disabled) leaks a tmp dir → F3-leak check has teeth"
    else
      no "TOOTH F3-leak: mutant still cleaned up — F3-leak check is THEATER"
    fi
  else
    no "TOOTH F3-leak: installer not found — cannot exercise this tooth"
  fi
  rm -f "$MUT_F3LEAK"

  echo "-- teeth: force render-completeness to always be accepted (single-harness); expect F3-missing to fail --"
  MUT_F3COMP="$HERE/../verify-skill-drift-mut-f3comp.$$.sh"
  sed 's/if \[ "\$render_state" != "ok" \]; then/if false; then/' "$SUT" > "$MUT_F3COMP"
  chmod +x "$MUT_F3COMP"
  if diff -q "$SUT" "$MUT_F3COMP" >/dev/null 2>&1; then
    no "TOOTH F3-completeness pre-check: mutant = SUT — render_state check line not found"
  else
    ok "TOOTH F3-completeness pre-check: mutant differs (single-harness completeness check disabled)"
  fi
  if [ -f "$INSTALLER_PD" ]; then
    H_TF3C="$ROOT/home_tf3comp"
    bash "$INSTALLER_PD" --home "$H_TF3C" --harness reasonix >/dev/null 2>&1
    rm -rf "$H_TF3C/.reasonix/research-sdd/profile/general"
    RC_TF3C=0
    bash "$MUT_F3COMP" --harness reasonix --home "$H_TF3C" >/dev/null 2>&1 || RC_TF3C=$?
    if [ "$RC_TF3C" -eq 0 ]; then
      ok "TOOTH F3-completeness: mutant (check disabled) reports a missing render dir as in-sync → completeness check has teeth"
    else
      no "TOOTH F3-completeness: mutant still refused (rc=$RC_TF3C) — completeness check is THEATER"
    fi
  else
    no "TOOTH F3-completeness: installer not found — cannot exercise this tooth"
  fi
  rm -f "$MUT_F3COMP"

  # TOOTH SYMLINK-TOOLBELT (kit issue #1024 round 4, MEDIUM). Measured directly (not asserted):
  # reverting ONLY verify-skill-drift.sh's own -P, with render-profile.sh's INDEPENDENT -P fix
  # left in place, no longer manifests an externally observable failure — render-profile.sh's own
  # physical resolution SELF-HEALS through the very symlink verify-skill-drift.sh's broken $KIT
  # constructs (its "$KIT/toolbelt/render-profile.sh" call still reaches the real toolbelt/ via
  # F1's whole-directory completion symlink, and -P there alone is enough to resolve back to the
  # true kit root). That symlink-preserving shape was verified empirically before writing this
  # tooth; a shape that instead replaces the toolbelt/ symlink with a real copied directory
  # reproduces a FAILURE but the WRONG one (loses the self-healing property a real render never
  # loses) — confirmed and discarded rather than kept as an easy but dishonest pass.
  # render-profile.sh has the identical bug class independently (kit issue #1024 round 4,
  # SYSTEMIC — found via the new verify-cd-physical.sh lint) and its OWN isolated tooth lives in
  # render-profile.test.sh (a clean single-mutant case: invoked directly, it never goes through
  # verify-skill-drift.sh's $KIT at all). THIS tooth instead reverts BOTH scripts together — the
  # exact pair that jointly produced kit issue #1024's originally reported symptom — because that
  # combination is what a "SELF_DIR/KIT_INSTALL/KIT -P" reversion of verify-skill-drift.sh ALONE
  # can no longer be shown to break on its own once render-profile.sh's sibling fix stands.
  echo "-- teeth SYMLINK-TOOLBELT: revert -P on verify-skill-drift.sh AND render-profile.sh together --"
  MUT_SYM="$HERE/../verify-skill-drift-mut-sym.$$.sh"
  sed -e 's/SELF_DIR="\$(cd -P "\$(dirname "\$0")" \&\& pwd -P)"/SELF_DIR="$(cd "$(dirname "$0")" \&\& pwd)"/' \
      -e 's/KIT_INSTALL="\$(cd -P "\$SELF_DIR\/\.\.\/install" 2>\/dev\/null \&\& pwd -P)"/KIT_INSTALL="$(cd "$SELF_DIR\/..\/install" 2>\/dev\/null \&\& pwd)"/' \
      -e 's/KIT="\$(cd -P "\$KIT_INSTALL\/\.\." \&\& pwd -P)"/KIT="$(cd "$KIT_INSTALL\/.." \&\& pwd)"/' \
      "$SUT" > "$MUT_SYM"
  chmod +x "$MUT_SYM"
  MUT_RPS="$HERE/../render-profile-mut-sym.$$.sh"
  sed -e 's/HERE="\$(cd -P "\$(dirname "\${BASH_SOURCE\[0\]}")" \&\& pwd -P)"/HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" \&\& pwd)"/' \
      -e 's/KIT_DIR="\${RSDD_KIT_DIR:-\$(cd -P "\$HERE\/\.\." \&\& pwd -P)}"/KIT_DIR="${RSDD_KIT_DIR:-$(cd "$HERE\/.." \&\& pwd)}"/' \
      "$KIT/toolbelt/render-profile.sh" > "$MUT_RPS"
  chmod +x "$MUT_RPS"
  if diff -q "$SUT" "$MUT_SYM" >/dev/null 2>&1; then
    no "teeth SYMLINK-TOOLBELT pre-check: verify-skill-drift.sh mutant = SUT — -P pattern not found (did the fix change shape?)"
  else
    ok "teeth SYMLINK-TOOLBELT pre-check: verify-skill-drift.sh mutant differs (-P reverted on all 3 hops)"
  fi
  if diff -q "$KIT/toolbelt/render-profile.sh" "$MUT_RPS" >/dev/null 2>&1; then
    no "teeth SYMLINK-TOOLBELT pre-check: render-profile.sh mutant = SUT — -P pattern not found (did the fix change shape?)"
  else
    ok "teeth SYMLINK-TOOLBELT pre-check: render-profile.sh mutant differs (-P reverted on both hops)"
  fi

  # Build a fully SYNTHETIC mini-kit (mktemp -d) — never a real render, whose toolbelt/ IS the
  # real tracked toolbelt/ via F1's completion symlink; writing a mutant through that path would
  # corrupt the live scripts (the exact mistake already made once in round 3, caught via an
  # unexpected diff before commit). toolbelt/install/profiles stay genuine SYMLINKS from the
  # render dir to this mini-kit's own copies — matching the real F1 shape exactly (a real,
  # non-symlinked toolbelt/ directly under the render dir would ALSO "fail", but for the wrong
  # reason: it discards the self-healing property a real render never loses, not the class of bug
  # kit issue #1024 is about).
  SCRATCH_TSYM="$ROOT/scratch_teeth_symlink"
  mkdir -p "$SCRATCH_TSYM/research-sdd/toolbelt" "$SCRATCH_TSYM/research-sdd/install" \
    "$SCRATCH_TSYM/research-sdd/profiles" "$SCRATCH_TSYM/research-sdd/skills/research-sdd"
  cp "$KIT/toolbelt/verify-skill-drift.sh" "$SCRATCH_TSYM/research-sdd/toolbelt/verify-skill-drift.sh"
  cp "$KIT/toolbelt/render-profile.sh"     "$SCRATCH_TSYM/research-sdd/toolbelt/render-profile.sh"
  chmod +x "$SCRATCH_TSYM/research-sdd/toolbelt/verify-skill-drift.sh" \
           "$SCRATCH_TSYM/research-sdd/toolbelt/render-profile.sh"
  cp "$KIT/install/adapters.sh" "$SCRATCH_TSYM/research-sdd/install/adapters.sh"
  cp "$KIT/profiles/general.slots.md" "$SCRATCH_TSYM/research-sdd/profiles/general.slots.md"
  cp "$KIT/skills/research-sdd/SKILL.md" "$SCRATCH_TSYM/research-sdd/skills/research-sdd/SKILL.md"
  cp "$KIT/PROMPT-LOOP.md" "$SCRATCH_TSYM/research-sdd/PROMPT-LOOP.md"
  cp "$KIT/METHODOLOGY.md" "$SCRATCH_TSYM/research-sdd/METHODOLOGY.md"
  mkdir -p "$SCRATCH_TSYM/render/profile/general"
  ln -s "$SCRATCH_TSYM/research-sdd/toolbelt"  "$SCRATCH_TSYM/render/profile/general/toolbelt"
  ln -s "$SCRATCH_TSYM/research-sdd/install"   "$SCRATCH_TSYM/render/profile/general/install"
  ln -s "$SCRATCH_TSYM/research-sdd/profiles"  "$SCRATCH_TSYM/render/profile/general/profiles"

  # Bootstrap a GENUINE render at the render dir's root using the real (fixed) render-profile.sh —
  # exactly what a real install's render step produces — BEFORE swapping the mutants in. Without
  # this, "zero slot markers" cannot reproduce: there would be no already-rendered file for the
  # broken KIT_DIR to find, and the mutant would instead fail with an unrelated "source not found".
  bash "$SCRATCH_TSYM/research-sdd/toolbelt/render-profile.sh" general "$SCRATCH_TSYM/render/profile/general" >/dev/null 2>&1

  H_TSYM="$ROOT/home_teeth_symlink"
  mkdir -p "$H_TSYM"

  # Now swap BOTH mutants in, in place of the mini-kit's own (fixed) copies — the render dir's
  # toolbelt/ symlink keeps pointing at this same directory, so it picks up the mutants too.
  cp "$MUT_SYM" "$SCRATCH_TSYM/research-sdd/toolbelt/verify-skill-drift.sh"
  cp "$MUT_RPS" "$SCRATCH_TSYM/research-sdd/toolbelt/render-profile.sh"
  chmod +x "$SCRATCH_TSYM/research-sdd/toolbelt/verify-skill-drift.sh" \
           "$SCRATCH_TSYM/research-sdd/toolbelt/render-profile.sh"

  OUT_TSYM="$(bash "$SCRATCH_TSYM/render/profile/general/toolbelt/verify-skill-drift.sh" \
    --harness reasonix --home "$H_TSYM" --profile general 2>&1)"; RC_TSYM=$?
  if [ "$RC_TSYM" -eq 2 ] && printf '%s' "$OUT_TSYM" | grep -qi 'zero slot markers'; then
    ok "teeth SYMLINK-TOOLBELT: both mutants together re-break through a symlinked toolbelt/ (zero slot markers, rc=2) → the -P fix pair has teeth"
  else
    no "teeth SYMLINK-TOOLBELT: mutants did not re-break — -P fix check is THEATER (rc=$RC_TSYM out=[$OUT_TSYM])"
  fi
  rm -f "$MUT_SYM" "$MUT_RPS"

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

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
#   K  also-diverged-names   mutant replaces the SENTINEL-ALSO-DIVERGED accumulator with a no-op (':'; deleting it
#                            would leave an empty else = bash syntax error) → REM1 loses harness names (RED)
# Mutants are built through tests/lib/mutant.sh inside a staged mini-kit sandbox under $ROOT (never the
# live tree); verified by git-status before/after.
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

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
# Every hook copy below lives directly under $ROOT and sources lib/hook-emit.sh beside itself (#1877).
mkdir -p "$ROOT/lib" && cp "$HERE/../lib/hook-emit.sh" "$ROOT/lib/hook-emit.sh"
# The hook also calls research-sdd-install.sh --verify (W1). These cases pin the SKILL.md-drift half only,
# so pin that call to a silent stub: never the real install against the operator's real $HOME. The
# install --verify half has its own suite: verify-skill-drift-hook.test.sh.
printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/silent-install-verify.sh"; chmod +x "$ROOT/silent-install-verify.sh"
export RESEARCH_SDD_INSTALL_VERIFY_CMD="$ROOT/silent-install-verify.sh"
pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP  %s\n' "$1"; }

# The real kit path from this test's location
KIT="$(cd "$HERE/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
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
if <<<"$OUT_STDERR" grep -q 'absent'; then
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
if <<<"$HOOK_OUT2" grep -q 'force-skill'; then
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
#   H_ALL: claude in-sync, gentle-shell absent, pi diverged (middle of the list; the
#   LAST-position drift case — gentle-shell — is covered by PIH4/TOOTH D)
H_ALL="$ROOT/home_all"
mkdir -p "$H_ALL/.claude/skills/research-sdd"
cp "$SRC_SKILL" "$H_ALL/.claude/skills/research-sdd/SKILL.md"      # claude: in-sync
mkdir -p "$H_ALL/.pi/agent/skills/research-sdd"
printf 'stale content — not matching kit\n' > "$H_ALL/.pi/agent/skills/research-sdd/SKILL.md"  # pi: diverged
# gentle-shell (.gentle-shell) not created → absent

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
if <<<"$ERR_AN2" grep -q 'fix:.*--harness pi.*--force-skill'; then
  ok "AN2 --all diverged → fix command for pi in stderr"
else
  no "AN2 --all diverged → expected fix command; got: $ERR_AN2"
fi

# AN3: --all diverged → summary shows diverged=1
if <<<"$ERR_AN2" grep -q 'diverged=1'; then
  ok "AN3 --all diverged → summary diverged=1"
else
  no "AN3 --all diverged → expected 'diverged=1' in summary; got: $ERR_AN2"
fi

# AN4: --all diverged → summary shows absent=1 (gentle-shell not installed)
if <<<"$ERR_AN2" grep -q 'absent=1'; then
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
# Only claude is installed; pi/gentle-shell absent
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

# Test AN-hook-2: hook --all diverged (pi diverged) → fix command in output
H_DIV_ALL="$ROOT/home_div_all"
mkdir -p "$H_DIV_ALL/.claude/skills/research-sdd"
cp "$SRC_SKILL" "$H_DIV_ALL/.claude/skills/research-sdd/SKILL.md"     # claude in-sync
mkdir -p "$H_DIV_ALL/.pi/agent/skills/research-sdd"
printf 'diverged\n' > "$H_DIV_ALL/.pi/agent/skills/research-sdd/SKILL.md"  # pi diverged
HOOK_PATCHED2_ALL="$ROOT/hook-test2-all.sh"
sed 's|"$here/verify-skill-drift.sh" --all|"'"$SUT"'" --all --home "'"$H_DIV_ALL"'"|' \
  "$HOOK_SUT" > "$HOOK_PATCHED2_ALL"
chmod +x "$HOOK_PATCHED2_ALL"
HOOK_OUT2_ALL="$(bash "$HOOK_PATCHED2_ALL" 2>&1)"
if <<<"$HOOK_OUT2_ALL" grep -q 'force-skill'; then
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
if [ "$RC_AX6" -eq 2 ] && <<<"$AX6_ERR" grep -q 'could-not-run.*HOME'; then
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
if <<<"$AX7_OUT" grep -qi 'ERROR'; then
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
mkdir -p "$H_BDG3/.pi/agent/skills/research-sdd"
printf '# stale pi\n' > "$H_BDG3/.pi/agent/skills/research-sdd/SKILL.md"
mkdir -p "$H_BDG3/.gentle-shell/agent/skills/research-sdd"
printf '# stale gentle-shell\n' > "$H_BDG3/.gentle-shell/agent/skills/research-sdd/SKILL.md"
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
# the detailed fix line, pi/gentle-shell must appear in "also diverged" line.
REM1_OUT="$(bash "$SUT" --all --home "$H_BDG3" 2>&1)"
if <<<"$REM1_OUT" grep -qF 'claude' && \
   <<<"$REM1_OUT" grep -qE 'also diverged: .*\bpi\b' && \
   <<<"$REM1_OUT" grep -qF 'gentle-shell'; then
  ok "REM1 3-diverged → all harness names appear in output"
else
  no "REM1 3-diverged → some harness names missing from output: $REM1_OUT"
fi

# ── PD: profile-aware drift detection (kit issue #993 WU2) ────────────────────
# PD1: install "general" for pi (its per-harness default — adapters.sh _RSDD_DEFAULT_PROFILE)
#      with the REAL installer, then verify-skill-drift re-renders that SAME profile into a
#      throwaway temp dir and compares against it: in-sync on the untouched install, diverged
#      after a hand-edit. Exercises the real render-profile.sh end-to-end, never a mutant.
INSTALLER_PD="$KIT/install/research-sdd-install.sh"
if [ ! -f "$INSTALLER_PD" ]; then
  no "PD1 setup: installer not found: $INSTALLER_PD"
else
  H_PD1="$ROOT/home_pd1"
  bash "$INSTALLER_PD" --home "$H_PD1" --harness pi >/dev/null 2>&1
  DEPLOYED_PD1="$H_PD1/.pi/agent/skills/research-sdd/SKILL.md"
  if [ ! -f "$DEPLOYED_PD1" ]; then
    no "PD1 setup: install did not produce a deployed skill at $DEPLOYED_PD1"
  else
    bash "$SUT" --harness pi --home "$H_PD1" >/dev/null 2>&1
    RC_PD1_SYNC=$?
    if [ "$RC_PD1_SYNC" -eq 0 ]; then
      ok "PD1a: fresh general-profile install is in-sync (exit 0)"
    else
      no "PD1a: fresh general-profile install reported drift (exit $RC_PD1_SYNC) — expected in-sync"
    fi

    printf '\n<!-- hand-edited by an operator -->\n' >> "$DEPLOYED_PD1"
    ERR_PD1_DIV="$(bash "$SUT" --harness pi --home "$H_PD1" 2>&1)"
    RC_PD1_DIV=$?
    if [ "$RC_PD1_DIV" -eq 1 ] && <<<"$ERR_PD1_DIV" grep -q 'diverged'; then
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
if [ "$RC_PD3" -eq 2 ] && <<<"$ERR_PD3" grep -qi 'unknown profile'; then
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
# found in sources" — exit 2 (could-not-run) for every pi/general check, every time, single-
# harness AND --all. This uses the REAL installer against a REAL kit (the established TOOTH-PD
# pattern above — this script's own resolution chain needs a REAL render-profile.sh, REAL
# profiles/*.slots.md and REAL slot-marker-bearing sources to reach the exact failure mode; a
# synthetic mini-kit would have to reimplement render-profile.sh's own behaviour to reproduce it),
# with only a THROWAWAY --home — never the real fleet, never real ~/.claude/~/.pi config.
if [ -f "$INSTALLER_PD" ]; then
  H_SYM="$ROOT/home_symlink_toolbelt"
  bash "$INSTALLER_PD" --home "$H_SYM" --harness pi >/dev/null 2>&1
  RENDER_TB_SYM="$H_SYM/.pi/agent/research-sdd/profile/general/toolbelt/verify-skill-drift.sh"
  if [ -x "$RENDER_TB_SYM" ]; then
    OUT_SYM_SINGLE="$(bash "$RENDER_TB_SYM" --harness pi --home "$H_SYM" 2>&1)"; RC_SYM_SINGLE=$?
    OUT_SYM_ALL="$(bash "$RENDER_TB_SYM" --all --home "$H_SYM" 2>&1)"; RC_SYM_ALL=$?
    if [ "$RC_SYM_SINGLE" -eq 0 ] && [ "$RC_SYM_ALL" -eq 0 ] \
       && ! <<<"$OUT_SYM_SINGLE$OUT_SYM_ALL" grep -qi 'zero slot markers'; then
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
  bash "$INSTALLER_PD" --home "$H_F3LEAK" --harness pi >/dev/null 2>&1
  F3_TMPDIR="$ROOT/f3-dedicated-tmpdir"; mkdir -p "$F3_TMPDIR"
  TMPDIR="$F3_TMPDIR" bash "$SUT" --harness pi --home "$H_F3LEAK" >/dev/null 2>&1
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
  bash "$INSTALLER_PD" --home "$H_F3MISS" --harness pi >/dev/null 2>&1
  rm -rf "$H_F3MISS/.pi/agent/research-sdd/profile/general"
  ERR_F3MISS="$(bash "$SUT" --harness pi --home "$H_F3MISS" 2>&1)"; RC_F3MISS=$?
  if [ "$RC_F3MISS" -eq 2 ] && <<<"$ERR_F3MISS" grep -qi 'render dir missing'; then
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
  bash "$INSTALLER_PD" --home "$H_F3HE" --harness pi >/dev/null 2>&1
  echo "tampered" >> "$H_F3HE/.pi/agent/research-sdd/profile/general/PROMPT-LOOP.md"
  ERR_F3HE="$(bash "$SUT" --harness pi --home "$H_F3HE" 2>&1)"; RC_F3HE=$?
  if [ "$RC_F3HE" -eq 2 ] && <<<"$ERR_F3HE" grep -qi 'render dir diverged'; then
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

# Mutation-control helpers: sourced on the --prove-teeth path only. mk/tt count a refused build or
# a failed tooth exactly ONCE (the helper prints its own FAIL line; a refused build never runs its tooth).
if [ "$prove_teeth" -eq 1 ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  for _fn in mutant_chain mutant_tooth; do
    declare -F "$_fn" >/dev/null || { echo "FATAL: lib/mutant.sh did not define $_fn" >&2; exit 2; }
  done
  mk()  { mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  tt()  { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
fi

# ── PIH: pi + gentle-shell harnesses are registered and drift-checked (general profile) ──────────
# Both default to the "general" profile, deploy under <home>/.pi/agent and <home>/.gentle-shell/agent,
# and gentle-shell is the LAST registered harness (list-edge rule: drift in the last position must
# still be reported). Real installer + real render-profile.sh, never a mutant.
if [ ! -f "$INSTALLER_PD" ]; then
  no "PIH setup: installer not found: $INSTALLER_PD"
else
  H_PIH="$ROOT/home_pih"
  bash "$INSTALLER_PD" --home "$H_PIH" --harness pi >/dev/null 2>&1
  bash "$INSTALLER_PD" --home "$H_PIH" --harness gentle-shell >/dev/null 2>&1
  for _h in pi gentle-shell; do
    case "$_h" in pi) _rel=".pi/agent" ;; *) _rel=".gentle-shell/agent" ;; esac
    bash "$SUT" --harness "$_h" --home "$H_PIH" >/dev/null 2>&1; _rc=$?
    if [ "$_rc" -eq 0 ]; then ok "PIH1 $_h: fresh general-profile install is in-sync (exit 0)"
    else no "PIH1 $_h: fresh install reported rc=$_rc (expected 0)"; fi
    [ -f "$H_PIH/$_rel/skills/research-sdd/SKILL.md" ] \
      && ok "PIH2 $_h: deployed skill lives at <home>/$_rel/skills/research-sdd/SKILL.md" \
      || no "PIH2 $_h: no deployed skill at <home>/$_rel"
  done
  bash "$SUT" --all --home "$H_PIH" >/dev/null 2>&1; _rc=$?
  [ "$_rc" -eq 0 ] && ok "PIH3 --all: pi and gentle-shell both in-sync (exit 0)" || no "PIH3 --all: expected exit 0, got $_rc"
  printf '\n<!-- hand-edited -->\n' >> "$H_PIH/.gentle-shell/agent/skills/research-sdd/SKILL.md"
  _err="$(bash "$SUT" --all --home "$H_PIH" 2>&1 >/dev/null)"; _rc=$?
  if [ "$_rc" -eq 1 ] && <<<"$_err" grep -q 'fix:.*--harness gentle-shell.*--force-skill'; then
    ok "PIH4 --all: drift in the LAST registered harness (gentle-shell) is reported with its fix command"
  else no "PIH4 --all: gentle-shell drift missed (rc=$_rc, err=$_err)"; fi
  printf '\n<!-- hand-edited -->\n' >> "$H_PIH/.pi/agent/skills/research-sdd/SKILL.md"
  _err="$(bash "$SUT" --all --home "$H_PIH" 2>&1 >/dev/null)"
  if <<<"$_err" grep -q 'diverged=2'; then ok "PIH5 --all: pi + gentle-shell both diverged → diverged=2"
  else no "PIH5 --all: expected diverged=2 (err=$_err)"; fi

  if [ "$prove_teeth" -eq 1 ]; then
    # Tooth: a sandbox kit whose adapters.sh DROPS gentle-shell from RESEARCH_SDD_HARNESSES must NOT
    # report the gentle-shell drift PIH4 detects (rc 0, name absent) — so PIH4 depends on registration.
    # The mutated file is adapters.sh (built from the live one into the temp sandbox through the
    # helper). BOTH sides run from sandboxes with an identical layout: PIO (pristine adapters.sh, the
    # original) and PIK (mutated adapters.sh), each with a byte-identical SUT copy and SKILL.md, so
    # adapters.sh is the ONLY difference between the two runs.
    PIK="$ROOT/pikit"; PIO="$ROOT/pikit-orig"
    mkdir -p "$PIK/install" "$PIK/toolbelt" "$PIK/skills/research-sdd" \
             "$PIO/install" "$PIO/toolbelt" "$PIO/skills/research-sdd"
    for _d in "$PIK" "$PIO"; do
      cp "$SUT" "$_d/toolbelt/verify-skill-drift.sh"
      cp "$SRC_SKILL" "$_d/skills/research-sdd/SKILL.md"
      # gentle-shell defaults to the "general" profile: the original must be able to re-render it.
      mkdir -p "$_d/profiles"
      cp "$KIT/toolbelt/render-profile.sh" "$_d/toolbelt/render-profile.sh"
      cp "$KIT/profiles/general.slots.md" "$_d/profiles/general.slots.md"
      cp "$KIT/PROMPT-LOOP.md" "$KIT/METHODOLOGY.md" "$_d/"
    done
    cp "$HERE/../../install/adapters.sh" "$PIO/install/adapters.sh"
    if ! cmp -s "$PIO/install/adapters.sh" "$HERE/../../install/adapters.sh"; then
      no "teeth PIH staging: pristine sandbox adapters.sh is not byte-identical to the live one"
    elif mk "teeth PIH harness-dropped" "$HERE/../../install/adapters.sh" "$PIK/install/adapters.sh" \
         's/^RESEARCH_SDD_HARNESSES="\(.*\) gentle-shell"/RESEARCH_SDD_HARNESSES="\1"/'; then
      H_PIT="$ROOT/home_pit"; mkdir -p "$H_PIT/.gentle-shell/agent/skills/research-sdd"
      printf 'stale\n' > "$H_PIT/.gentle-shell/agent/skills/research-sdd/SKILL.md"
      # GOOD_RC 1 (original reports the stale gentle-shell) / BAD_RC 0 (registration dropped → silent).
      tt "teeth PIH" 1 0 "$PIK/toolbelt/verify-skill-drift.sh" --orig "$PIO/toolbelt/verify-skill-drift.sh" \
        --good-has '^verify-skill-drift: fix: .*--harness gentle-shell ' --bad-lacks 'gentle-shell' \
        -- bash @SUT@ --all --home "$H_PIT"
    fi
  fi
fi

# SENTINEL-TEETH-BANNER-START
if [ "$prove_teeth" -eq 1 ]; then
  echo "-- mutation teeth --"

  # Mini-kit sandbox. The SUT resolves everything relative to its OWN path (SELF_DIR →
  # ../install/adapters.sh, KIT = the dir above install/, then $KIT/skills, $KIT/profiles,
  # $KIT/toolbelt/render-profile.sh, $KIT/PROMPT-LOOP.md, $KIT/METHODOLOGY.md), so a mutant must sit
  # beside those files — but lib/mutant.sh refuses any mutant written into the live tree. Both are
  # satisfied by staging exactly those files in a temp dir ($ROOT, a mktemp dir that the EXIT trap
  # removes) and building every mutant inside it. The ORIGINAL is staged there too (a byte-identical
  # copy of the SUT), so original and mutant run from equivalent sandboxes — the comparison never
  # depends on the live tree. Layout: $ROOT/toolbelt/ (SUT copy, render-profile.sh, mutants) +
  # $ROOT/install/ + $ROOT/skills/ + $ROOT/profiles/ + $ROOT/PROMPT-LOOP.md + $ROOT/METHODOLOGY.md.
  mkdir -p "$ROOT/install" "$ROOT/skills/research-sdd" "$ROOT/toolbelt" "$ROOT/profiles"
  MUT_DIR="$ROOT/toolbelt"
  SBX_ORIG="$MUT_DIR/verify-skill-drift.sh"
  # stage_file LIVE_ABS SANDBOX_REL — copy one live file into the sandbox.
  stage_file() { cp "$1" "$ROOT/$2" 2>/dev/null; }
  stage_file "$SUT"                           toolbelt/verify-skill-drift.sh
  stage_file "$KIT/toolbelt/render-profile.sh" toolbelt/render-profile.sh
  stage_file "$KIT/install/adapters.sh"       install/adapters.sh
  stage_file "$KIT/profiles/general.slots.md" profiles/general.slots.md
  stage_file "$SRC_SKILL"                     skills/research-sdd/SKILL.md
  stage_file "$KIT/PROMPT-LOOP.md"            PROMPT-LOOP.md
  stage_file "$KIT/METHODOLOGY.md"            METHODOLOGY.md
  chmod +x "$SBX_ORIG" "$MUT_DIR/render-profile.sh" 2>/dev/null
  # Staging check: every file the SUT (and the render-profile.sh it calls) resolves relative to its
  # own path must be present in the sandbox AND byte-identical to its live counterpart. A missing or
  # drifted file fails loudly ONCE and the sandbox teeth are skipped, so a half-staged sandbox can
  # never turn a crash into a "bite".
  STAGE_OK=1
  for _pair in "$SUT:toolbelt/verify-skill-drift.sh" \
               "$KIT/toolbelt/render-profile.sh:toolbelt/render-profile.sh" \
               "$KIT/install/adapters.sh:install/adapters.sh" \
               "$KIT/profiles/general.slots.md:profiles/general.slots.md" \
               "$SRC_SKILL:skills/research-sdd/SKILL.md" \
               "$KIT/PROMPT-LOOP.md:PROMPT-LOOP.md" \
               "$KIT/METHODOLOGY.md:METHODOLOGY.md"; do
    _live="${_pair%%:*}"; _rel="${_pair#*:}"
    if [ ! -s "$_live" ] || [ ! -s "$ROOT/$_rel" ] || ! cmp -s "$_live" "$ROOT/$_rel"; then
      no "TEETH staging: sandbox file '$_rel' missing, empty or not byte-identical to '$_live' — mini-kit sandbox incomplete"
      STAGE_OK=0
    fi
  done
  [ "$STAGE_OK" -eq 1 ] && ok "TEETH staging: mini-kit sandbox complete (SUT copy, render-profile.sh, adapters.sh, profile slots, SKILL.md, PROMPT-LOOP.md, METHODOLOGY.md byte-identical to live)"

  # git-status snapshot before any mutant creation (proves no live-tree leakage after)
  _GIT_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
  _GIT_BEFORE="$(git -C "$_GIT_ROOT" status --porcelain 2>/dev/null || true)"

  if [ "$STAGE_OK" -eq 1 ]; then
    # Positional codes of every tt call below: LABEL GOOD_RC BAD_RC MUTANT [opts] -- ARGV, where
    # GOOD_RC is the exact exit code of the ORIGINAL (--orig, the sandbox copy) and BAD_RC the exact
    # exit code of the MUTANT. A mutant that crashes or exits with any other code is theater, not teeth.

    # TOOTH A: in-sync-not-silent — mutant disables the cmp-s in-sync guard.
    # Real test 6: in-sync → exit 0 + silent. Mutant: in-sync → falls through to diverged → exit 1.
    H_TA="$ROOT/home_ta"
    make_home_copy "$H_TA" "$SRC_SKILL"
    MUT_A="$MUT_DIR/verify-skill-drift-mut-A.sh"
    if mk "TOOTH A in-sync-not-silent" "$SUT" "$MUT_A" 's/if cmp -s "\$src" "\$deployed"; then/if false; then/'; then
      ok "TOOTH A pre-check: mutant built (cmp-s guard disabled)"
      tt "TOOTH A in-sync-not-silent" 0 1 "$MUT_A" --orig "$SBX_ORIG" \
        --good-lacks '.' --bad-has '^verify-skill-drift: diverged harness=claude ' \
        -- bash @SUT@ --harness claude --home "$H_TA"
    fi

    # TOOTH B: diverged-silent — mutant replaces the final bare 'exit 1' (diverged) with 'exit 0'.
    # Real test 7: diverged → exit 1. Mutant: diverged → exit 0.
    H_TB="$ROOT/home_tb"
    make_home_stale "$H_TB" "# diverged content"
    MUT_B="$MUT_DIR/verify-skill-drift-mut-B.sh"
    if mk "TOOTH B diverged-silent" "$SUT" "$MUT_B" 's/^exit 1$/exit 0/'; then
      ok "TOOTH B pre-check: mutant built (diverged exit 1 → exit 0)"
      tt "TOOTH B diverged-silent" 1 0 "$MUT_B" --orig "$SBX_ORIG" \
        --good-has '^verify-skill-drift: diverged harness=claude ' \
        -- bash @SUT@ --harness claude --home "$H_TB"
    fi

    # TOOTH C: absent-confused — mutant replaces 'exit 3' in the absent block with 'exit 0'.
    # Real test 8: absent → exit 3. Mutant: absent → exit 0 (indistinguishable from in-sync).
    H_TC="$ROOT/home_tc"
    mkdir -p "$H_TC/.claude"
    MUT_C="$MUT_DIR/verify-skill-drift-mut-C.sh"
    if mk "TOOTH C absent-confused" "$SUT" "$MUT_C" 's/^  exit 3$/  exit 0/'; then
      ok "TOOTH C pre-check: mutant built (absent exit 3 → exit 0)"
      tt "TOOTH C absent-confused" 3 0 "$MUT_C" --orig "$SBX_ORIG" \
        --good-has '^verify-skill-drift: absent harness=claude ' \
        -- bash @SUT@ --harness claude --home "$H_TC"
    fi

    # TOOTH D: all-last-skipped — mutant iterates all-but-last of RESEARCH_SDD_HARNESSES.
    # Real test PIH4: gentle-shell (last in RESEARCH_SDD_HARNESSES) diverged → exit 1.
    # Mutant: the loop misses gentle-shell → exit 0.
    H_TD="$ROOT/home_td"
    mkdir -p "$H_TD/.claude/skills/research-sdd"
    cp "$SRC_SKILL" "$H_TD/.claude/skills/research-sdd/SKILL.md"
    mkdir -p "$H_TD/.gentle-shell/agent/skills/research-sdd"
    printf 'stale content\n' > "$H_TD/.gentle-shell/agent/skills/research-sdd/SKILL.md"
    MUT_D="$MUT_DIR/verify-skill-drift-mut-D.sh"
    _TD_EXPR='s/for h in \$RESEARCH_SDD_HARNESSES; do/for h in ${RESEARCH_SDD_HARNESSES% *}; do/'
    # Sabotage check: if the sentinel were renamed the sed would match nothing; the helper must then
    # refuse the build with its dead-stage code (10) instead of handing back an unchanged mutant.
    mkdir -p "$ROOT/sab"
    SUT_SAB="$ROOT/sab/sut-sabotaged-D.sh"
    sed 's/for h in \$RESEARCH_SDD_HARNESSES; do/for hh in $RESEARCH_SDD_HARNESSES; do/' "$SUT" > "$SUT_SAB"
    mutant_chain "TOOTH D sabotage" "$SUT_SAB" "$ROOT/sab/mut-D-sabotaged.sh" "$_TD_EXPR" >/dev/null 2>&1; _rc_sab=$?
    MUTANT_CHAIN_DEAD_STAGE=10   # mutant_chain's documented return code for a sed stage that matches nothing
    if [ "$_rc_sab" -eq "$MUTANT_CHAIN_DEAD_STAGE" ]; then
      ok "TOOTH D sabotage: renamed sentinel → mutant_chain refuses (dead stage, rc $MUTANT_CHAIN_DEAD_STAGE) → tooth would report failure"
    else
      no "TOOTH D sabotage: renamed sentinel → expected mutant_chain rc $MUTANT_CHAIN_DEAD_STAGE (dead stage); got rc=$_rc_sab"
    fi
    if mk "TOOTH D all-last-skipped" "$SUT" "$MUT_D" "$_TD_EXPR"; then
      ok "TOOTH D pre-check: mutant built (loop skips last harness)"
      tt "TOOTH D all-last-skipped" 1 0 "$MUT_D" --orig "$SBX_ORIG" \
        --good-has '^verify-skill-drift: fix: .*--harness gentle-shell ' --bad-lacks 'gentle-shell' \
        -- bash @SUT@ --all --home "$H_TD"
    fi

    # TOOTH E: fixture-src — hardcoded src_relkit=source_a for all → harness_b in-sync falsely diverged.
    # Proves SENTINEL-SRC-RELKIT-LOOKUP is actually used (not hardcoded).
    # Uses the two-src-kit (already built above): harness_a→source_a, harness_b→source_b.
    # The mutant MUST live in $TWO_KIT/toolbelt/ so its SELF_DIR resolves to the two-src adapters
    # (not the real kit adapters, which would fail to find skills/source_{a,b}/SKILL.md). It is built
    # FROM the live SUT (byte-identical to SUT_SRC, the two-src original) into that temp dir.
    MUT_E="$TWO_KIT/toolbelt/verify-skill-drift-mut-E.sh"
    if ! cmp -s "$SUT_SRC" "$SUT"; then
      no "TOOTH E staging: two-src original '$SUT_SRC' is not byte-identical to the live SUT — mutant/original mismatch, tooth skipped"
    elif mk "TOOTH E fixture-src" "$SUT" "$MUT_E" \
         's/src_relkit="\$(rsdd_field "\$h" skill_src_relkit "\$home")"/src_relkit="skills\/source_a\/SKILL.md"/'; then
      ok "TOOTH E pre-check: mutant built (skill_src_relkit lookup hardcoded to source_a)"
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
      # Actual tooth: SRC1 home (harness_b deployed=source_b) → original in-sync (0); mutant compares
      # harness_b against source_a → diverged → exit 1 with harness_b's fix line.
      tt "TOOTH E fixture-src" 0 1 "$MUT_E" --orig "$SUT_SRC" \
        --good-lacks '.' --bad-has '^verify-skill-drift: fix: .*--harness harness_b ' \
        -- bash @SUT@ --all --home "$H_SRC1"
    fi

    # TOOTH F: dangling-symlink-single — remove the SENTINEL-DANGLING-SINGLE block (sentinel + 4 lines).
    # Real test AX1: dangling symlink single → exit 2. Mutant: falls through to the absent path → exit 3.
    MUT_F="$MUT_DIR/verify-skill-drift-mut-F.sh"
    if mk "TOOTH F dangling-symlink-single" "$SUT" "$MUT_F" '/# SENTINEL-DANGLING-SINGLE/{N;N;N;N;d}'; then
      ok "TOOTH F pre-check: mutant built (SENTINEL-DANGLING-SINGLE removed)"
      tt "TOOTH F dangling-symlink-single" 2 3 "$MUT_F" --orig "$SBX_ORIG" \
        --good-has 'could-not-run harness=claude \(dangling symlink' \
        --bad-has '^verify-skill-drift: absent harness=claude ' \
        -- bash @SUT@ --harness claude --home "$H_AX1"
    fi

    # TOOTH G: dangling-symlink-all — remove the SENTINEL-DANGLING-ALL block (sentinel + 5 lines).
    # Real test AX2: dangling symlink --all → exit 2. Mutant: counted as absent → exit 0.
    MUT_G="$MUT_DIR/verify-skill-drift-mut-G.sh"
    if mk "TOOTH G dangling-symlink-all" "$SUT" "$MUT_G" '/# SENTINEL-DANGLING-ALL/{N;N;N;N;N;d}'; then
      ok "TOOTH G pre-check: mutant built (SENTINEL-DANGLING-ALL removed)"
      tt "TOOTH G dangling-symlink-all" 2 0 "$MUT_G" --orig "$SBX_ORIG" \
        --good-has 'could-not-run harness=claude \(dangling symlink' --bad-lacks 'could-not-run' \
        -- bash @SUT@ --all --home "$H_AX2"
    fi

    # TOOTH H: HOME-check-deleted — remove the SENTINEL-HOME-CHECK block (sentinel + 4 lines).
    # Real test AX6: HOME unset → exit 2 + typed message. Mutant: home="" resolves under "" → absent → exit 3.
    MUT_H="$MUT_DIR/verify-skill-drift-mut-H.sh"
    if mk "TOOTH H HOME-check-deleted" "$SUT" "$MUT_H" '/# SENTINEL-HOME-CHECK/{N;N;N;N;d}'; then
      ok "TOOTH H pre-check: mutant built (SENTINEL-HOME-CHECK removed)"
      tt "TOOTH H HOME-check-deleted" 2 3 "$MUT_H" --orig "$SBX_ORIG" \
        --good-has '^verify-skill-drift: could-not-run: HOME is unset' \
        --bad-has '^verify-skill-drift: absent harness=claude ' \
        -- env -u HOME bash @SUT@
    fi

    # TOOTH I: unconditional-summary — make the SENTINEL-SUMMARY-GUARD condition always true.
    # Real test AX5: --all in-sync → empty output. Mutant: the summary always prints → non-empty.
    MUT_I="$MUT_DIR/verify-skill-drift-mut-I.sh"
    if mk "TOOTH I unconditional-summary" "$SUT" "$MUT_I" '/# SENTINEL-SUMMARY-GUARD/{n; s/if \[ .* -gt 0 .*/if true; then/}'; then
      ok "TOOTH I pre-check: mutant built (SENTINEL-SUMMARY-GUARD condition forced true)"
      # The bad-side anchor pins only what the mutation flips (a summary line exists on a clean run, with
      # diverged=0 and could-not-run=0); the harness counts are wildcards so the tooth is not coupled to
      # how many harnesses adapters.sh registers.
      tt "TOOTH I unconditional-summary" 0 0 "$MUT_I" --orig "$SBX_ORIG" \
        --good-lacks '.' --bad-has '^verify-skill-drift: all: checked=[0-9]+ in-sync=[0-9]+ diverged=0 absent=[0-9]+ could-not-run=0$' \
        -- bash @SUT@ --all --home "$H_ALL_SYNC"
    fi

    # TOOTH J: drop-all-err-exit2 — remove the SENTINEL-ERR-EXIT2 block (sentinel + 1 line).
    # Real test AX2: dangling symlink --all → exit 2 (err_count=1, no diverged → exits via the err guard).
    # Mutant: err guard deleted → exit 0 (the summary still reports could-not-run=1).
    MUT_J="$MUT_DIR/verify-skill-drift-mut-J.sh"
    if mk "TOOTH J drop-all-err-exit2" "$SUT" "$MUT_J" '/# SENTINEL-ERR-EXIT2/{N;d}'; then
      ok "TOOTH J pre-check: mutant built (SENTINEL-ERR-EXIT2 removed)"
      tt "TOOTH J drop-all-err-exit2" 2 0 "$MUT_J" --orig "$SBX_ORIG" \
        --good-has 'could-not-run=1$' --bad-has '^verify-skill-drift: all: .*could-not-run=1$' \
        -- bash @SUT@ --all --home "$H_AX2"
    fi

    # TOOTH K: also-diverged-names — neuter the accumulator line after SENTINEL-ALSO-DIVERGED, replacing
    # it with a no-op ':'. DELETING it leaves an empty else branch = a bash syntax error: a crash that
    # would read as a bite (the helper's bash -n refusal caught exactly that in the pre-migration mutant).
    # Real test REM1: all 3 diverged → pi/gentle-shell must appear in the also-diverged line.
    # Mutant: accumulator replaced with a no-op → also_names stays empty → no names line → gentle-shell absent. Both
    # sides exit 1 (diverged), so the discriminator is the typed also-diverged line.
    MUT_K="$MUT_DIR/verify-skill-drift-mut-K.sh"
    if mk "TOOTH K also-diverged-names" "$SUT" "$MUT_K" '/# SENTINEL-ALSO-DIVERGED/{n;s/.*/        :/}'; then
      ok "TOOTH K pre-check: mutant built (SENTINEL-ALSO-DIVERGED accumulator replaced with a no-op)"
      tt "TOOTH K also-diverged-names" 1 1 "$MUT_K" --orig "$SBX_ORIG" \
        --good-has '^verify-skill-drift: also diverged: .*gentle-shell' \
        --bad-has '^verify-skill-drift: all: checked=[0-9]+ in-sync=0 diverged=[0-9]+ ' --bad-lacks 'gentle-shell' \
        -- bash @SUT@ --all --home "$H_BDG3"
    fi

    echo "-- teeth: force _vsd_resolve_src to always use the kit source (ignore profile); expect PD1a to fail --"
    # Neuters the profile branch so a NON-claude profile is silently compared against the kit
    # source instead of a fresh render — a general-profile install (which legitimately differs
    # from the kit source) would then be misreported as diverged even when untouched. The sandbox
    # carries profiles/ + render-profile.sh (staged above) so the ORIGINAL can render "general".
    MUT_PD="$MUT_DIR/verify-skill-drift-mut-PD.sh"
    if [ -f "$INSTALLER_PD" ]; then
      if mk "TOOTH PD profile-ignored" "$SUT" "$MUT_PD" 's/if \[ "\$profile" = "claude" \]; then/if true; then/'; then
        ok "TOOTH PD pre-check: mutant built (profile branch forced true)"
        H_PD_TEETH="$ROOT/home_pd_teeth"
        bash "$INSTALLER_PD" --home "$H_PD_TEETH" --harness pi >/dev/null 2>&1
        tt "TOOTH PD profile-ignored" 0 1 "$MUT_PD" --orig "$SBX_ORIG" \
          --good-lacks '.' --bad-has '^verify-skill-drift: diverged harness=pi ' \
          -- bash @SUT@ --harness pi --home "$H_PD_TEETH"
      fi
    else
      no "TOOTH PD: installer not found — cannot exercise this tooth"
    fi

    # F3-leak/F3-completeness mutants need an ACTUAL successful render to reach the code under test
    # (unlike TOOTH PD's mutation above, which takes a fast path that skips rendering entirely); the
    # sandbox's render-profile.sh/profiles/ provide it, so they are built in the sandbox like the rest.
    echo "-- teeth: disable tmp-dir tracking append; expect F3-leak to fail --"
    MUT_F3LEAK="$MUT_DIR/verify-skill-drift-mut-f3leak.sh"
    if [ -f "$INSTALLER_PD" ]; then
      if mk "TOOTH F3-leak" "$SUT" "$MUT_F3LEAK" 's/\[ -n "\$_vsd_tmp" \] && _VSD_RENDER_TMPDIRS+=("\$_vsd_tmp")/false/'; then
        ok "TOOTH F3-leak pre-check: mutant built (tmp-dir tracking disabled)"
        H_TF3L="$ROOT/home_tf3leak"
        bash "$INSTALLER_PD" --home "$H_TF3L" --harness pi >/dev/null 2>&1
        # Probe: each run gets its OWN fresh dedicated TMPDIR and prints the leftover count as a typed
        # line (F3_LEFTOVER=<n>), exiting with the SUT's own rc.
        _F3_PROBE='sut="$1"; shift; d="$(mktemp -d)" || exit 97; TMPDIR="$d" bash "$sut" "$@"; rc=$?; n="$(find "$d" -mindepth 1 -maxdepth 1 | wc -l | tr -d " ")"; printf "F3_LEFTOVER=%s\n" "$n"; rm -rf "$d"; exit "$rc"'
        tt "TOOTH F3-leak" 0 0 "$MUT_F3LEAK" --orig "$SBX_ORIG" \
          --good-has '^F3_LEFTOVER=0$' --bad-has '^F3_LEFTOVER=[1-9][0-9]*$' \
          -- bash -c "$_F3_PROBE" _ @SUT@ --harness pi --home "$H_TF3L"
      fi
    else
      no "TOOTH F3-leak: installer not found — cannot exercise this tooth"
    fi

    echo "-- teeth: force render-completeness to always be accepted (single-harness); expect F3-missing to fail --"
    MUT_F3COMP="$MUT_DIR/verify-skill-drift-mut-f3comp.sh"
    if [ -f "$INSTALLER_PD" ]; then
      if mk "TOOTH F3-completeness" "$SUT" "$MUT_F3COMP" 's/if \[ "\$render_state" != "ok" \]; then/if false; then/'; then
        ok "TOOTH F3-completeness pre-check: mutant built (single-harness completeness check disabled)"
        H_TF3C="$ROOT/home_tf3comp"
        bash "$INSTALLER_PD" --home "$H_TF3C" --harness pi >/dev/null 2>&1
        rm -rf "$H_TF3C/.pi/agent/research-sdd/profile/general"
        # Original: missing persisted render dir → could-not-run (2). Mutant (check disabled): in-sync (0).
        tt "TOOTH F3-completeness" 2 0 "$MUT_F3COMP" --orig "$SBX_ORIG" \
          --good-has 'render dir missing' --bad-lacks 'render dir|could-not-run|ERROR' \
          -- bash @SUT@ --harness pi --home "$H_TF3C"
      fi
    else
      no "TOOTH F3-completeness: installer not found — cannot exercise this tooth"
    fi

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
    # The two mutants are built through lib/mutant.sh into a temp dir ($ROOT/symmut) and then swapped
    # into the synthetic mini-kit below; the observation (the mutated pair re-breaks through the
    # symlinked toolbelt/) keeps its existing shape because a pair swapped in place does not fit
    # mutant_tooth's single original/mutant substitution.
    echo "-- teeth SYMLINK-TOOLBELT: revert -P on verify-skill-drift.sh AND render-profile.sh together --"
    mkdir -p "$ROOT/symmut"
    MUT_SYM="$ROOT/symmut/verify-skill-drift-mut-sym.sh"
    MUT_RPS="$ROOT/symmut/render-profile-mut-sym.sh"
    _sym_ok=1
    if mk "teeth SYMLINK-TOOLBELT verify-skill-drift.sh" "$SUT" "$MUT_SYM" \
         's/SELF_DIR="\$(cd -P "\$(dirname "\$0")" \&\& pwd -P)"/SELF_DIR="$(cd "$(dirname "$0")" \&\& pwd)"/' \
         's/KIT_INSTALL="\$(cd -P "\$SELF_DIR\/\.\.\/install" 2>\/dev\/null \&\& pwd -P)"/KIT_INSTALL="$(cd "$SELF_DIR\/..\/install" 2>\/dev\/null \&\& pwd)"/' \
         's/KIT="\$(cd -P "\$KIT_INSTALL\/\.\." \&\& pwd -P)"/KIT="$(cd "$KIT_INSTALL\/.." \&\& pwd)"/'; then
      ok "teeth SYMLINK-TOOLBELT pre-check: verify-skill-drift.sh mutant built (-P reverted on all 3 hops)"
    else
      _sym_ok=0
    fi
    if mk "teeth SYMLINK-TOOLBELT render-profile.sh" "$KIT/toolbelt/render-profile.sh" "$MUT_RPS" \
         's/HERE="\$(cd -P "\$(dirname "\${BASH_SOURCE\[0\]}")" \&\& pwd -P)"/HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" \&\& pwd)"/' \
         's/KIT_DIR="\${RSDD_KIT_DIR:-\$(cd -P "\$HERE\/\.\." \&\& pwd -P)}"/KIT_DIR="${RSDD_KIT_DIR:-$(cd "$HERE\/.." \&\& pwd)}"/'; then
      ok "teeth SYMLINK-TOOLBELT pre-check: render-profile.sh mutant built (-P reverted on both hops)"
    else
      _sym_ok=0
    fi

    if [ "$_sym_ok" -eq 1 ]; then
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
        --harness pi --home "$H_TSYM" --profile general 2>&1)"; RC_TSYM=$?
      if [ "$RC_TSYM" -eq 2 ] && <<<"$OUT_TSYM" grep -qi 'zero slot markers'; then
        ok "teeth SYMLINK-TOOLBELT: both mutants together re-break through a symlinked toolbelt/ (zero slot markers, rc=2) → the -P fix pair has teeth"
      else
        no "teeth SYMLINK-TOOLBELT: mutants did not re-break — -P fix check is THEATER (rc=$RC_TSYM out=[$OUT_TSYM])"
      fi
    fi
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

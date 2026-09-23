#!/usr/bin/env bash
# enforcement-e2e.test.sh — hermetic end-to-end auto-fire harness for EN4 (R2/R3/R5/R6/R7).
#
# Proves the /research-sdd enforcement chain fires automatically against a scratch target
# without any manual instrument call, without hitting real GitHub, without touching real
# targets.  R1 (SessionStart sweeps) and R4 (live Stop hook blocking) require a live
# Claude Code session; see odd/delta-backlog-campaign/EN4-external-verification-design.md
# for their manual runbook.
#
# R2 — research-sdd-init auto-wires Stop + SessionStart hooks (EN2a).
# R3 — research-sdd-status --next emits RETRO-DUE when blocks_since_retro > threshold (EN1).
# R5 — retro-gate auto-invokes stage-retro-issues --apply on a conforming retro (EN3).
# R6 — reconcile-issues reports delta 'tracked:' against a mock issue (tracked state).
# R7 — retro-gate emits WARN + still allows close (exits 0) when gh unauthenticated.
#
# TEETH (--prove-teeth): sentinel-based and assertion-self-test mutants confirm each
# R-check actually bites:
#   R2-TOOTH: Stop-only settings (no SessionStart) → R2 assertion correctly fails.
#   R3-TOOTH: mutant status (threshold=999) → no RETRO-DUE → R3 check would FAIL.
#   R5-TOOTH: mutant gate (SEEDING-CALL stripped) → seeder not invoked → R5 fails.
#   R7-TOOTH: mutant gate (GH-PROBE stripped) → no WARN emitted → R7 fails.
#
# Usage: enforcement-e2e.test.sh [--prove-teeth]
# Exit: 0 = all pass · 1 = failure · 2 = harness error

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT_TOOLBELT="$HERE/.."
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

INIT_SUT="$KIT_TOOLBELT/research-sdd-init.sh"
STATUS_SUT="$KIT_TOOLBELT/research-sdd-status.sh"
GATE_SUT="$KIT_TOOLBELT/retro-gate.sh"
RECONCILE_SUT="$KIT_TOOLBELT/reconcile-issues.sh"
VR_SUT="$KIT_TOOLBELT/verify-retro.sh"

for _f in "$INIT_SUT" "$STATUS_SUT" "$GATE_SUT" "$RECONCILE_SUT" "$VR_SUT"; do
  [ -f "$_f" ] || { echo "FATAL: SUT not found: $_f" >&2; exit 2; }
done
for _lib in lib/block-files.sh lib/retro-status.sh lib/retro-grammar.sh \
            lib/focus-prefix.sh lib/state-files.sh lib/target-paths.sh; do
  [ -f "$KIT_TOOLBELT/$_lib" ] || { echo "FATAL: lib not found: $KIT_TOOLBELT/$_lib" >&2; exit 2; }
done

command -v jq  >/dev/null 2>&1 || { echo "FATAL: jq required for R2 hook check" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required for target setup"  >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== enforcement-e2e.test.sh =="

# ── mkgit_baseline <dir>: init hermetic git repo with ONE baseline commit (no blocks).
# Callers write the session file from HEAD, THEN commit a block, so git-diff detects it.
mkgit_baseline() {
  local d="$1"
  mkdir -p "$d/.claude" "$d/retros"
  git -C "$d" init -q -b main 2>/dev/null || git -C "$d" init -q
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name tester
  touch "$d/.gitkeep"; git -C "$d" add -A
  GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
    git -C "$d" commit -q -m "init"
}

# ── add_block <target> <filename>: commit a canonical block file.
# Block name MUST match (^|/)[^/]+-(block|bloque)[0-9]+ (block_file_filter regex).
add_block() {
  local tgt="$1" fname="$2"
  printf '# Block\n\nContent.\n' > "$tgt/$fname"
  git -C "$tgt" add "$fname"
  GIT_AUTHOR_DATE="2026-09-01T10:00:00" GIT_COMMITTER_DATE="2026-09-01T10:00:00" \
    git -C "$tgt" commit -q -m "add $fname"
  touch -t 202609011000 "$tgt/$fname"  # block mtime: 10:00
}

# ── mksession <target> <session_id>: record current HEAD sha; set mtime < block.
# Call BEFORE add_block so session-sha precedes the block commit.
mksession() {
  local tgt="$1" sid="$2"
  git -C "$tgt" rev-parse HEAD > "$tgt/.claude/.rsdd-session-$sid"
  touch -t 202609010900 "$tgt/.claude/.rsdd-session-$sid"  # session mtime: 09:00
}

# ── state_file <dir> <bsr>: write a minimal valid RESEARCH-STATE.md ────────────
state_file() {
  local d="$1" bsr="$2"
  local f="$d/RESEARCH-STATE.md"
  cat > "$f" << STEOF
<!-- research-state.v1 -->
schema: research-state.v1
covered_blocks: 0
gaps_closed: 0
known_gaps: 1
investigable_open: 1
requires_execution_open: 0
blocked_open: 0
undocumented_findings: 0
blocks_since_retro: $bsr
<!-- /research-state.v1 -->

## Gap-backlog

| Priority | Gap | type | Status |
|---|---|---|---|
| high | e2e-test-gap | web | pending |

## Blocked gaps
- none

## Stop control
- **Open gaps -- read-only investigable**: 1
STEOF
}

# ── conforming_retro <target> <fname>: write a conforming retro with open delta ─
conforming_retro() {
  local tgt="$1" fname="$2"
  mkdir -p "$tgt/retros"
  cat > "$tgt/retros/$fname" << REOF
<!-- review-status: pending -->
# Retro — E2E harness

## Proposed kit deltas

| # | change | target | evidence | type | priority |
|---|---|---|---|---|---|
| 1 | add session cost spec | research-sdd/METHODOLOGY.md | B1 | new | high |
REOF
  touch -t 202609011200 "$tgt/retros/$fname"  # retro mtime: 12:00 (newer than block 10:00)
}

# ── mock_gh <dir> [mode]: write a gh stub to <dir>/gh ──────────────────────────
# auth-ok (default): auth succeeds, issue list empty.
# fail-auth: auth fails (not authenticated).
# tracked-e2e: issue list returns matching signature for R6 retro.
mock_gh() {
  local dir="$1" mode="${2:-auth-ok}"
  mkdir -p "$dir"
  {
    printf '#!%s\n' "$BASH_BIN"
    printf 'case "${1:-} ${2:-}" in\n'
    if [ "$mode" = "fail-auth" ]; then
      printf '  "auth status") exit 1 ;;\n'
    else
      printf '  "auth status") exit 0 ;;\n'
    fi
    if [ "$mode" = "tracked-e2e" ]; then
      printf '  "issue list") printf "Source retro: e2e-target/retros/2026-09-01-r6-retro.md · 1\\n"; exit 0 ;;\n'
    else
      printf '  "issue list") exit 0 ;;\n'
    fi
    printf '  *) exit 0 ;;\n'
    printf 'esac\n'
  } > "$dir/gh"; chmod +x "$dir/gh"
}

# ── fkit <dir> <seed_log>: hermetic gate sandbox with stub seeder ──────────────
# Copies gate + libs into <dir>/toolbelt/; stub seeder logs args to <seed_log>.
fkit() {
  local dir="$1" seed_log="$2"
  local tb="$dir/toolbelt"
  mkdir -p "$tb/lib"
  for _l in block-files.sh retro-status.sh retro-grammar.sh; do
    cp "$KIT_TOOLBELT/lib/$_l" "$tb/lib/"
  done
  cp "$VR_SUT" "$tb/"
  {
    printf '#!%s\n' "$BASH_BIN"
    printf 'printf "%%s\\n" "$*" >> "${SEED_LOG:-%s}"\n' "$seed_log"
    printf 'exit 0\n'
  } > "$tb/stage-retro-issues.sh"; chmod +x "$tb/stage-retro-issues.sh"
  # Gate copy: SELF_DIR → $tb so lib/ and stub seeder resolve correctly
  cp "$GATE_SUT" "$tb/retro-gate.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# R2 — research-sdd-init --wire writes Stop + SessionStart hooks (opt-in)
# ─────────────────────────────────────────────────────────────────────────────
T_R2="$ROOT/r2-target"; mkdir -p "$T_R2"
git -C "$T_R2" init -q -b main 2>/dev/null || git -C "$T_R2" init -q
git -C "$T_R2" config user.email t@example.com
git -C "$T_R2" config user.name tester
"$BASH_BIN" "$INIT_SUT" "$T_R2" --wire >/dev/null 2>&1

_r2_settings="$T_R2/.claude/settings.json"
_r2_stop_cmd="" ; _r2_ss_cmd=""
if [ -f "$_r2_settings" ]; then
  _r2_stop_cmd="$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$_r2_settings" 2>/dev/null)"
  _r2_ss_cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$_r2_settings" 2>/dev/null)"
fi

if printf '%s' "$_r2_stop_cmd" | grep -q 'retro-gate-stop.sh' && \
   printf '%s' "$_r2_ss_cmd"   | grep -q 'research-protocol.sh'; then
  ok "R2: init --wire wrote Stop (retro-gate-stop.sh) + SessionStart (research-protocol.sh)"
else
  no "R2: init --wire did NOT write both hooks — stop=[$_r2_stop_cmd] ss=[$_r2_ss_cmd]"
fi

# R2-ctrl: default (no --wire flag) must NOT write settings.json (prove-never-apply is the default)
T_R2N="$ROOT/r2-default"; mkdir -p "$T_R2N"
git -C "$T_R2N" init -q -b main 2>/dev/null || git -C "$T_R2N" init -q
git -C "$T_R2N" config user.email t@example.com
git -C "$T_R2N" config user.name tester
"$BASH_BIN" "$INIT_SUT" "$T_R2N" >/dev/null 2>&1

if [ ! -f "$T_R2N/.claude/settings.json" ]; then
  ok "R2-ctrl: default (no flag) skips settings.json write — propose-never-apply is the default"
else
  no "R2-ctrl: default (no flag) should NOT write settings.json but found one"
fi

# ─────────────────────────────────────────────────────────────────────────────
# R3 — blocks_since_retro > 10 → --next auto-emits RETRO-DUE
# ─────────────────────────────────────────────────────────────────────────────
T_R3="$ROOT/r3-target"; mkdir -p "$T_R3"
state_file "$T_R3" 11

_r3_out="$("$BASH_BIN" "$STATUS_SUT" "$T_R3" --next 2>/dev/null)"
case "$_r3_out" in
  RETRO-DUE*)
    ok "R3: blocks_since_retro=11 → --next auto-emits RETRO-DUE (EN1/#627)" ;;
  *)
    no "R3: expected RETRO-DUE, got [$_r3_out]" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# R5 — retro-gate auto-invokes stage-retro-issues --apply on conforming retro
# ─────────────────────────────────────────────────────────────────────────────
FKIT_R5="$ROOT/fkit-r5"
SEED_LOG_R5="$ROOT/r5-seed.log"
fkit "$FKIT_R5" "$SEED_LOG_R5"

MOCK_GH_R5="$ROOT/mockbin-r5"
mock_gh "$MOCK_GH_R5" auth-ok

# Scratch target: baseline commit → session file → block commit → retro (newer than block)
T_R5="$ROOT/r5-target"
mkgit_baseline "$T_R5"
SID_R5="r5-sess-e2e"
mksession "$T_R5" "$SID_R5"         # session sha = baseline HEAD (before block commit)
add_block "$T_R5" "e2e-block1.md"   # block commit after session sha → diff detects it
conforming_retro "$T_R5" "2026-09-01-r5-retro.md"

rm -f "$SEED_LOG_R5"
_r5_json="$(printf '{"session_id":"%s","stop_hook_active":false,"hook_event_name":"Stop","cwd":"/tmp"}' "$SID_R5")"
printf '%s' "$_r5_json" | SEED_LOG="$SEED_LOG_R5" \
  PATH="$MOCK_GH_R5:$PATH" "$BASH_BIN" "$FKIT_R5/toolbelt/retro-gate.sh" "$T_R5" \
  >/dev/null 2>/dev/null || true

if [ -f "$SEED_LOG_R5" ] && grep -qF -- '--apply' "$SEED_LOG_R5"; then
  ok "R5: gate auto-invoked stub seeder with --apply (EN3 seeding fires on conforming retro)"
else
  no "R5: seeder NOT called with --apply; log=$(cat "$SEED_LOG_R5" 2>/dev/null || echo absent)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# R6 — reconcile-issues reports 'tracked:' with matching mock issue
# ─────────────────────────────────────────────────────────────────────────────
BOX_R6="$ROOT/box-r6"
mkdir -p "$BOX_R6/research-sdd/toolbelt/lib" \
         "$BOX_R6/rh/e2e-target/retros" \
         "$BOX_R6/bin"
cp "$RECONCILE_SUT" "$BOX_R6/research-sdd/toolbelt/reconcile-issues.sh"
for _l in retro-status.sh retro-grammar.sh target-paths.sh; do
  cp "$KIT_TOOLBELT/lib/$_l" "$BOX_R6/research-sdd/toolbelt/lib/"
done
{
  printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n'
  printf '| 1 | e2e-target | `%s` |\n' "$BOX_R6/rh/e2e-target"
} > "$BOX_R6/research-sdd/TARGETS.md"

R6_RETRO="$BOX_R6/rh/e2e-target/retros/2026-09-01-r6-retro.md"
cat > "$R6_RETRO" << R6EOF
<!-- review-status: pending -->
# Retro — E2E R6

## Proposed kit deltas

| # | change | target | evidence | type | priority |
|---|---|---|---|---|---|
| 1 | add session cost spec | research-sdd/METHODOLOGY.md | B1 | new | high |
R6EOF

mock_gh "$BOX_R6/bin" tracked-e2e

_r6_out="$(PATH="$BOX_R6/bin:$PATH" "$BASH_BIN" \
  "$BOX_R6/research-sdd/toolbelt/reconcile-issues.sh" "$R6_RETRO" 2>/dev/null)"
if printf '%s' "$_r6_out" | grep -qi 'tracked:'; then
  ok "R6: reconcile-issues reports delta 'tracked:' with matching mock issue"
else
  no "R6: expected 'tracked:' in output, got [$_r6_out]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# R7 — gh unauthenticated → gate emits WARN + exits 0 (allows close)
# ─────────────────────────────────────────────────────────────────────────────
T_R7="$ROOT/r7-target"
mkgit_baseline "$T_R7"
SID_R7="r7-sess-e2e"
mksession "$T_R7" "$SID_R7"        # session sha before block commit
add_block "$T_R7" "e2e-block1.md"  # block after session sha
conforming_retro "$T_R7" "2026-09-01-r7-retro.md"

FAIL_AUTH_R7="$ROOT/failauth-r7"
mock_gh "$FAIL_AUTH_R7" fail-auth

_r7_json="$(printf '{"session_id":"%s","stop_hook_active":false,"hook_event_name":"Stop","cwd":"/tmp"}' "$SID_R7")"
_r7_errf="$ROOT/r7-err"
_r7_stdout="$(printf '%s' "$_r7_json" | PATH="$FAIL_AUTH_R7:$PATH" \
  "$BASH_BIN" "$GATE_SUT" "$T_R7" 2>"$_r7_errf")"
_r7_rc=$?
_r7_stderr="$(cat "$_r7_errf")"

if [ "$_r7_rc" -eq 0 ]; then
  ok "R7: gate exits 0 (allows close) even with unauthenticated gh (hook contract)"
else
  no "R7: gate must exit 0 with unauthenticated gh, got exit $_r7_rc"
fi
if printf '%s' "$_r7_stderr" | grep -q 'WARN.*not authenticated'; then
  ok "R7: gate emits WARN when gh not authenticated (degraded is honest)"
else
  no "R7: gate missing gh-auth WARN with unauthenticated gh; stderr=[$_r7_stderr]"
fi
if [ -z "$_r7_stdout" ]; then
  ok "R7: no block JSON on stdout — gate allows close with unauthenticated gh"
else
  no "R7: unexpected stdout (should be empty on allow): [$_r7_stdout]"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary (non-teeth run)
# ─────────────────────────────────────────────────────────────────────────────
PROVE_TEETH="${1:-}"
if [ "$PROVE_TEETH" != "--prove-teeth" ]; then
  echo
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi

echo
echo "-- TEETH: mutation controls --"

# ── Mutant kit dir: toolbelt mirror for gate mutants (gate uses SELF_DIR-relative lib paths)
MUT_KIT="$ROOT/mutkit"
mkdir -p "$MUT_KIT/toolbelt/lib"
for _l in block-files.sh retro-status.sh retro-grammar.sh; do
  cp "$KIT_TOOLBELT/lib/$_l" "$MUT_KIT/toolbelt/lib/"
done
cp "$VR_SUT" "$MUT_KIT/toolbelt/"
cp "$FKIT_R5/toolbelt/stage-retro-issues.sh" "$MUT_KIT/toolbelt/"  # stub seeder

# ── Mutant status kit dir: status mirror with lib for R3 mutant ───────────────
MUT_STAT_KIT="$ROOT/mutstatkit/toolbelt"
mkdir -p "$MUT_STAT_KIT/lib"
for _l in focus-prefix.sh state-files.sh block-files.sh; do
  cp "$KIT_TOOLBELT/lib/$_l" "$MUT_STAT_KIT/lib/"
done

# ── R2-TOOTH: Stop-only settings (no SessionStart) → R2 assertion fails ───────
# Proves the R2 check verifies BOTH hooks, not just one.
_r2t_dir="$ROOT/r2-tooth"; mkdir -p "$_r2t_dir/.claude"
jq -n '{
  "hooks": {
    "Stop": [{"matcher":"","hooks":[{"type":"command","command":"/x/retro-gate-stop.sh"}]}],
    "SessionStart": []
  }
}' > "$_r2t_dir/.claude/settings.json"

_r2t_stop="$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$_r2t_dir/.claude/settings.json" 2>/dev/null)"
_r2t_ss="$(jq -r '.hooks.SessionStart[0].hooks[0].command // empty' "$_r2t_dir/.claude/settings.json" 2>/dev/null)"
_r2t_pass=0
if printf '%s' "$_r2t_stop" | grep -q 'retro-gate-stop.sh' && \
   printf '%s' "$_r2t_ss"   | grep -q 'research-protocol.sh'; then
  _r2t_pass=1
fi
if [ "$_r2t_pass" -eq 0 ]; then
  ok "R2-TOOTH: Stop-only settings (no SessionStart) → R2 assertion correctly fails (checks both)"
else
  no "R2-TOOTH: Stop-only settings should FAIL R2 assertion but PASSED (assertion too loose)"
fi

# ── R3-TOOTH: mutant status (threshold=999) → no RETRO-DUE → R3 check fails ───
# Proves R3 check catches a SUT where RETRO-DUE threshold is effectively disabled.
MUT_STAT_R3="$MUT_STAT_KIT/research-sdd-status.sh"
sed 's/_rd_threshold=10/_rd_threshold=999/' "$STATUS_SUT" > "$MUT_STAT_R3"
chmod +x "$MUT_STAT_R3"

_r3t_out="$("$BASH_BIN" "$MUT_STAT_R3" "$T_R3" --next 2>/dev/null)"
_r3t_pass=1
case "$_r3t_out" in RETRO-DUE*) _r3t_pass=0 ;; esac

if [ "$_r3t_pass" -eq 1 ]; then
  ok "R3-TOOTH: mutant (threshold=999) → no RETRO-DUE for bsr=11 → R3 check would FAIL (bites)"
else
  no "R3-TOOTH: mutant (threshold=999) should NOT produce RETRO-DUE but got [$_r3t_out]"
fi

# ── R5-TOOTH: mutant gate (SEEDING-CALL stripped) → seeder not called ─────────
# Proves R5 check catches a gate that skips calling stage-retro-issues.
MUT_GATE_R5="$MUT_KIT/toolbelt/mutant-gate-r5.sh"
sed '/# SENTINEL-SEEDING-CALL-START/,/# SENTINEL-SEEDING-CALL-END/d' \
  "$GATE_SUT" > "$MUT_GATE_R5"; chmod +x "$MUT_GATE_R5"

rm -f "$SEED_LOG_R5"
printf '%s' "$_r5_json" | SEED_LOG="$SEED_LOG_R5" \
  PATH="$MOCK_GH_R5:$PATH" "$BASH_BIN" "$MUT_GATE_R5" "$T_R5" \
  >/dev/null 2>/dev/null || true

_r5t_pass=1
[ -f "$SEED_LOG_R5" ] && grep -qF -- '--apply' "$SEED_LOG_R5" && _r5t_pass=0
if [ "$_r5t_pass" -eq 1 ]; then
  ok "R5-TOOTH: mutant (seeding-call stripped) → seeder not called → R5 check would FAIL (bites)"
else
  no "R5-TOOTH: mutant with seeding-call removed should NOT log --apply but did"
fi

# ── R7-TOOTH: mutant gate (GH-PROBE stripped) → no WARN emitted ───────────────
# Proves R7 check catches a gate that omits the gh-auth probe (never emits WARN).
MUT_GATE_R7="$MUT_KIT/toolbelt/mutant-gate-r7.sh"
sed '/# SENTINEL-GH-PROBE-START/,/# SENTINEL-GH-PROBE-END/d' \
  "$GATE_SUT" > "$MUT_GATE_R7"; chmod +x "$MUT_GATE_R7"

_r7t_errf="$ROOT/r7-tooth-err"
_r7t_stdout="$(printf '%s' "$_r7_json" | PATH="$FAIL_AUTH_R7:$PATH" \
  "$BASH_BIN" "$MUT_GATE_R7" "$T_R7" 2>"$_r7t_errf")"
_r7t_stderr="$(cat "$_r7t_errf")"

_r7t_has_ghprobe_warn=0
printf '%s' "$_r7t_stderr" | grep -q 'WARN.*not authenticated' && _r7t_has_ghprobe_warn=1
if [ "$_r7t_has_ghprobe_warn" -eq 0 ]; then
  ok "R7-TOOTH: mutant (gh-probe stripped) → no gh-auth WARN → R7 check would FAIL (bites)"
else
  no "R7-TOOTH: mutant with gh-probe removed should NOT emit gh-auth WARN but did; stderr=[$_r7t_stderr]"
fi

echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1

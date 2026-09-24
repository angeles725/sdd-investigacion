#!/usr/bin/env bash
# hook-sessionstart.test.sh — RED-FIRST harness for the SessionStart hook template.
#
# Covers: bash -n syntax; tool-registry.md pointer (F11 — stale list replaced);
#         calm wording — no ALWAYS (F11); jq probe present and behaviorally correct
#         (L7); P8 placeholder cleanliness (no unexpected <KIT>).
# Each mutation control proves the matching green assertion bites.
#
# Usage: hook-sessionstart.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../../templates/hook-sessionstart.sh"
VS="$HERE/../verify-state.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$VS"  ] || { echo "FATAL: verify-state not found: $VS" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== hook-sessionstart.test.sh (SUT: $(basename "$SUT")) =="

# ── STATIC CHECKS ────────────────────────────────────────────────────────────────────────────

echo "-- static: bash -n syntax --"
if bash -n "$SUT" 2>/dev/null; then
  ok "static: template passes bash -n syntax check"
else
  no "static: template has bash -n syntax error"
fi

echo "-- static: tool list is a tool-registry.md pointer, not a stale per-tool list --"
if grep -qF "tool-registry.md" "$SUT"; then
  ok "static: template contains tool-registry.md pointer"
else
  no "static: template missing tool-registry.md pointer"
fi
for _stale in "decompile-java.sh" "decompile-net.sh" "decompile-native.sh" \
              "scan-firmware.sh"; do
  if grep -qF "$_stale" "$SUT"; then
    no "static: stale tool '$_stale' still present in template"
  else
    ok "static: stale tool '$_stale' absent from template"
  fi
done
unset _stale

echo "-- static: calm wording — ALWAYS follow this order removed --"
if grep -qF "ALWAYS follow this order" "$SUT"; then
  no "static: 'ALWAYS follow this order' still present in template"
else
  ok "static: 'ALWAYS follow this order' removed from template"
fi

echo "-- static: jq probe present (command -v jq) --"
if grep -q 'command -v jq' "$SUT"; then
  ok "static: jq probe (command -v jq) present in template"
else
  no "static: jq probe (command -v jq) missing from template"
fi

echo "-- static: header comment says SessionStart, not Stop-hook --"
if grep -q 'Stop-hook JSON stdin' "$SUT"; then
  no "static: header comment still says 'Stop-hook JSON stdin'"
else
  ok "static: header comment does not say 'Stop-hook JSON stdin'"
fi

# ── NO-JQ BEHAVIOURAL CHECK ───────────────────────────────────────────────────────────────────

echo "-- no-jq: hook exits 0 and emits hookSpecificOutput JSON when jq is absent --"
# Hermetic approach: build a temp bin with symlinks to exactly the external tools the hook
# needs before the probe fires, and NOTHING else — so jq is provably absent.
#
# External tools used between shebang and probe (lines 13–40 of the template):
#   cat      — line 13: _hook_stdin=$(cat)
#   dirname  — line 20: _hook_target="$(cd "$(dirname "$0")/../.." && pwd)"
#   jq       — line 14: pipeline with || fallback; intentionally excluded here
# All other calls (git, find, mkdir) are inside 'if [ -n "$_session_id" ]' which is
# skipped when jq is absent (|| _session_id="" leaves _session_id empty).
_bash_exe="$(command -v bash)"
_hermetic_bin="$TMP/hermetic-nojq"
mkdir -p "$_hermetic_bin"
for _htool in cat dirname; do
  _htool_real="$(command -v "$_htool" 2>/dev/null || true)"
  if [ -n "$_htool_real" ]; then
    ln -sf "$_htool_real" "$_hermetic_bin/$_htool"
  fi
done
unset _htool _htool_real
_nojq_tested=0

# Sanity assert: jq must NOT be reachable under the hermetic PATH before running the hook.
# Use the resolved absolute bash path so `PATH=... bash` does not fail looking up 'bash'.
if PATH="$_hermetic_bin" "$_bash_exe" -c 'command -v jq >/dev/null 2>&1'; then
  printf '  SKIP  no-jq: jq still reachable under hermetic PATH — unexpected install (e.g. /usr/local/bin or snap); test skipped [typed: hermetic-skip-jq-reachable]\n'
else
  _nojq_out="$TMP/nojq-out.txt"
  _nojq_err="$TMP/nojq-err.txt"
  PATH="$_hermetic_bin" "$_bash_exe" "$SUT" </dev/null >"$_nojq_out" 2>"$_nojq_err"
  _nojq_ec=$?
  _nojq_tested=1
  if [ "$_nojq_ec" -eq 0 ]; then
    ok "no-jq: hook exits 0 when jq absent"
  else
    no "no-jq: hook exits $_nojq_ec when jq absent (expected 0)"
  fi
  if grep -qF '"hookSpecificOutput"' "$_nojq_out" 2>/dev/null; then
    ok "no-jq: stdout contains hookSpecificOutput JSON"
  else
    no "no-jq: stdout missing hookSpecificOutput JSON when jq absent"
  fi
  if grep -q 'degraded' "$_nojq_err" 2>/dev/null; then
    ok "no-jq: stderr contains degraded notice"
  else
    no "no-jq: stderr missing degraded notice when jq absent"
  fi
fi

# ── ROTATION: THIS SESSION'S OWN STATE FILES SURVIVE A LONG SESSION (#984) ───────────────────

echo "-- rotation: a >7-day-old session must keep its OWN state files, but an unrelated old one is still purged --"
_rotd="$TMP/rotation-target"
mkdir -p "$_rotd/.claude/hooks"
# Install the hook at its real two-levels-below-target layout ($0-relative _hook_target
# resolution depends on this — same layout the P8 block below uses).
cp "$SUT" "$_rotd/.claude/hooks/research-protocol.sh"
_rot_sid="rot984-current-session"
_rot_other_sid="rot984-unrelated-old-session"
_rot_own_session_file="$_rotd/.claude/.rsdd-session-${_rot_sid}"
_rot_own_blocked_file="$_rotd/.claude/.rsdd-retro-blocked-${_rot_sid}"
_rot_other_file="$_rotd/.claude/.rsdd-session-${_rot_other_sid}"
printf 'deadbeef\n' > "$_rot_own_session_file"
printf '2026-01-01T00:00:00Z\n' > "$_rot_own_blocked_file"
printf 'deadbeef\n' > "$_rot_other_file"
# Age all three past the 7-day rotation window — simulates a session that has been running
# for over a week, alongside an unrelated session's leftover state.
touch -d '-10 days' "$_rot_own_session_file" "$_rot_own_blocked_file" "$_rot_other_file"
_rot_json="{\"session_id\":\"${_rot_sid}\"}"
printf '%s' "$_rot_json" | bash "$_rotd/.claude/hooks/research-protocol.sh" >"$TMP/rot-out.txt" 2>"$TMP/rot-err.txt"
if [ -s "$_rot_own_session_file" ]; then
  ok "rotation: current session's own .rsdd-session file survives past the 7-day window"
else
  no "rotation: current session's own .rsdd-session file was deleted despite being the active session"
fi
if [ -f "$_rot_own_blocked_file" ]; then
  ok "rotation: current session's own .rsdd-retro-blocked file survives past the 7-day window"
else
  no "rotation: current session's own .rsdd-retro-blocked file was deleted despite being the active session"
fi
if [ ! -e "$_rot_other_file" ]; then
  ok "rotation: an unrelated old session's state file is still purged (rotation not disabled entirely)"
else
  no "rotation: unrelated old session's state file was NOT purged — rotation broken, not just narrowed"
fi
# The recorded sha under this session id must be preserved verbatim (write-once): the hook must
# not have overwritten it just because the file was old.
if grep -qF 'deadbeef' "$_rot_own_session_file"; then
  ok "rotation: pre-existing sha under this session id is preserved (write-once still holds)"
else
  no "rotation: pre-existing sha under this session id was NOT preserved"
fi

# ── F3: TOUCH-REFRESH PROTECTS AN ACTIVE SESSION ACROSS ANOTHER SESSION'S ROTATION PASS ──────

echo "-- F3: an active session's mtime-refresh survives a DIFFERENT session's rotation pass --"
# The self-exclusion above (by name) only protects a session from its OWN rotation pass — it
# cannot help session B when it is session A's hook that runs the rotation, since A's find
# excludes only A's own id. Opus reproduced: with only self-exclusion, session B's 10-day-old
# file was deleted by session A's hook. The fix refreshes (never rewrites) a session's own
# state-file mtimes on every SessionStart trigger for that id, so an active session looks
# "recent" to ANY hook's rotation pass, not just its own.
_f3d="$TMP/f3-cross-session-target"
mkdir -p "$_f3d/.claude/hooks"
cp "$SUT" "$_f3d/.claude/hooks/research-protocol.sh"
_f3_sid_b="f3-session-b"
_f3_sid_a="f3-session-a"
_f3_b_file="$_f3d/.claude/.rsdd-session-${_f3_sid_b}"
printf 'deadbeef\n' > "$_f3_b_file"
touch -d '-10 days' "$_f3_b_file"
# Session B fires its own SessionStart (e.g. a resume) — this refreshes B's own mtime to now,
# even though write-once keeps its recorded sha untouched (still non-empty, so no rewrite).
printf '{"session_id":"%s"}' "$_f3_sid_b" \
  | bash "$_f3d/.claude/hooks/research-protocol.sh" >/dev/null 2>&1
if grep -qF 'deadbeef' "$_f3_b_file"; then
  ok "F3: session B's own hook run refreshes its mtime WITHOUT rewriting its recorded sha"
else
  no "F3: session B's recorded sha was lost by the mtime-refresh (write-once broken)"
fi
# Session A — a totally different session id — now fires ITS OWN SessionStart. A's rotation
# pass does not know B's id at all; B's file must survive purely because it was refreshed a
# moment ago, not because A's find excluded it by name.
printf '{"session_id":"%s"}' "$_f3_sid_a" \
  | bash "$_f3d/.claude/hooks/research-protocol.sh" >/dev/null 2>&1
if [ -e "$_f3_b_file" ]; then
  ok "F3: session B's file survives session A's rotation pass (cross-session mtime protection)"
else
  no "F3: session B's file was deleted by session A's rotation pass — cross-session protection missing"
fi

# ── P8 PLACEHOLDER CLEANLINESS ───────────────────────────────────────────────────────────────

echo "-- p8: hook installed from template triggers only per-target placeholders --"
_p8d="$TMP/p8-target"
mkdir -p "$_p8d/.claude/hooks"
cp "$SUT" "$_p8d/.claude/hooks/research-protocol.sh"
# Minimal RESEARCH-STATE.md so verify-state does not exit 2 before P8 runs
{ printf '<!-- research-state.v1 -->\n'
  printf 'schema: research-state.v1\n'
  printf 'covered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\n'
  printf 'investigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\n'
  printf '<!-- /research-state.v1 -->\n'; } > "$_p8d/RESEARCH-STATE.md"
_p8_out="$(bash "$VS" "$_p8d" 2>/dev/null)"
if printf '%s\n' "$_p8_out" | grep -q 'WARN.*hook-placeholder.*<KIT>'; then
  no "p8: unexpected <KIT> placeholder WARN — template still contains <KIT>"
else
  ok "p8: no <KIT> placeholder WARN (\$RESEARCH_SDD_KIT correctly used)"
fi

# ── MUTATION CONTROLS (--prove-teeth) ────────────────────────────────────────────────────────

if [ "${1:-}" = "--prove-teeth" ]; then

  echo "-- teeth M1: tool-registry.md pointer check has teeth --"
  _m1="$TMP/mutant-m1.sh"
  cp "$SUT" "$_m1"
  sed -i 's/tool-registry\.md/decompile-java.sh/g' "$_m1"
  if grep -qF "tool-registry.md" "$_m1"; then
    no "teeth M1: could not build mutant (tool-registry.md still present after sed)"
  else
    # The green assertion: grep -qF "tool-registry.md" SUT
    # On the mutant it should return 1 (RED)
    if ! grep -qF "tool-registry.md" "$_m1"; then
      ok "teeth M1: tool-registry.md assertion RED on mutant (has teeth)"
    else
      no "teeth M1: tool-registry.md assertion PASSES on mutant — no teeth"
    fi
  fi

  echo "-- teeth M2: no-jq exit-0 check has teeth --"
  if [ "$_nojq_tested" -eq 1 ]; then
    _m2="$TMP/mutant-m2.sh"
    cp "$SUT" "$_m2"
    # Mutant: disable the jq probe so it never fires
    sed -i 's/if ! command -v jq/if false  # MUTANT: probe disabled; was: if ! command -v jq/' "$_m2"
    if grep -qF 'MUTANT: probe disabled' "$_m2"; then
      PATH="$_hermetic_bin" "$_bash_exe" "$_m2" </dev/null >"$TMP/m2-out.txt" 2>/dev/null
      _m2_ec=$?
      # Without probe, jq-n fails → hook exits non-zero
      if [ "$_m2_ec" -ne 0 ]; then
        ok "teeth M2: no-jq exit-0 check RED on probe-disabled mutant (has teeth)"
      else
        no "teeth M2: probe-disabled mutant still exits 0 — no-jq exit-0 check has no teeth"
      fi
    else
      no "teeth M2: could not build probe-disabled mutant"
    fi
  else
    printf '  SKIP  teeth M2: no-jq test was skipped (jq reachable under hermetic PATH) — M2 skipped too\n'
  fi

  echo "-- teeth M4: rotation protections (self-exclusion + touch-refresh) have teeth (#984) --"
  _m4d="$TMP/rotation-mutant"
  mkdir -p "$_m4d/.claude/hooks"
  _m4="$_m4d/.claude/hooks/research-protocol.sh"
  cp "$SUT" "$_m4"
  # Mutant: drop the self-exclusion `! -name ... ! -name ...` line AND the F3 touch-refresh
  # lines, reverting to the pre-#984 behaviour that purges a session's own state files too.
  # Both must go together here: with touch-refresh alone still present, it would refresh this
  # session's own mtime to "now" moments before the (self-exclusion-stripped) find runs, and
  # the file would survive anyway — masking a self-exclusion regression. Must delete whole
  # lines (not just text) — a blank line in the `\`-continued find command would snap it in
  # two, breaking `-delete` into an invalid standalone "command", degrading the find to its
  # default -print action instead of actually reverting to the pre-fix delete (caught
  # empirically: see PR body). The dedicated touch-refresh teeth below isolates F3 on its own.
  sed -i \
    -e '/! -name "\.rsdd-session-\${_session_id}"/d' \
    -e '/touch "\$_rsdd_file" 2>\/dev\/null/d' \
    -e '/touch "\$_rsdd_blocked_file" 2>\/dev\/null/d' \
    "$_m4"
  if grep -qF '! -name ".rsdd-session-${_session_id}"' "$_m4" || grep -qF 'touch "$_rsdd_file"' "$_m4"; then
    no "teeth M4: could not build mutant (self-exclusion or touch-refresh still present after sed)"
  else
    _m4_sid="m4-current-session"
    _m4_own="$_m4d/.claude/.rsdd-session-${_m4_sid}"
    printf 'deadbeef\n' > "$_m4_own"
    touch -d '-10 days' "$_m4_own"
    printf '{"session_id":"%s"}' "$_m4_sid" | bash "$_m4" >/dev/null 2>&1
    if [ ! -e "$_m4_own" ]; then
      ok "teeth M4: mutant deletes its own session file past 7 days (RED as expected)"
    else
      no "teeth M4: mutant did NOT delete the session file — rotation protections have no teeth"
    fi
  fi

  echo "-- teeth M5: F3 touch-refresh alone has teeth (cross-session mtime protection) --"
  _m5d="$TMP/touch-refresh-mutant"
  mkdir -p "$_m5d/.claude/hooks"
  _m5="$_m5d/.claude/hooks/research-protocol.sh"
  cp "$SUT" "$_m5"
  # Mutant: drop ONLY the two touch-refresh lines, leaving the by-name self-exclusion intact.
  # Self-exclusion cannot cover a DIFFERENT session id by construction, so this isolates F3:
  # re-run the exact F3 cross-session scenario below and expect session B's file to now be
  # deleted by session A's rotation pass, because it is never refreshed to a recent mtime.
  sed -i \
    -e '/touch "\$_rsdd_file" 2>\/dev\/null/d' \
    -e '/touch "\$_rsdd_blocked_file" 2>\/dev\/null/d' \
    "$_m5"
  if grep -qF 'touch "$_rsdd_file"' "$_m5"; then
    no "teeth M5: could not build mutant (touch-refresh still present after sed)"
  else
    _m5d_target="$TMP/f3-mutant-target"
    mkdir -p "$_m5d_target/.claude/hooks"
    cp "$_m5" "$_m5d_target/.claude/hooks/research-protocol.sh"
    _m5_sid_b="m5-session-b"
    _m5_sid_a="m5-session-a"
    _m5_b_file="$_m5d_target/.claude/.rsdd-session-${_m5_sid_b}"
    printf 'deadbeef\n' > "$_m5_b_file"
    touch -d '-10 days' "$_m5_b_file"
    # B's own hook run: pre-fix, this refreshed B's mtime (case F3 below). On this mutant it
    # does not, so B's file stays at -10 days.
    printf '{"session_id":"%s"}' "$_m5_sid_b" \
      | bash "$_m5d_target/.claude/hooks/research-protocol.sh" >/dev/null 2>&1
    # A's own SessionStart, a different session id entirely: self-exclusion protects only A's
    # OWN files by name, never B's — B's fate depends solely on the (now missing) touch-refresh.
    printf '{"session_id":"%s"}' "$_m5_sid_a" \
      | bash "$_m5d_target/.claude/hooks/research-protocol.sh" >/dev/null 2>&1
    if [ ! -e "$_m5_b_file" ]; then
      ok "teeth M5: touch-refresh removed → session B's file deleted by session A's rotation (RED as expected)"
    else
      no "teeth M5: touch-refresh removed → session B's file should have been deleted by A's rotation but was not"
    fi
  fi

  echo "-- teeth M3: P8 <KIT> check has teeth --"
  _m3d="$TMP/p8-mutant"
  mkdir -p "$_m3d/.claude/hooks"
  # Inject <KIT> into the hook so P8 fires a WARN about it
  sed 's/\$RESEARCH_SDD_KIT/<KIT>/g' "$SUT" > "$_m3d/.claude/hooks/research-protocol.sh"
  { printf '<!-- research-state.v1 -->\n'; printf 'schema: research-state.v1\n'
    printf 'covered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\n'
    printf 'investigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\n'
    printf '<!-- /research-state.v1 -->\n'; } > "$_m3d/RESEARCH-STATE.md"
  _m3_out="$(bash "$VS" "$_m3d" 2>/dev/null)"
  if printf '%s\n' "$_m3_out" | grep -q 'WARN.*hook-placeholder.*<KIT>'; then
    ok "teeth M3: P8 <KIT> WARN fires on mutant with <KIT> injected (has teeth)"
  else
    no "teeth M3: P8 mutant did not warn about <KIT> — p8 check has no teeth"
  fi

fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

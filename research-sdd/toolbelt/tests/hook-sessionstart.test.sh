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

# ── R3-001: no mtime refresh — a resume/compact must not move retro-gate's reference point ──

echo "-- R3-001(a): a second SessionStart leaves mtime+content unchanged; retro-gate still sees a between-calls edit as changed --"
_r3d="$TMP/r3-target"; mkdir -p "$_r3d/.claude/hooks"
git -C "$_r3d" init -q -b main
git -C "$_r3d" -c user.email=t@example.com -c user.name=tester commit -q --allow-empty -m init
cp "$SUT" "$_r3d/.claude/hooks/research-protocol.sh"; _r3_sid="r3-session"; _r3_file="$_r3d/.claude/.rsdd-session-${_r3_sid}"
printf '{"session_id":"%s"}' "$_r3_sid" | bash "$_r3d/.claude/hooks/research-protocol.sh" >/dev/null 2>&1
touch -d '-1 hour' "$_r3_file"
_r3_c1="$(cat "$_r3_file")"; _r3_m1="$(stat -c %Y "$_r3_file")"
printf '# Block 1\nBody.\n' > "$_r3d/t-block1.md"   # edit made BETWEEN the two SessionStarts
printf '{"session_id":"%s"}' "$_r3_sid" | bash "$_r3d/.claude/hooks/research-protocol.sh" >/dev/null 2>&1
_r3_c2="$(cat "$_r3_file")"; _r3_m2="$(stat -c %Y "$_r3_file")"
_r3_gate="$(printf '{"session_id":"%s","stop_hook_active":false}' "$_r3_sid" | bash "$HERE/../retro-gate.sh" "$_r3d" 2>/dev/null)"
if [ "$_r3_c1" = "$_r3_c2" ] && [ "$_r3_m1" = "$_r3_m2" ] && grep -qF '"decision":"block"' <<<"$_r3_gate"; then
  ok "R3-001(a): second SessionStart leaves mtime/content unchanged; retro-gate still sees the edit as changed"
else
  no "R3-001(a): reference-point regression (c1=$_r3_c1 c2=$_r3_c2 m1=$_r3_m1 m2=$_r3_m2 gate=$_r3_gate)"
fi

echo "-- R3-001(b): no sha resolvable (non-git target) → no phantom session file is created --"
_r3bd="$TMP/r3-nogit"; mkdir -p "$_r3bd/.claude/hooks"; cp "$SUT" "$_r3bd/.claude/hooks/research-protocol.sh"; _r3b_sid="r3b-session"
printf '{"session_id":"%s"}' "$_r3b_sid" | bash "$_r3bd/.claude/hooks/research-protocol.sh" >/dev/null 2>&1
if [ ! -e "$_r3bd/.claude/.rsdd-session-${_r3b_sid}" ]; then
  ok "R3-001(b): non-git target with no resolvable sha → no phantom session file created"
else
  no "R3-001(b): a phantom (empty) session file was created despite no resolvable sha"
fi

echo "-- glob-metachar guard: a session_id containing a glob metacharacter skips rotation loudly --"
_gmd="$TMP/glob-metachar-target"; mkdir -p "$_gmd/.claude/hooks"; cp "$SUT" "$_gmd/.claude/hooks/research-protocol.sh"
_gm_sid='evil*id'
_gm_unrelated="$_gmd/.claude/.rsdd-session-unrelated-old"
printf 'deadbeef\n' > "$_gm_unrelated"; touch -d '-10 days' "$_gm_unrelated"
_gm_err="$TMP/glob-metachar-err.txt"
printf '{"session_id":"%s"}' "$_gm_sid" | bash "$_gmd/.claude/hooks/research-protocol.sh" >/dev/null 2>"$_gm_err"
if grep -q 'glob metacharacter' "$_gm_err" && [ -e "$_gm_unrelated" ]; then
  ok "glob-metachar guard: WARNs loudly and skips rotation (unrelated old file survives)"
else
  no "glob-metachar guard: WARNs loudly and skips rotation" \
     "err=[$(cat "$_gm_err")] unrelated-survived=$([ -e "$_gm_unrelated" ] && echo yes || echo no)"
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

  echo "-- teeth M4: rotation self-exclusion check has teeth (#984) --"
  _m4d="$TMP/rotation-mutant"
  mkdir -p "$_m4d/.claude/hooks"
  _m4="$_m4d/.claude/hooks/research-protocol.sh"
  cp "$SUT" "$_m4"
  # Mutant: drop the ENTIRE `! -name ... ! -name ...` self-exclusion clause, reverting to the
  # pre-#984 behaviour that purges a session's own state files too. Must delete the whole line
  # (not just its text) — a blank line in the `\`-continued find command would snap it in two,
  # breaking `-delete` into an invalid standalone "command", degrading the find to its default
  # -print action instead of actually reverting to the pre-fix delete.
  sed -i '/! -name "\.rsdd-session-\${_session_id}"/d' "$_m4"
  if grep -qF '! -name ".rsdd-session-${_session_id}"' "$_m4"; then
    no "teeth M4: could not build mutant (self-exclusion clause still present after sed)"
  else
    _m4_sid="m4-current-session"
    _m4_own="$_m4d/.claude/.rsdd-session-${_m4_sid}"
    printf 'deadbeef\n' > "$_m4_own"
    touch -d '-10 days' "$_m4_own"
    printf '{"session_id":"%s"}' "$_m4_sid" | bash "$_m4" >/dev/null 2>&1
    if [ ! -e "$_m4_own" ]; then
      ok "teeth M4: mutant deletes its own session file past 7 days (RED as expected)"
    else
      no "teeth M4: mutant did NOT delete the session file — self-exclusion check has no teeth"
    fi
  fi

  echo "-- teeth R3-001(a): write-once guard has teeth --"
  _m5="$TMP/r3a-mutant.sh"
  sed 's/if \[ ! -s "\$_rsdd_file" \]; then/if true; then/' "$SUT" > "$_m5"
  if ! grep -q 'if true; then' "$_m5"; then
    no "teeth R3-001(a): anchor not found — SUT drifted?"
  else
    cp "$_m5" "$_r3d/.claude/hooks/research-protocol.sh"; _m5_sid="r3a-mutant"; _m5_file="$_r3d/.claude/.rsdd-session-${_m5_sid}"
    printf '{"session_id":"%s"}' "$_m5_sid" | bash "$_r3d/.claude/hooks/research-protocol.sh" >/dev/null 2>&1
    touch -d '-1 hour' "$_m5_file"
    _m5_m1="$(stat -c %Y "$_m5_file")"
    printf '{"session_id":"%s"}' "$_m5_sid" | bash "$_r3d/.claude/hooks/research-protocol.sh" >/dev/null 2>&1
    _m5_m2="$(stat -c %Y "$_m5_file")"
    if [ "$_m5_m1" != "$_m5_m2" ]; then
      ok "teeth R3-001(a): mutant moves mtime on the second SessionStart (RED as expected)"
    else
      no "teeth R3-001(a): mutant did not move mtime — assertion has no teeth"
    fi
  fi

  echo "-- teeth R3-001(b): empty-sha guard has teeth --"
  _m6="$TMP/r3b-mutant.sh"
  sed 's/if \[ -n "\$_sha" \]; then/if true; then/' "$SUT" > "$_m6"
  if ! grep -q 'if true; then' "$_m6"; then
    no "teeth R3-001(b): anchor not found — SUT drifted?"
  else
    cp "$_m6" "$_r3bd/.claude/hooks/research-protocol.sh"; _m6_sid="r3b-mutant"   # reuse test (b)'s target
    printf '{"session_id":"%s"}' "$_m6_sid" | bash "$_r3bd/.claude/hooks/research-protocol.sh" >/dev/null 2>&1
    if [ -e "$_r3bd/.claude/.rsdd-session-${_m6_sid}" ]; then
      ok "teeth R3-001(b): mutant creates a phantom session file on a non-git target (RED as expected)"
    else
      no "teeth R3-001(b): mutant did NOT create a phantom file — assertion has no teeth"
    fi
  fi

  echo "-- teeth: glob-metachar validation has teeth --"
  _content_hookss="$(cat "$SUT")"
  anchor_glob='  case "$_session_id" in
    *[\*\?\[]*)'
  neutered_glob='  case "$_session_id" in
    _never_matches_this_)'
  if [[ "$_content_hookss" != *"$anchor_glob"* ]]; then
    no "teeth: locate glob-metachar validation in SUT" "anchor not found — SUT drifted?"
  else
    _m7d="$TMP/glob-metachar-mutant"; mkdir -p "$_m7d/.claude/hooks"
    _m7="$_m7d/.claude/hooks/research-protocol.sh"
    printf '%s\n' "${_content_hookss/"$anchor_glob"/$neutered_glob}" > "$_m7"
    _m7_unrelated="$_m7d/.claude/.rsdd-session-unrelated-old"
    printf 'deadbeef\n' > "$_m7_unrelated"; touch -d '-10 days' "$_m7_unrelated"
    printf '{"session_id":"%s"}' 'evil*id' | bash "$_m7" >/dev/null 2>/dev/null
    if [ ! -e "$_m7_unrelated" ]; then
      ok "teeth: glob-metachar validation removed → unrelated old file gets deleted (RED as expected)"
    else
      no "teeth: glob-metachar validation removed → unrelated old file should have been deleted" ""
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

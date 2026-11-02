#!/usr/bin/env bash
# verify-skill-drift-hook.test.sh — harness for verify-skill-drift-hook.sh, now a shim to
# `rsdd verify skill-drift --hook` (kit issue #2365).
#
# Covers the SHIM contract against a STUB rsdd (the toolbelt dir handed over, output and exit code passed
# through, symlinked invocation, rsdd unavailable → a DEGRADED SessionStart envelope with rc 0, a missing lib →
# an announcement with rc 0), the real Go binary end to end on a mini kit (in sync → silent, a diverged skill →
# the stale envelope, an install --verify finding → the surfaced line, an unusable install command → a typed
# line), and mutation proof on the shim. What the hook decides — the install --verify bound and its notes,
# the drift block, the kit-staleness line, the envelope bytes — is pinned in Go (internal/verify,
# skilldrifthook*_test.go: behaviour tests plus a differential against the frozen hook).
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a sandbox toolbelt
SUT="$HERE/../verify-skill-drift-hook.sh"
ADAPTERS="$HERE/../../install/adapters.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# a stale value from the caller must not change a case
unset RESEARCH_SDD_PROFILE GENTLE_PI_AGENT_HOME PI_CODING_AGENT_DIR RESEARCH_SDD_INSTALL_VERIFY_CMD RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT RESEARCH_SDD_KIT_DIR
export RESEARCH_SDD_KIT_STALE_CHECK=off   # the stale-kit line has its own Go tests; the mini kits here are not checkouts

echo "== verify-skill-drift-hook.test.sh =="

# 1. Existence and 2. executable
[ -f "$SUT" ] && ok "1 hook exists at $SUT" || no "1 hook NOT found at $SUT"
[ -f "$SUT" ] && [ -x "$SUT" ] && ok "2 hook is executable" || no "2 hook NOT executable (missing +x bit)"
if [ ! -f "$SUT" ] || [ ! -f "$ADAPTERS" ]; then echo "== $pass passed · $fail failed =="; exit 2; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The real binary for the end-to-end cases: the caller's RSDD_BIN, else one build into the temp dir.
REAL_BIN="${RSDD_BIN:-}"
if [ -z "$REAL_BIN" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  REAL_BIN="$TMP/rsdd"
fi

# stage_kit DEST [SHIM] — a mini kit: the hook shim (the real one, or a mutant), every toolbelt lib, the real
# adapters.sh and a kit SKILL.md. The toolbelt is DEST/toolbelt.
stage_kit() {
  mkdir -p "$1/toolbelt" "$1/install" "$1/skills/research-sdd"
  cp "${2:-$SUT}" "$1/toolbelt/verify-skill-drift-hook.sh"; chmod +x "$1/toolbelt/verify-skill-drift-hook.sh"
  rsdd_stage_libs "$1/toolbelt" || exit 2
  cp "$ADAPTERS" "$1/install/adapters.sh"
  printf 'kit skill\n' > "$1/skills/research-sdd/SKILL.md"
}
# stub_bin RC OUTPUT — a fake rsdd that records its arguments (one per line) in $TMP/args, prints OUTPUT, exits RC.
stub_bin() {
  printf '%s' "$2" > "$TMP/stub-out.txt"; : > "$TMP/args"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\ncat "%s"\nexit %s\n' "$TMP/args" "$TMP/stub-out.txt" "$1" > "$TMP/stub-rsdd"
  chmod +x "$TMP/stub-rsdd"
}

stage_kit "$TMP/kit"; HOOK="$TMP/kit/toolbelt/verify-skill-drift-hook.sh"
PHYS="$(cd -P "$TMP/kit/toolbelt" && pwd -P)"

# 3. Nothing to flag (the binary is silent, rc 0) → the hook is silent; the binary got the group, the command,
#    --hook and the hook's own directory.
stub_bin 0 ""
OUT="$(RSDD_BIN="$TMP/stub-rsdd" bash "$HOOK" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(tr '\n' ' ' < "$TMP/args")" = "verify skill-drift --hook $PHYS " ]; then
  ok "3 silent → hook silent (exit 0), binary called as 'verify skill-drift --hook <own dir>'"
else no "3 silent → rc=$RC out=[$OUT] args=[$(tr '\n' ' ' < "$TMP/args")]"; fi

# 4. The binary's output and exit code pass through unchanged (the envelope is the binary's work).
ENV='{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"stale"}}
'
stub_bin 0 "$ENV"
OUT="$(RSDD_BIN="$TMP/stub-rsdd" bash "$HOOK" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "${ENV%$'\n'}" ]; then ok "4 binary output passes through, exit 0"; else no "4 passthrough differs (rc=$RC out=[$OUT])"; fi

# 5. Invoked through a symlink in another directory, the hook still names its REAL directory.
mkdir -p "$TMP/elsewhere"; ln -s "$HOOK" "$TMP/elsewhere/link-hook.sh"
stub_bin 0 ""
RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/elsewhere/link-hook.sh" >/dev/null 2>&1
if [ "$(tail -n 1 "$TMP/args")" = "$PHYS" ]; then ok "5 symlinked hook → binary gets the physical own directory"; else no "5 symlink: args=[$(tr '\n' ' ' < "$TMP/args")]"; fi

# 6. rsdd unavailable → exit 0 and a DEGRADED SessionStart envelope (never empty stdout), stderr names the cause.
OUT="$(RSDD_BIN="$TMP/does-not-exist" bash "$HOOK" 2>"$TMP/err6")"; RC=$?
if [ "$RC" -eq 0 ] && grep -q 'Research-SDD hooks DEGRADED: rsdd-unavailable — RSDD_BIN not executable' <<<"$OUT" \
   && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$TMP/err6"; then
  ok "6 rsdd unavailable → rc 0, DEGRADED envelope on stdout, degraded line on stderr"
else no "6 unavailable: rc=$RC out=[$OUT] err=[$(cat "$TMP/err6")]"; fi

# 7. The shim's own lib missing → an announcement on stdout, rc 0 (a hook never fails the session).
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/verify-skill-drift-hook.sh"
OUT="$(bash "$TMP/nolib/verify-skill-drift-hook.sh" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "Research-SDD hook: lib/rsdd-exec.sh missing beside $TMP/nolib/verify-skill-drift-hook.sh" ]; then
  ok "7 missing rsdd-exec.sh → announced, rc 0"
else no "7 missing lib: rc=$RC out=[$OUT]"; fi

# ---- end to end against the real binary ----
HOMEDIR="$TMP/home"; DEP="$HOMEDIR/.claude/skills/research-sdd/SKILL.md"
mkdir -p "$(dirname "$DEP")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/install-silent.sh"; chmod +x "$TMP/install-silent.sh"
real() { RSDD_BIN="$REAL_BIN" HOME="$HOMEDIR" RESEARCH_SDD_PROFILE=claude RESEARCH_SDD_INSTALL_VERIFY_CMD="${1:-$TMP/install-silent.sh}" bash "$HOOK" 2>&1; }
ctx() { jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null; }

# 8. In sync, nothing from install --verify → silent.
cp "$TMP/kit/skills/research-sdd/SKILL.md" "$DEP"
OUT="$(real)"; RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "8 real binary, in sync → silent, exit 0"; else no "8 in sync not silent (rc=$RC out=[$OUT])"; fi

# 9. A hand-edited deployed skill → a SessionStart envelope: the stale header, the fix command, the summary.
echo edited > "$DEP"
OUT="$(real)"; RC=$?; C="$(ctx <<<"$OUT")"
if [ "$RC" -eq 0 ] && [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$OUT" 2>/dev/null)" = SessionStart ] \
   && [[ "$C" == "WARN: research-sdd SKILL.md stale for one or more harnesses — run the fix command(s) shown"* ]] \
   && grep -q 'research-sdd-install.sh --harness claude --force-skill' <<<"$C" \
   && grep -q 'verify-skill-drift: all: checked=3 in-sync=0 diverged=1 absent=2 could-not-run=0' <<<"$C"; then
  ok "9 real binary, diverged skill → SessionStart envelope with the stale header and the fix command"
else no "9 diverged: rc=$RC out=[$OUT]"; fi

# 10. install --verify surfaces a typed finding next to an in-sync skill; the hook still exits 0.
cp "$TMP/kit/skills/research-sdd/SKILL.md" "$DEP"
printf '#!/usr/bin/env bash\necho "verify harness=pi status=degraded reason=no-profiles"\n' > "$TMP/install-finding.sh"; chmod +x "$TMP/install-finding.sh"
OUT="$(real "$TMP/install-finding.sh")"; RC=$?; C="$(ctx <<<"$OUT")"
if [ "$RC" -eq 0 ] && [ "$C" = "WARN: research-sdd install --verify reports issues — see lines below
verify harness=pi status=degraded reason=no-profiles" ]; then
  ok "10 real binary, install --verify finding → surfaced under the install header"
else no "10 finding: rc=$RC out=[$OUT]"; fi

# 11. An install command that cannot run is a typed line, never silence.
OUT="$(real "$TMP/no-such-install.sh")"; RC=$?; C="$(ctx <<<"$OUT")"
if [ "$RC" -eq 0 ] && grep -q '^verify: install --verify could not run (not executable: no-such-install.sh)$' <<<"$C"; then
  ok "11 real binary, unusable install command → typed 'could not run' line"
else no "11 unusable install: rc=$RC out=[$OUT]"; fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"

  # A: the own-directory argument dropped → case 3 sees no directory.
  if mk_mut "teeth A: own dir dropped" "$SUT" "$TMP/mutA.sh" 's/ "\$_RSDD_SELF"$//'; then
    stage_kit "$TMP/mA" "$TMP/mutA.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mA/toolbelt/verify-skill-drift-hook.sh" >/dev/null 2>&1
    if [ "$(tr '\n' ' ' < "$TMP/args")" = "verify skill-drift --hook " ]; then ok "teeth A: own dir dropped → case 3 would go RED"; else no "teeth A: mutant still passes the own dir"; fi
  fi
  # B: --hook dropped → the real binary runs the plain check, not the hook → cases 3 and 9.
  if mk_mut "teeth B: --hook dropped" "$SUT" "$TMP/mutB.sh" 's/ --hook / /'; then
    stage_kit "$TMP/mB" "$TMP/mutB.sh"; stub_bin 0 ""
    RSDD_BIN="$TMP/stub-rsdd" bash "$TMP/mB/toolbelt/verify-skill-drift-hook.sh" >/dev/null 2>&1
    if ! grep -qx -- '--hook' "$TMP/args"; then ok "teeth B: --hook dropped → case 3 would go RED"; else no "teeth B: mutant still passes --hook"; fi
  fi
  # C: sweep mode changed to gate → the degraded envelope vanishes (stdout empty) → case 6.
  if mk_mut "teeth C: sweep → gate" "$SUT" "$TMP/mutC.sh" 's/rsdd_exec_hook sweep /rsdd_exec_hook gate /'; then
    stage_kit "$TMP/mC" "$TMP/mutC.sh"
    OUT="$(RSDD_BIN="$TMP/does-not-exist" bash "$TMP/mC/toolbelt/verify-skill-drift-hook.sh" 2>/dev/null)"
    if [ -z "$OUT" ]; then ok "teeth C: gate degraded mode → empty stdout, case 6 would go RED"; else no "teeth C: mutant still emits [$OUT]"; fi
  fi
  # D: the missing-lib guard stripped → no announcement → case 7.
  if mk_mut "teeth D: guard removed" "$SUT" "$TMP/mutD.sh" 's/ 2>\/dev\/null || { printf .*exit 0; }//'; then
    mkdir -p "$TMP/mD"; cp "$TMP/mutD.sh" "$TMP/mD/verify-skill-drift-hook.sh"
    OUT="$(bash "$TMP/mD/verify-skill-drift-hook.sh" 2>/dev/null)"
    if [ -z "$OUT" ]; then ok "teeth D: unguarded hook is silent when the lib is missing → case 7 would go RED"; else no "teeth D: mutant still announces [$OUT]"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1

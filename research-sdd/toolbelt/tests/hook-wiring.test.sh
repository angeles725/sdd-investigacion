#!/usr/bin/env bash
# hook-wiring.test.sh — regression harness for lib/hook-wiring.sh (kit issue #1108/#1109): the
# single source of truth for "is this target's Stop hook registered to run retro-gate?", shared
# by sweep-retros.sh's WIRING-STATUS fleet pass, verify-registry.sh's 'hook yes' claim check, and
# research-sdd-status.sh's per-target self-report line.
#
# Two entry points are pinned:
#   hook_stop_wiring_state_var <dir>  — sets $HOOK_WIRING_STATE, no subshell fork. sweep-retros.sh
#                                        uses this in its per-target WIRING-STATUS loop (kit issue
#                                        #1108 round 2: a redundant fork per fleet target measured
#                                        as a real RSDD_PROFILE regression).
#   hook_stop_wiring_state <dir>      — convenience wrapper, echoes the state for $(...) capture.
#                                        Used where the caller only needs the state once.
#
# Mutation teeth mutate a COPY of the LIB FILE on disk and source THAT (never a hand-redefined
# stand-in function called directly) — a stand-in only proves the test file's own inline logic
# runs, not that the real implementation reacts to a real mutation (kit issue #1108 round 2 RDD
# finding: the prior teeth here redefined hook_stop_wiring_state() as a constant and called it
# directly, which is circular — it could not have caught a real regression in the sourced lib).
#
# Usage: hook-wiring.test.sh [--prove-teeth]
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/hook-wiring.sh"
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== hook-wiring.test.sh =="

# shellcheck source=../lib/hook-wiring.sh
. "$LIB"
declare -F hook_stop_wiring_state >/dev/null 2>&1 || { echo "FATAL: $LIB did not define hook_stop_wiring_state" >&2; exit 2; }
declare -F hook_stop_wiring_state_var >/dev/null 2>&1 || { echo "FATAL: $LIB did not define hook_stop_wiring_state_var" >&2; exit 2; }

# wire_settings <dir> <json> : write <dir>/.claude/settings.json
wire_settings() { mkdir -p "$1/.claude"; printf '%s' "$2" > "$1/.claude/settings.json"; }

# assert_state <case-label> <dir> <expected>
# Runs BOTH entry points against the same fixture and requires them to agree — the wrapper is a
# thin pass-through, so any disagreement means the wrapper drifted from the fork-free core.
assert_state() {
  local label="$1" d="$2" want="$3" got_wrap got_var
  got_wrap="$(hook_stop_wiring_state "$d")"
  hook_stop_wiring_state_var "$d"; got_var="$HOOK_WIRING_STATE"
  if [ "$got_wrap" = "$want" ] && [ "$got_var" = "$want" ]; then
    ok "$label"
  else
    no "$label" "wrapper=[$got_wrap] var=[$got_var] want=[$want]"
  fi
}

# 1 — no .claude/settings.json at all → absent-settings.
d="$ROOT/t1"; mkdir -p "$d"
assert_state "1 no settings.json → absent-settings" "$d" "absent-settings"

# 2 — settings.json registers retro-gate under Stop → wired.
d="$ROOT/t2"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
assert_state "2 Stop registers retro-gate → wired" "$d" "wired"

# 3 — settings.json exists but no retro-gate anywhere → unwired.
d="$ROOT/t3"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/other-hook.sh"}]}]}}'
assert_state "3 Stop present, no retro-gate → unwired" "$d" "unwired"

# 4 — retro-gate appears ONLY under SessionStart (not Stop) → unwired (scoped strictly to Stop).
d="$ROOT/t4"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"/x/retro-gate.sh"}]}]}}'
assert_state "4 retro-gate under SessionStart only → unwired (not Stop)" "$d" "unwired"

# 5 — retro-gate appears in permissions.deny (not under Stop) → unwired.
d="$ROOT/t5"; mkdir -p "$d"
wire_settings "$d" '{"permissions":{"deny":["Bash(retro-gate:*)"]},"hooks":{"Stop":[]}}'
assert_state "5 retro-gate in permissions.deny → unwired" "$d" "unwired"

# 6 — settings.json unreadable (chmod 000) → unreadable. Skipped when running as root (root
#     bypasses permission bits, matching sweep-retros.test.sh's own skip convention).
if [ "$(id -u)" != "0" ]; then
  d="$ROOT/t6"; mkdir -p "$d"
  wire_settings "$d" '{"hooks":{"Stop":[]}}'
  chmod 000 "$d/.claude/settings.json"
  assert_state "6 unreadable settings.json → unreadable" "$d" "unreadable"
  chmod 644 "$d/.claude/settings.json"   # restore so cleanup works
else
  echo "  SKIP  6 unreadable settings.json → unreadable (running as root; permission bits bypassed)"
fi

# 7 — non-existent target dir → absent-settings (never a crash).
d="$ROOT/t7-absent"
assert_state "7 non-existent target dir → absent-settings" "$d" "absent-settings"

echo ""
printf '== %d passed · %d failed ==\n' "$pass" "$fail"

# --- mutation teeth ("--prove-teeth") --------------------------------------------------------------
# Each mutant is a COPY of the real lib file with ONE line changed, sourced fresh in a subshell —
# never a hand-redefined function called directly (RDD finding, see header). Running the REAL
# hook_stop_wiring_state_var against the mutated COPY proves the SOURCED implementation reacts to
# a real code change, not that the test file's own inline stand-in behaves as scripted.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: force the awk always-found (END { exit 0 }) — case 3 must go RED --"
  mut_wired="$ROOT/hook-wiring.MUTANT-always-wired.sh"
  if ! grep -qF 'END { exit !found }' "$LIB"; then
    no "teeth: locate 'END { exit !found }' anchor in lib — drifted?"
  else
    sed 's/END { exit !found }/END { exit 0 }  # MUTANT: always found/' "$LIB" > "$mut_wired"
    (
      # The outer script already sourced the REAL lib, so these names are already declared in
      # this subshell (subshells inherit the parent's functions). Unset first, or the mutant
      # lib's idempotency guard (`if ! declare -F ...`) sees them as already defined and skips
      # its own redefinition — the mutant would silently never take effect.
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var
      # shellcheck disable=SC1090
      . "$mut_wired"
      d="$ROOT/t3"
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "unwired" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 3 (unwired misreported as wired)"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: always-found awk mutation caught (real sourced lib)"; else no "teeth: always-found awk mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: collapse absent-settings assignment into 'unwired' — case 1 must go RED --"
  mut_absent="$ROOT/hook-wiring.MUTANT-absent-collapse.sh"
  if ! grep -qF 'HOOK_WIRING_STATE="absent-settings"; return 0' "$LIB"; then
    no "teeth: locate absent-settings assignment anchor in lib — drifted?"
  else
    sed 's/HOOK_WIRING_STATE="absent-settings"; return 0/HOOK_WIRING_STATE="unwired"; return 0  # MUTANT: collapsed/' "$LIB" > "$mut_absent"
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var
      # shellcheck disable=SC1090
      . "$mut_absent"
      d="$ROOT/t1"
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "absent-settings" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 1 (absent-settings collapsed into unwired)"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: absent-settings/unwired collapse mutation caught (real sourced lib)"; else no "teeth: absent-settings/unwired collapse mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: force hook_stop_wiring_state_var (fork-free path) to always set 'wired' — case 6 must go RED --"
  mut_var="$ROOT/hook-wiring.MUTANT-var-always-wired.sh"
  if ! grep -qF 'HOOK_WIRING_STATE="unreadable"; return 0' "$LIB"; then
    no "teeth: locate unreadable assignment anchor in lib — drifted?"
  else
    sed 's/HOOK_WIRING_STATE="unreadable"; return 0/HOOK_WIRING_STATE="wired"; return 0  # MUTANT: unreadable forced wired/' "$LIB" > "$mut_var"
    if [ "$(id -u)" != "0" ]; then
      # Fresh fixture — case 6's own $ROOT/t6 was already chmod-644-restored above for cleanup,
      # so reusing it here would silently test the awk path instead of the unreadable branch.
      d_t6b="$ROOT/t6b-teeth"; mkdir -p "$d_t6b"
      wire_settings "$d_t6b" '{"hooks":{"Stop":[]}}'
      chmod 000 "$d_t6b/.claude/settings.json"
      (
        unset -f hook_stop_wiring_state hook_stop_wiring_state_var
        # shellcheck disable=SC1090
        . "$mut_var"
        d="$d_t6b"
        hook_stop_wiring_state_var "$d"
        if [ "$HOOK_WIRING_STATE" = "unreadable" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
        else echo "  PASS  teeth: mutant correctly breaks case 6 via the fork-free entry point"; exit 0; fi
      )
      _t6b_rc=$?
      chmod 644 "$d_t6b/.claude/settings.json"   # restore so cleanup can remove it
      if [ "$_t6b_rc" -eq 0 ]; then ok "teeth: hook_stop_wiring_state_var unreadable mutation caught (real sourced lib)"; else no "teeth: hook_stop_wiring_state_var unreadable mutation NOT caught (theater)"; fi
    else
      echo "  SKIP  teeth: hook_stop_wiring_state_var unreadable mutation (running as root)"
    fi
  fi
fi

[ "$fail" -eq 0 ] && exit 0 || exit 1

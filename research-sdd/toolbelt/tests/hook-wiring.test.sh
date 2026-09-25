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
# HERMETICITY (kit issue #1140 round-2 review, Blocking 4): the git-root walk-up in
# lib/hook-wiring.sh climbs from a target all the way to `/` unless RSDD_HOOK_WIRING_CEILING is
# set. `$ROOT` below comes from `mktemp -d`, which honors `$TMPDIR` — if `$TMPDIR` ever points
# inside a REAL git repository (this kit checkout is one), every fixture in this suite meant to
# model "clean git root" or "no git repo at all" would silently pick up the ENCLOSING repo's real
# `.git` instead. The ceiling is set once, globally, right after `$ROOT` is created, so this is not
# a per-fixture concern for the rest of the suite; cases 13a/13b below reproduce the bug and prove
# the ceiling is what fixes it, with $TMPDIR genuinely pointed inside a repo.
#
# Usage: hook-wiring.test.sh [--prove-teeth]
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/hook-wiring.sh"
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$ROOT")"
export RSDD_HOOK_WIRING_CEILING
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

# --- kit issue #1135: 'wired-off-root' — settings.json is syntactically wired but the registered
# path is NOT its own git root (an ancestor owns the nearest `.git`). Downgrade applies ONLY to
# the wired case: an unwired/absent-settings/unreadable target off-root makes no active-firing
# claim, so there is nothing false to downgrade.

# 8 — POSITIVE CONTROL: registered path IS its own git root (git init'd there directly) and wired →
#     stays 'wired', never downgraded. Pins that a normal git-root target is unaffected.
d="$ROOT/t8-root"; mkdir -p "$d"
git init -q "$d" >/dev/null 2>&1
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
assert_state "8 registered path is its own git root, wired → wired (unaffected)" "$d" "wired"

# 9 — the three.js SHAPE (structural fact only — kit issue #1140 round-2 review: this predicate
#     does NOT know or claim where sessions actually launch from; see lib/hook-wiring.sh's own
#     header): registered path is a NESTED subdirectory of a git repo (git root is an ancestor),
#     settings.json wired at the nested path → wired-off-root, not wired.
d_root="$ROOT/t9-gitroot"; d="$d_root/nested"; mkdir -p "$d"
git init -q "$d_root" >/dev/null 2>&1
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
assert_state "9 nested non-root path, wired → wired-off-root (three.js shape)" "$d" "wired-off-root"

# 10 — a nested non-root path that is UNWIRED must stay 'unwired', never 'wired-off-root': no
#     active-firing claim is being made, so there is nothing to downgrade (matches kit issue #1135's
#     own fixture scope: "a nested non-root row with hook no/deferred — no WARN").
d_root="$ROOT/t10-gitroot"; d="$d_root/nested"; mkdir -p "$d"
git init -q "$d_root" >/dev/null 2>&1
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/other-hook.sh"}]}]}}'
assert_state "10 nested non-root path, unwired → unwired (not downgraded)" "$d" "unwired"

# 11 — a nested non-root path with NO settings.json at all must stay 'absent-settings', never
#     'wired-off-root' — the downgrade only ever applies to an already-'wired' result.
d_root="$ROOT/t11-gitroot"; d="$d_root/nested"; mkdir -p "$d"
git init -q "$d_root" >/dev/null 2>&1
assert_state "11 nested non-root path, no settings.json → absent-settings (not downgraded)" "$d" "absent-settings"

# 12 — registered path is NOT inside any git repository at all (walk-up reaches `/` with no `.git`
#     found) and wired → stays 'wired'. No git root to compare against, so nothing is downgraded.
d="$ROOT/t12-nogit"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
assert_state "12 not inside any git repo, wired → wired (no root to compare)" "$d" "wired"

# --- kit issue #1140 round-2 review, Blocking 4: TMPDIR-inside-a-repo hermeticity ------------------
# Reproduces the exact bug class this suite's own $RSDD_HOOK_WIRING_CEILING (set above) protects
# against, with $TMPDIR genuinely pointed inside a real git repository: without a ceiling, the
# walk-up (correctly, by design) keeps climbing past a fixture's own sandbox root and finds the
# ENCLOSING repo's real `.git`, misreporting a plain wired target as wired-off-root. This builds
# its own throwaway enclosing repo (never touches the actual kit checkout) so the reproduction is
# fully self-contained.
_encl="$ROOT/t13-enclosing-repo"; mkdir -p "$_encl"
git init -q "$_encl" >/dev/null 2>&1
_old_tmpdir="${TMPDIR:-}"; _had_tmpdir=0; [ -n "${TMPDIR+x}" ] && _had_tmpdir=1
TMPDIR="$_encl"; export TMPDIR
_inner_root="$(mktemp -d)"   # now lands under $_encl — simulates a host whose real $TMPDIR sits inside a repo
d="$_inner_root/target-no-own-git"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'

# 13a — CONTROL, no per-fixture ceiling: proves the bleed-in bug is real, not hypothetical. The
#      suite-wide ceiling (dirname of $ROOT) does not reach this far down — $_encl is BELOW it — so
#      this reproduces exactly what an unset RSDD_HOOK_WIRING_CEILING would do on a real host whose
#      $TMPDIR sits inside a repo.
_saved_ceiling="$RSDD_HOOK_WIRING_CEILING"
unset RSDD_HOOK_WIRING_CEILING
r13a="$(hook_stop_wiring_state "$d")"
if [ "$r13a" = "wired-off-root" ]; then
  ok "13a (control) TMPDIR inside a repo, no ceiling → enclosing repo's .git bleeds in, misreports wired-off-root (bug reproduced)"
else
  no "13a (control) TMPDIR inside a repo, no ceiling → expected the bleed-in bug to reproduce" "got [$r13a]"
fi
export RSDD_HOOK_WIRING_CEILING="$_saved_ceiling"

# 13b — WITH a ceiling set to $_encl (this fixture's own enclosing-repo boundary — the realistic
#      choice a suite makes: "don't look above my own sandbox"), the walk-up never scans $_encl at
#      all and correctly reports plain 'wired'. This is the actual fix under test.
export RSDD_HOOK_WIRING_CEILING="$_encl"
assert_state "13b ceiling set to the enclosing repo boundary → correctly 'wired', bleed-in blocked" "$d" "wired"
export RSDD_HOOK_WIRING_CEILING="$_saved_ceiling"

rm -rf "$_inner_root"
if [ "$_had_tmpdir" -eq 1 ]; then TMPDIR="$_old_tmpdir"; export TMPDIR; else unset TMPDIR; fi

# --- kit issue #1140 round-2 review, smaller items: symlink handling ---------------------------
# The pure-builtin walk-up needs no `pwd -P` / `cd -P` canonicalization step for the LEAF case:
# `[ -e ]` resolves a symlink AT the final path component at the kernel level, so a target that IS
# (or directly contains) a real `.git` resolves correctly even through a leaf symlink. An
# INTERMEDIATE symlinked component is a KNOWN, documented limitation (see lib/hook-wiring.sh's own
# header on _hw_find_git_root): the walk climbs the target STRING's textual ancestors, not the
# symlink's resolution target, so it is a false negative (stays 'wired'), never a false positive.

# 14a — DOCUMENTED LIMITATION, pinned so a future change is deliberate, not silent: target reached
#      via a symlinked INTERMEDIATE component, landing nested under the real (but textually
#      unreachable) git root → stays 'wired' (a false negative — see lib header), not a crash and
#      not a false 'wired-off-root' WARN either way. If this pin ever needs to flip to
#      'wired-off-root', that is a deliberate feature add (a fork-based fallback), not a
#      regression — update this test alongside it.
d_real_root="$ROOT/t14-real-repo"; mkdir -p "$d_real_root/real-nested"
git init -q "$d_real_root" >/dev/null 2>&1
wire_settings "$d_real_root/real-nested" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
d_link="$ROOT/t14a-link-to-nested"
ln -s "$d_real_root/real-nested" "$d_link"
assert_state "14a DOCUMENTED LIMITATION: symlinked intermediate component → stays 'wired' (false negative, not a crash or false WARN)" "$d_link" "wired"

# 14b — the LEAF case works correctly: a leaf symlink pointing DIRECTLY at a git root (settings.json
#      wired there) → stays 'wired', not off-root (this is the case `[ -e ]` resolves for free).
d_real_root2="$ROOT/t14b-real-root2"; mkdir -p "$d_real_root2"
git init -q "$d_real_root2" >/dev/null 2>&1
wire_settings "$d_real_root2" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
d_link_root="$ROOT/t14b-link-to-root2"
ln -s "$d_real_root2" "$d_link_root"
assert_state "14b leaf symlink pointing directly AT a git root, wired → wired (not off-root)" "$d_link_root" "wired"

# --- 15a/15b/15c — RELATIVE-PATH INFINITE LOOP (RDD correction, kit issue #1140) ----------------
# A relative target ('.', 'foo', 'foo/bar' -> 'foo') gave ${d%/*} no "/" to climb past, so the
# walk-up spun forever — a real caller shape (e.g. research-sdd-status.sh invoked as '.'), not
# synthetic. Each case runs in a fresh subprocess under `timeout` so a regression fails loudly.
run_relative_case() {
  local label="$1" cwd="$2" target="$3" want="$4" out rc
  out="$(cd "$cwd" && timeout 10 "$BASH_BIN" -c ". \"$LIB\"; hook_stop_wiring_state \"$target\"" 2>&1)"
  rc=$?
  if [ "$rc" -eq 124 ]; then no "$label" "TIMED OUT (infinite loop) after 10s"
  elif [ "$rc" -eq 0 ] && [ "$out" = "$want" ]; then ok "$label" "-> $out"
  else no "$label" "rc=$rc out=[$out] want=[$want]"; fi
}
d15a="$ROOT/t15a-dot-selfroot"; mkdir -p "$d15a"; git init -q "$d15a" >/dev/null 2>&1
wire_settings "$d15a" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
run_relative_case "15a relative target '.' at its own git root → wired (no hang)" "$d15a" "." "wired"
mkdir -p "$ROOT/t15b-bare-norepo"
wire_settings "$ROOT/t15b-bare-norepo" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
run_relative_case "15b relative target (no slash), no ancestor .git under ceiling → wired (no hang)" "$ROOT" "t15b-bare-norepo" "wired"
d15c_root="$ROOT/t15c-repo"; mkdir -p "$d15c_root/nested"; git init -q "$d15c_root" >/dev/null 2>&1
wire_settings "$d15c_root/nested" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
run_relative_case "15c relative target 'nested' inside a repo → wired-off-root (no hang)" "$d15c_root" "nested" "wired-off-root"

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
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
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
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
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
        unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
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

  echo "-- teeth: neuter the wired-off-root downgrade assignment — case 9 must go RED (stays 'wired') --"
  mut_offroot_neuter="$ROOT/hook-wiring.MUTANT-offroot-neuter.sh"
  if ! grep -qF 'HOOK_WIRING_STATE="wired-off-root"' "$LIB"; then
    no "teeth: locate wired-off-root assignment anchor in lib — drifted?"
  else
    sed 's/HOOK_WIRING_STATE="wired-off-root"/: # MUTANT: neutered/' "$LIB" > "$mut_offroot_neuter"
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_offroot_neuter"
      d_root="$ROOT/t9-teeth-neuter"; d="$d_root/nested"; mkdir -p "$d"
      git init -q "$d_root" >/dev/null 2>&1
      wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "wired-off-root" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 9 (off-root false-reported as plain wired)"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: wired-off-root downgrade-neuter mutation caught (real sourced lib)"; else no "teeth: wired-off-root downgrade-neuter mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: widen the git-root comparison to always-mismatch — case 8 must go RED (a clean git-root target would be misreported off-root) --"
  mut_offroot_always="$ROOT/hook-wiring.MUTANT-offroot-always.sh"
  if ! grep -qF 'if [ -n "$HW_GIT_ROOT" ] && [ "$HW_GIT_ROOT" != "$_hw_target_norm" ]; then  # WIRED-OFF-ROOT-CHECK' "$LIB"; then
    no "teeth: locate WIRED-OFF-ROOT-CHECK comparison anchor in lib — drifted?"
  else
    sed 's/if \[ -n "\$HW_GIT_ROOT" \] \&\& \[ "\$HW_GIT_ROOT" != "\$_hw_target_norm" \]; then  # WIRED-OFF-ROOT-CHECK/if [ -n "$HW_GIT_ROOT" ]; then  # MUTANT: comparison dropped, always mismatches when a root is found/' "$LIB" > "$mut_offroot_always"
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_offroot_always"
      d="$ROOT/t8-teeth-always"; mkdir -p "$d"
      git init -q "$d" >/dev/null 2>&1
      wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "wired" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 8 (clean git-root target misreported [$r])"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: git-root comparison always-mismatch mutation caught (real sourced lib)"; else no "teeth: git-root comparison always-mismatch mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: drop the '[ -n \"\$HW_GIT_ROOT\" ]' guard — case 12 must go RED (a non-repo target would be misreported off-root) --"
  mut_hwg_guard="$ROOT/hook-wiring.MUTANT-hwgroot-null-guard.sh"
  if ! grep -qF 'if [ -n "$HW_GIT_ROOT" ] && [ "$HW_GIT_ROOT" != "$_hw_target_norm" ]; then  # WIRED-OFF-ROOT-CHECK' "$LIB"; then
    no "teeth: locate WIRED-OFF-ROOT-CHECK null-guard anchor in lib — drifted?"
  else
    sed 's/if \[ -n "\$HW_GIT_ROOT" \] \&\& \[ "\$HW_GIT_ROOT" != "\$_hw_target_norm" \]; then  # WIRED-OFF-ROOT-CHECK/if [ "$HW_GIT_ROOT" != "$_hw_target_norm" ]; then  # MUTANT: null-guard dropped/' "$LIB" > "$mut_hwg_guard"
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_hwg_guard"
      d="$ROOT/t12-teeth-nullguard"; mkdir -p "$d"
      wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "wired" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 12 (non-repo target misreported [$r] — empty HW_GIT_ROOT != any target string)"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: null-guard-dropped mutation caught (real sourced lib)"; else no "teeth: null-guard-dropped mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: neuter HOOK-WIRING-GITDIR-CHECK ('.git' existence test) — case 9 must go RED (off-root target never finds any git root) --"
  mut_gitdir="$ROOT/hook-wiring.MUTANT-gitdir-check.sh"
  if ! grep -qF 'if [ -e "$d/.git" ]; then  # HOOK-WIRING-GITDIR-CHECK' "$LIB"; then
    no "teeth: locate HOOK-WIRING-GITDIR-CHECK anchor in lib — drifted?"
  else
    sed 's/if \[ -e "\$d\/\.git" \]; then  # HOOK-WIRING-GITDIR-CHECK/if false; then  # MUTANT: gitdir check neutered/' "$LIB" > "$mut_gitdir"
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_gitdir"
      d_root="$ROOT/t9-teeth-gitdir"; d="$d_root/nested"; mkdir -p "$d"
      git init -q "$d_root" >/dev/null 2>&1
      wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "wired-off-root" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 9 ('.git' never found, stays plain wired [$r])"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: HOOK-WIRING-GITDIR-CHECK neuter mutation caught (real sourced lib)"; else no "teeth: HOOK-WIRING-GITDIR-CHECK neuter mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: neuter HOOK-WIRING-CEILING-CHECK — case 13b must go RED (ceiling no longer stops the walk-up before the enclosing repo) --"
  mut_ceiling="$ROOT/hook-wiring.MUTANT-ceiling-check.sh"
  if ! grep -qF 'if [ -n "$ceiling" ] && [ "$d" = "$ceiling" ]; then  # HOOK-WIRING-CEILING-CHECK' "$LIB"; then
    no "teeth: locate HOOK-WIRING-CEILING-CHECK anchor in lib — drifted?"
  else
    sed 's/if \[ -n "\$ceiling" \] \&\& \[ "\$d" = "\$ceiling" \]; then  # HOOK-WIRING-CEILING-CHECK/if false; then  # MUTANT: ceiling check neutered/' "$LIB" > "$mut_ceiling"
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_ceiling"
      _mc_encl="$ROOT/t13-teeth-enclosing"; mkdir -p "$_mc_encl"
      git init -q "$_mc_encl" >/dev/null 2>&1
      _mc_old_tmpdir="${TMPDIR:-}"; _mc_had=0; [ -n "${TMPDIR+x}" ] && _mc_had=1
      TMPDIR="$_mc_encl"; export TMPDIR
      _mc_inner="$(mktemp -d)"
      d="$_mc_inner/target"; mkdir -p "$d"
      wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
      export RSDD_HOOK_WIRING_CEILING="$_mc_encl"
      r="$(hook_stop_wiring_state "$d")"
      rm -rf "$_mc_inner"
      if [ "$_mc_had" -eq 1 ]; then TMPDIR="$_mc_old_tmpdir"; export TMPDIR; else unset TMPDIR; fi
      if [ "$r" = "wired" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 13b (ceiling ignored, enclosing repo bleeds in again [$r])"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: HOOK-WIRING-CEILING-CHECK neuter mutation caught (real sourced lib)"; else no "teeth: HOOK-WIRING-CEILING-CHECK neuter mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: drop the abspath prefix AND the no-progress guard — case 15b must go RED (reproduces the original infinite loop) --"
  mut_relhang="$ROOT/hook-wiring.MUTANT-relpath-hang.sh"
  if ! grep -qF '*)  d="$PWD/$d" ;;' "$LIB" || ! grep -qF '# HOOK-WIRING-NOPROGRESS-GUARD' "$LIB"; then
    no "teeth: locate abspath-prefix or no-progress-guard anchor in lib — drifted?"
  else
    sed -e 's/\*)  d="\$PWD\/\$d" ;;/*)  : ;;  # MUTANT: absolutization dropped/' \
        -e 's/if \[ "\$_hw_next" = "\$d" \]; then  # HOOK-WIRING-NOPROGRESS-GUARD.*/if false; then  # MUTANT: no-progress guard dropped/' \
        "$LIB" > "$mut_relhang"
    d_relhang="$ROOT/t15b-teeth-norepo"; mkdir -p "$d_relhang"
    wire_settings "$d_relhang" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
    out_relhang="$(cd "$ROOT" && timeout 10 "$BASH_BIN" -c ". \"$mut_relhang\"; hook_stop_wiring_state \"t15b-teeth-norepo\"" 2>&1)"
    rc_relhang=$?
    if [ "$rc_relhang" -eq 124 ]; then
      ok "teeth: relative-path abspath+no-progress-guard mutation caught (real sourced lib, timed out as expected)"
    else
      no "teeth: relative-path abspath+no-progress-guard mutation NOT caught (theater)" "rc=$rc_relhang out=[$out_relhang]"
    fi
  fi
fi

echo ""
printf '== %d passed · %d failed ==\n' "$pass" "$fail"

[ "$fail" -eq 0 ] && exit 0 || exit 1

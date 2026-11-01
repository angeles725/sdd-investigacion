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
# The first half of the lib (wiring state, script state, git-root walk-up) is a shim over `rsdd hook ...` (kit issue #2356,
# U2.3a), so every case below goes through the Go binary. Use $RSDD_BIN when the caller set one (run-all.sh exports it);
# otherwise resolve - and if need be build - the binary exactly as a shim would (lib/rsdd-exec.sh).
if [ -z "${RSDD_BIN:-}" ]; then
  RSDD_BIN="$( . "$HERE/../lib/rsdd-exec.sh" 2>/dev/null && _rsdd_exec_resolve 2>/dev/null && printf '%s' "$_RSDD_EXEC_BIN" )" || RSDD_BIN=""
  [ -n "$RSDD_BIN" ] || { echo "FATAL: rsdd is unavailable (set RSDD_BIN, or install Go / build research-sdd/bin/rsdd): lib/hook-wiring.sh cannot be exercised" >&2; exit 2; }
fi
export RSDD_BIN

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

# 13a — CONTROL, no per-fixture ceiling: proves the TMPDIR-bleed-in HAZARD is real, not
#      hypothetical (kit r3 review nit — distinct from case 9: case 9's 'wired-off-root' is the
#      PRODUCT correctly detecting a deliberately nested target; this case's SAME-LOOKING outcome
#      has a different CAUSE — an unrelated enclosing repo bleeding into a fixture never meant to
#      be nested at all, purely because $TMPDIR happens to sit inside one). The suite-wide ceiling
#      (dirname of $ROOT) does not reach this far down — $_encl is BELOW it — so this reproduces
#      exactly what an unset RSDD_HOOK_WIRING_CEILING would do on a real host whose $TMPDIR sits
#      inside a repo.
_saved_ceiling="$RSDD_HOOK_WIRING_CEILING"
unset RSDD_HOOK_WIRING_CEILING
r13a="$(hook_stop_wiring_state "$d")"
if [ "$r13a" = "wired-off-root" ]; then
  ok "13a (control) TMPDIR inside a repo, no ceiling → unrelated enclosing repo bleeds in (hermeticity hazard reproduced, not case 9's intentional detection)"
else
  no "13a (control) TMPDIR inside a repo, no ceiling → expected the bleed-in hazard to reproduce" "got [$r13a]"
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

# --- kit r3 review, M2: symlink handling (CORRECTED — 14a was mislabeled "intermediate
# component"; it is a LEAF symlink) --------------------------------------------------------------
# `[ -e ]` resolves a symlink AT the final path component at the kernel level, so a LEAF symlink
# pointing DIRECTLY at a git root resolves correctly on the FIRST check, before any climbing (14b).
# A leaf symlink pointing at a NESTED, non-root directory does NOT (14a): once the walk needs to
# climb past the leaf, it climbs the SYMLINK'S OWN textual path, not the resolved target's real
# ancestors, so it is a false negative (stays 'wired'), never a false positive. A genuinely
# INTERMEDIATE symlinked path component is a distinct, untested shape with the same root cause —
# see lib/hook-wiring.sh's own header on _hw_find_git_root.

# 14a — DOCUMENTED LIMITATION, pinned so a future change is deliberate, not silent: a LEAF symlink
#      pointing at a NESTED (non-root) real directory → stays 'wired' (a false negative — see lib
#      header), not a crash and not a false 'wired-off-root' WARN either way. If this pin ever
#      needs to flip to 'wired-off-root', that is a deliberate feature add (a fork-based
#      fallback), not a regression — update this test alongside it.
d_real_root="$ROOT/t14-real-repo"; mkdir -p "$d_real_root/real-nested"
git init -q "$d_real_root" >/dev/null 2>&1
wire_settings "$d_real_root/real-nested" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
d_link="$ROOT/t14a-link-to-nested"
ln -s "$d_real_root/real-nested" "$d_link"
assert_state "14a DOCUMENTED LIMITATION: leaf symlink to a NESTED dir → stays 'wired' (false negative, not a crash or false WARN)" "$d_link" "wired"

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

# --- 16 — DOTDOT DISTRACTOR (kit r3 review, M1): a '..' component must be COLLAPSED before the
#      walk-up runs, not stripped one raw textual segment at a time. Target = ".../A/B/.." really
#      resolves to ".../A" (no .git of its own); ".../A/B" is an UNRELATED nested repo (B has its
#      own .git, A does not). Un-normalized, the walk-up's first miss at ".../A/B/../.git" climbs
#      by stripping the trailing '..' segment (not collapsing it), landing on the REAL directory
#      ".../A/B" and finding B's irrelevant .git there — a FALSE 'wired-off-root' for a target that
#      (correctly resolved) is not in any repo at all and should stay plain 'wired'.
d16_a="$ROOT/t16-dotdot/A"; d16_b="$d16_a/B"; mkdir -p "$d16_b"
wire_settings "$d16_a" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
git init -q "$d16_b" >/dev/null 2>&1
assert_state "16 dotdot distractor: '.../A/B/..' resolves to A (no repo) → wired, B's nested .git ignored" "$d16_a/B/.." "wired"

# --- 17 — CEILING TRAILING SLASH (kit r3 review, M3): $RSDD_HOOK_WIRING_CEILING is compared
#      TEXTUALLY against the walk-up's (normalized, no trailing slash) $d, so the lib normalizes
#      the ceiling through _hw_abspath first. This case pins that: a ceiling with a trailing slash
#      still stops the walk-up, so the enclosing repo does not bleed in (case 13a's un-ceilinged
#      control shows what bleeding looks like). Reuses case 13's TMPDIR-inside-
#      a-repo fixture shape with a fresh enclosing dir so it cannot collide with case 13's cleanup.
_encl17="$ROOT/t17-enclosing"; mkdir -p "$_encl17"; git init -q "$_encl17" >/dev/null 2>&1
_old_tmpdir17="${TMPDIR:-}"; _had17=0; [ -n "${TMPDIR+x}" ] && _had17=1
TMPDIR="$_encl17"; export TMPDIR
_inner17="$(mktemp -d)"
d17="$_inner17/target"; mkdir -p "$d17"
wire_settings "$d17" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
_saved_ceiling17="$RSDD_HOOK_WIRING_CEILING"
export RSDD_HOOK_WIRING_CEILING="$_encl17/"
assert_state "17 ceiling with a trailing slash still blocks the enclosing repo (not silently disabled)" "$d17" "wired"
export RSDD_HOOK_WIRING_CEILING="$_saved_ceiling17"
rm -rf "$_inner17"
if [ "$_had17" -eq 1 ]; then TMPDIR="$_old_tmpdir17"; export TMPDIR; else unset TMPDIR; fi

# --- 18 — SYMLINK BEFORE '..' (kit issue #1153 item 1) -------------------------------------------
# The kernel resolves '..' AFTER following a symlink, but the textual collapse in _hw_abspath does
# not: target ".../P/sub/link/.." (link -> Q/y/z) really names Q/y, a git root of its own and the
# directory holding the wired settings.json, yet collapses to ".../P/sub" inside enclosing repo P.
# That used to report a false 'wired-off-root'. The raw "$target/.git" check answers it first.
d18_p="$ROOT/t18-P"; d18_q="$ROOT/t18-Q"
mkdir -p "$d18_p/sub" "$d18_q/y/z"
git init -q "$d18_p" >/dev/null 2>&1; git init -q "$d18_q/y" >/dev/null 2>&1
ln -s "$d18_q/y/z" "$d18_p/sub/link"
wire_settings "$d18_q/y" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
assert_state "18 symlink-before-'..' resolving to a wired git root → wired (not a false off-root)" "$d18_p/sub/link/.." "wired"

# --- 19 — EMBEDDED NEWLINE (kit issue #1153 item 5): the path split used to be `read -ra` over a
#      here-string, which stops at the first newline and silently truncated the target. Target
#      ".../t19/a<NL>b" is a plain directory inside enclosing repo t19, so it is off-root. A
#      truncated ".../t19/a" is a different, sibling directory that is its own git root, so the old
#      split reported a false plain 'wired' (the raw-target check cannot rescue this shape: the
#      target itself owns no .git).
d19_p="$ROOT/t19"; d19="$d19_p/a"$'\n'"b"
mkdir -p "$d19" "$d19_p/a"; git init -q "$d19_p" >/dev/null 2>&1; git init -q "$d19_p/a" >/dev/null 2>&1
wire_settings "$d19" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
assert_state "19 embedded newline, nested in a repo → wired-off-root (path not truncated)" "$d19" "wired-off-root"

# --- 20 — NO HERE-STRING (kit issue #1153 item 2): on bash < 5.1 a here-string is backed by a
#      $TMPDIR temp file; if that cannot be created `read` fails, the array stays empty and the path
#      silently becomes '/'. The split must use parameter expansion only. Lint over executable
#      lines (comment lines excluded) of the lib.
# herestring_count FILE : sets HS_N to the number of here-strings on executable lines; rc 2 when
# FILE is unreadable or awk fails, so "0" never means "could not look" (no pipeline: one awk reads
# FILE directly and its own status is checked). Shared by case 20 and its tooth.
herestring_count() {
  HS_N=""
  [ -r "$1" ] || return 2
  HS_N="$(awk '!/^[[:space:]]*#/ && index($0, "<<<") { n++ } END { print n + 0 }' "$1")" || return 2
  return 0
}
# 20a — control: a missing path must be "could not look" (rc 2, empty count), never a clean 0.
herestring_count "$ROOT/no-such-file"; _hs_ctl_rc=$?
if [ "$_hs_ctl_rc" -eq 2 ] && [ -z "$HS_N" ]; then ok "20a here-string lint on a missing file → rc 2, no count (not a silent 0)"
else no "20a here-string lint on a missing file → rc 2, no count" "rc=$_hs_ctl_rc n=[$HS_N]"; fi
if ! herestring_count "$LIB"; then
  no "20 lib here-string lint could not run"
elif [ "$HS_N" -eq 0 ]; then
  ok "20 lib has no here-string on executable lines (no TMPDIR-backed split)"
else
  no "20 lib has no here-string on executable lines" "found $HS_N"
fi

# --- 21 — RAW-TARGET CHECK honors the ceiling (kit issue #1153, RDD review): same shape as case 18
#      (target ".../link/.." whose spelled form owns a .git), but the collapsed path IS the ceiling.
#      The ceiling must still win: HW_GIT_ROOT stays empty instead of echoing the collapsed path.
d21_p="$ROOT/t21-P"; d21_q="$ROOT/t21-Q"
mkdir -p "$d21_p/sub" "$d21_q/y/z"
git init -q "$d21_q/y" >/dev/null 2>&1
ln -s "$d21_q/y/z" "$d21_p/sub/link"
_saved_ceiling21="$RSDD_HOOK_WIRING_CEILING"
export RSDD_HOOK_WIRING_CEILING="$d21_p/sub"
_hw_find_git_root "$d21_p/sub/link/.."
_r21="$HW_GIT_ROOT"
export RSDD_HOOK_WIRING_CEILING="$_saved_ceiling21"
if [ -z "$_r21" ]; then ok "21 raw .git target whose collapsed path is the ceiling → ceiling wins (no root)"
else no "21 raw .git target whose collapsed path is the ceiling → ceiling wins (no root)" "HW_GIT_ROOT=[$_r21]"; fi

# --- 22 — HW_TARGET_IS_ROOT FLAG (kit issue #1696): in the RAW-TARGET branch HW_GIT_ROOT used to be
#      the textually collapsed target, which can name a directory with NO .git. It must now be a real
#      git-root path (here: the spelled target, which owns the .git) and the "target is its own root"
#      answer travels in HW_TARGET_IS_ROOT. The ordinary walk and the ceiling leave the flag 0.
d22_p="$ROOT/t22-P"; d22_q="$ROOT/t22-Q"
mkdir -p "$d22_p/sub" "$d22_q/y/z"
git init -q "$d22_p" >/dev/null 2>&1; git init -q "$d22_q/y" >/dev/null 2>&1
ln -s "$d22_q/y/z" "$d22_p/sub/link"
_hw_find_git_root "$d22_p/sub/link/.."
_r22="$HW_GIT_ROOT"; _f22="$HW_TARGET_IS_ROOT"
if [ "$_f22" = "1" ] && [ -e "$_r22/.git" ]; then ok "22a raw .git target → HW_TARGET_IS_ROOT=1 and HW_GIT_ROOT owns a .git"
else no "22a raw .git target → flag set, HW_GIT_ROOT is a real git root" "flag=[$_f22] root=[$_r22]"; fi
_hw_find_git_root "$d22_p/sub"
if [ "$HW_TARGET_IS_ROOT" = "0" ] && [ "$HW_GIT_ROOT" = "$d22_p" ]; then ok "22b ordinary walk → flag 0, root is the enclosing repo"
else no "22b ordinary walk → flag 0, root is the enclosing repo" "flag=[$HW_TARGET_IS_ROOT] root=[$HW_GIT_ROOT]"; fi
_saved_ceiling22="$RSDD_HOOK_WIRING_CEILING"
export RSDD_HOOK_WIRING_CEILING="$d22_p/sub"
_hw_find_git_root "$d22_p/sub/link/.."
export RSDD_HOOK_WIRING_CEILING="$_saved_ceiling22"
if [ "$HW_TARGET_IS_ROOT" = "0" ] && [ -z "$HW_GIT_ROOT" ]; then ok "22c ceiling wins → flag 0 and empty root"
else no "22c ceiling wins → flag 0 and empty root" "flag=[$HW_TARGET_IS_ROOT] root=[$HW_GIT_ROOT]"; fi

# --- 23 — the string comparison stays reachable (kit issue #1696): spelled target ".../link/.." has
#      no .git, but its collapsed path (the directory holding the link) is a git root equal to the
#      normalized target string → flag 0, root == collapsed → plain 'wired'.
d23_p="$ROOT/t23-P"; mkdir -p "$d23_p" "$ROOT/t23-Q/y/z"
git init -q "$d23_p" >/dev/null 2>&1
ln -s "$ROOT/t23-Q/y/z" "$d23_p/link"
wire_settings "$d23_p/link/.." '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
assert_state "23 spelled target without .git, collapsed path is a git root → wired (flag 0, comparison equal)" "$d23_p/link/.." "wired"

# --- 24 — kit issue #1157: SCRIPT-RESOLUTION state (hook_stop_script_state_var). A hook REGISTERED in
#      settings.json whose command names a script that does not exist can never load; the text match
#      behind hook_stop_wiring_state_var still says 'wired' (it is deliberately unchanged), so the
#      script state is a SEPARATE typed answer: present | missing | unverifiable | no-entry | degraded.
assert_script_state() {
  local label="$1" d="$2" want="$3" got_var got_wrap
  hook_stop_script_state_var "$d"; got_var="$HOOK_SCRIPT_STATE"
  got_wrap="$(hook_stop_script_state "$d")"
  if [ "$got_var" = "$want" ] && [ "$got_wrap" = "$want" ]; then ok "$label"
  else no "$label" "var=[$got_var] wrapper=[$got_wrap] want=[$want]"; fi
}
declare -F hook_stop_script_state_var >/dev/null 2>&1 || { no "24 lib defines hook_stop_script_state_var"; }
declare -F hook_stop_script_state >/dev/null 2>&1 || { no "24 lib defines hook_stop_script_state"; }
st() { printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"%s"}]}]}}' "$1"; }

d="$ROOT/t24a"; mkdir -p "$d/.claude/hooks"; : > "$d/.claude/hooks/retro-gate-stop.sh"
wire_settings "$d" "$(st "$d/.claude/hooks/retro-gate-stop.sh")"
assert_script_state "24a absolute command, script exists → present" "$d" "present"
assert_state "24a' same fixture is still plain wired (wiring state unchanged)" "$d" "wired"

d="$ROOT/t24b"; mkdir -p "$d"
wire_settings "$d" "$(st "$d/.claude/hooks/retro-gate-stop.sh")"
assert_script_state "24b absolute command, script deleted → missing" "$d" "missing"
assert_state "24b' same fixture still reads wired (the text match is not widened)" "$d" "wired"

d="$ROOT/t24c"; mkdir -p "$d/.claude/hooks"; : > "$d/.claude/hooks/retro-gate-stop.sh"
wire_settings "$d" "$(st '$CLAUDE_PROJECT_DIR/.claude/hooks/retro-gate-stop.sh')"
assert_script_state "24c \$CLAUDE_PROJECT_DIR command resolved against the target, exists → present" "$d" "present"

d="$ROOT/t24d"; mkdir -p "$d"
wire_settings "$d" "$(st '$CLAUDE_PROJECT_DIR/.claude/hooks/retro-gate-stop.sh')"
assert_script_state "24d \$CLAUDE_PROJECT_DIR command, script absent → missing" "$d" "missing"

d="$ROOT/t24e"; mkdir -p "$d/.claude/hooks"; : > "$d/.claude/hooks/retro-gate-stop.sh"
wire_settings "$d" "$(st 'bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/retro-gate-stop.sh --flag')"
assert_script_state "24e interpreter prefix + escaped-quoted \$CLAUDE_PROJECT_DIR + args, exists → present" "$d" "present"

d="$ROOT/t24f"; mkdir -p "$d"
wire_settings "$d" "$(st 'bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/retro-gate-stop.sh --flag')"
assert_script_state "24f same shape, script absent → missing" "$d" "missing"

d="$ROOT/t24g"; mkdir -p "$d"
wire_settings "$d" "$(st 'retro-gate-stop.sh')"
assert_script_state "24g bare command name (PATH lookup, no slash) → unverifiable, never a false missing" "$d" "unverifiable"

d="$ROOT/t24h"; mkdir -p "$d"
wire_settings "$d" "$(st '$SOME_UNKNOWN_VAR/retro-gate-stop.sh')"
assert_script_state "24h unresolvable variable in path → unverifiable" "$d" "unverifiable"

d="$ROOT/t24i"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/nope/retro-gate-a.sh"},{"type":"command","command":"'"$d"'/real-retro-gate-b.sh"}]}]}}'
: > "$d/real-retro-gate-b.sh"
assert_script_state "24i two registrations, one script exists → present (the hook can load)" "$d" "present"

d="$ROOT/t24j"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/nope/retro-gate-a.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"/x/other.sh"}]}]}}'
assert_script_state "24j retro-gate only under SessionStart, Stop has none → no-entry" "$d" "no-entry"

d="$ROOT/t24k"; mkdir -p "$d"
assert_script_state "24k no settings.json → no-entry" "$d" "no-entry"

d="$ROOT/t24l"; mkdir -p "$d"; wire_settings "$d" "$(st "$d/gone/retro-gate-stop.sh")"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$d/.claude/settings.json"
  assert_script_state "24l unreadable settings.json → no-entry (wiring state names unreadable)" "$d" "no-entry"
  chmod 644 "$d/.claude/settings.json"
else
  echo "  SKIP  24l unreadable settings (running as root)"
fi

d="$ROOT/t24m"; mkdir -p "$d"; : > "$d/retro-gate-stop.sh"
wire_settings "$d" "$(st "$d/retro-gate-stop.sh")"
if (
  export RSDD_BIN="$ROOT/no-such-rsdd"
  hook_stop_script_state_var "$d"; [ "$HOOK_SCRIPT_STATE" = "degraded" ]
) 2>/dev/null; then ok "24m rsdd unavailable (the script-state probe cannot run) → typed degraded, not present/missing"
else no "24m rsdd unavailable → typed degraded" "state did not read degraded"; fi

d="$ROOT/t24n"; mkdir -p "$d/rel/.claude"; mkdir -p "$d/rel/sub"; : > "$d/rel/sub/retro-gate-stop.sh"
wire_settings "$d/rel" "$(st 'sub/retro-gate-stop.sh')"
assert_script_state "24n relative path with a slash resolves against the target → present" "$d/rel" "present"

# --- 25 — kit issue #1157 round 2: 'missing' is a FIRM claim, emitted only when every registered
#      command was resolved unambiguously; every other shape is 'unverifiable'.
TL='~'; fh="$ROOT/t25-home"; mkdir -p "$fh/hk"; : > "$fh/hk/retro-gate-stop.sh"

d="$ROOT/t25a"; mkdir -p "$d/.claude/hooks"; : > "$d/.claude/hooks/retro-gate-stop.sh"
wire_settings "$d" "$(st '${CLAUDE_PROJECT_DIR}/.claude/hooks/retro-gate-stop.sh')"
assert_script_state "25a \${CLAUDE_PROJECT_DIR}/p, exists → present" "$d" "present"
d="$ROOT/t25b"; mkdir -p "$d"
wire_settings "$d" "$(st '${CLAUDE_PROJECT_DIR}/.claude/hooks/retro-gate-stop.sh')"
assert_script_state "25b \${CLAUDE_PROJECT_DIR}/p, absent → missing" "$d" "missing"

d="$ROOT/t25c"; mkdir -p "$d"
wire_settings "$d" "$(st '$HOME/hk/retro-gate-stop.sh')"
HOME="$fh" assert_script_state "25c \$HOME/p, HOME set, exists → present" "$d" "present"
wire_settings "$d" "$(st '${HOME}/hk/retro-gate-stop.sh')"
HOME="$fh" assert_script_state "25d \${HOME}/p, HOME set, exists → present" "$d" "present"
wire_settings "$d" "$(st "$TL/hk/retro-gate-stop.sh")"
HOME="$fh" assert_script_state "25e ~/p, HOME set, exists → present" "$d" "present"
wire_settings "$d" "$(st '$HOME/gone/retro-gate-stop.sh')"
HOME="$fh" assert_script_state "25f \$HOME/p, HOME set, absent → missing" "$d" "missing"
wire_settings "$d" "$(st '${HOME}/gone/retro-gate-stop.sh')"
HOME="$fh" assert_script_state "25g \${HOME}/p, HOME set, absent → missing" "$d" "missing"
wire_settings "$d" "$(st "$TL/gone/retro-gate-stop.sh")"
HOME="$fh" assert_script_state "25h ~/p, HOME set, absent → missing" "$d" "missing"
wire_settings "$d" "$(st '$HOME/hk/retro-gate-stop.sh')"
HOME="" assert_script_state "25i \$HOME/p with HOME empty → unverifiable (never joined to the target)" "$d" "unverifiable"
wire_settings "$d" "$(st "$TL/hk/retro-gate-stop.sh")"
HOME="" assert_script_state "25j ~/p with HOME empty → unverifiable" "$d" "unverifiable"
wire_settings "$d" "$(st '~someone/hk/retro-gate-stop.sh')"
HOME="$fh" assert_script_state "25k ~user/p → unverifiable" "$d" "unverifiable"
wire_settings "$d" "$(st '--dir=$CLAUDE_PROJECT_DIR/retro-gate-stop.sh')"
assert_script_state "25l variable not at the start of the word → unverifiable" "$d" "unverifiable"

d="$ROOT/t25m"; mkdir -p "$d/my tools"; : > "$d/my tools/retro-gate-stop.sh"
wire_settings "$d" "$(st "bash \\\"$d/my tools/retro-gate-stop.sh\\\" --x")"
assert_script_state "25m quoted path containing a space, exists → present" "$d" "present"
wire_settings "$d" "$(st "bash \\\"$d/my gone/retro-gate-stop.sh\\\" --x")"
assert_script_state "25n quoted path containing a space, absent → missing" "$d" "missing"
wire_settings "$d" "$(st "bash \\\"$d/my tools/retro-gate-stop.sh --x")"
assert_script_state "25o unterminated quote → unverifiable" "$d" "unverifiable"
wire_settings "$d" "$(st "bash $d/my tools/retro-gate-stop.sh")"
assert_script_state "25p unquoted space splits the word → the fragment is a bare name, unverifiable" "$d" "unverifiable"

d="$ROOT/t25q"; mkdir -p "$d"
wire_settings "$d" "$(st 'cd sub && ./retro-gate-stop.sh')"
assert_script_state "25q relative path after a 'cd' in the command → unverifiable" "$d" "unverifiable"
wire_settings "$d" "$(st './retro-gate-stop.sh')"
assert_script_state "25r same relative path without 'cd' → joined to the target → missing" "$d" "missing"

d="$ROOT/t25s"; mkdir -p "$d"; : > "$d/ok-retro-gate.sh"
wire_settings "$d" '{"hooks":{"Stop":[{"hooks":[{"command":"/nope/retro-gate-a.sh"},{"command":"retro-gate-b"}]}]}}'
assert_script_state "25s one missing + one unresolvable → unverifiable, never missing" "$d" "unverifiable"
wire_settings "$d" '{"hooks":{"Stop":[{"hooks":[{"command":"retro-gate-b"},{"command":"'"$d"'/ok-retro-gate.sh"}]}]}}'
assert_script_state "25t one unresolvable + one present → present (any present wins)" "$d" "present"
wire_settings "$d" '{"hooks":{"Stop":[{"hooks":[{"command":"/nope/retro-gate-a.sh"},{"command":"/nope2/retro-gate-b.sh"}]}]}}'
assert_script_state "25u every entry firmly absent → missing" "$d" "missing"

# --- 26 — kit issue #1157 round 3: shapes whose word is not a plain script path.
d="$ROOT/t26a"; mkdir -p "$d"
wire_settings "$d" "$(st 'bash -c \"/nope/retro-gate-stop.sh && echo ok\"')"
assert_script_state "26a word after 'bash -c' is a re-parsed payload → unverifiable (not missing)" "$d" "unverifiable"
wire_settings "$d" "$(st 'sh -lc /nope/retro-gate-stop.sh')"
assert_script_state "26a' word after 'sh -lc' → unverifiable" "$d" "unverifiable"
wire_settings "$d" "$(st 'bash /nope/retro-gate-stop.sh -c')"
assert_script_state "26a'' '-c' AFTER the script is an ordinary argument → missing" "$d" "missing"
d="$ROOT/t26b"; mkdir -p "$d"
wire_settings "$d" "$(st 'tool --cfg=/nope/retro-gate.json')"
assert_script_state "26b option word '--cfg=/x/retro-gate.json' → unverifiable" "$d" "unverifiable"
d="$ROOT/t26c"; mkdir -p "$d"
wire_settings "$d" "$(st 'C:/nope/retro-gate-stop.sh')"
assert_script_state "26c ':' before the first '/' (C:/x) → unverifiable" "$d" "unverifiable"
d="$ROOT/t26d"; mkdir -p "$d"
wire_settings "$d" "$(st "bash \\\"$TL/hk/retro-gate-stop.sh\\\"")"
HOME="$fh" assert_script_state "26d '~/p' inside double quotes is not expanded → unverifiable" "$d" "unverifiable"
d="$ROOT/t26e"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"Stop":[{"hooks":[{"command":"'"$fh"'/hk/retro-gate-stop.sh \"unterminated"},{"command":"/nope/retro-gate-b.sh"}]}]}}'
assert_script_state "26e unterminated quote in entry 1 leaves no stale result for entry 2 → unverifiable" "$d" "unverifiable"

# --- 27 — kit issue #1157: LAUNCH-HISTORY state (hook_stop_launch_state_var). A hook REGISTERED in
#      settings.json is only loaded for a session launched in exactly that directory. The history
#      root is a test seam ($RSDD_CLAUDE_PROJECTS_DIR), so every case builds its own fixture history.
#      launched | no-sessions | unknown; 'unknown' is "could not look" and never reads as no-sessions.
declare -F hook_stop_launch_state_var >/dev/null 2>&1 || no "27 lib defines hook_stop_launch_state_var"
declare -F hook_stop_launch_state >/dev/null 2>&1 || no "27 lib defines hook_stop_launch_state"
assert_launch() { # <label> <dir> <want> [history-root]
  local label="$1" d="$2" want="$3" hist="${4-$ROOT/hist}" got_var got_wrap
  got_var="$(RSDD_CLAUDE_PROJECTS_DIR="$hist" bash -c '. "$1"; hook_stop_launch_state_var "$2"; printf "%s" "$HOOK_LAUNCH_STATE"' _ "$LIB" "$d" 2>&1)"
  got_wrap="$(RSDD_CLAUDE_PROJECTS_DIR="$hist" bash -c '. "$1"; hook_stop_launch_state "$2"' _ "$LIB" "$d" 2>&1)"
  if [ "$got_var" = "$want" ] && [ "$got_wrap" = "$want" ]; then ok "$label"
  else no "$label" "var=[$got_var] wrapper=[$got_wrap] want=[$want]"; fi
}
ENCROOT="${ROOT//[^A-Za-z0-9]/-}"
mkdir -p "$ROOT/hist"
# 27a — history dir named after the encoded path holds a transcript → launched.
mkdir -p "$ROOT/hist/$ENCROOT-t27a"; : > "$ROOT/hist/$ENCROOT-t27a/s1.jsonl"
assert_launch "27a transcript in the encoded history dir → launched" "$ROOT/t27a" "launched"
# 27b — history root exists, no dir for this target → no-sessions.
assert_launch "27b no history dir for the target → no-sessions" "$ROOT/t27b" "no-sessions"
# 27c — dir exists but holds no *.jsonl (only a memory dir) → no-sessions (a dir alone is not a launch).
mkdir -p "$ROOT/hist/$ENCROOT-t27c/memory"
assert_launch "27c history dir without a transcript → no-sessions" "$ROOT/t27c" "no-sessions"
# 27d — history root absent → unknown (could not look), never no-sessions.
assert_launch "27d history root absent → unknown" "$ROOT/t27d" "unknown" "$ROOT/no-such-root"
# 27e — no override and HOME empty → unknown.
got="$(env -u RSDD_CLAUDE_PROJECTS_DIR HOME="" bash -c '. "$1"; hook_stop_launch_state_var "$2"; printf "%s" "$HOOK_LAUNCH_STATE"' _ "$LIB" "$ROOT/t27e" 2>&1)"
if [ "$got" = "unknown" ]; then ok "27e HOME empty, no override → unknown"; else no "27e HOME empty, no override → unknown" "got [$got]"; fi
# 27f — without the override the default root is $HOME/.claude/projects.
mkdir -p "$ROOT/home27f/.claude/projects/$ENCROOT-t27f"; : > "$ROOT/home27f/.claude/projects/$ENCROOT-t27f/s.jsonl"
got="$(env -u RSDD_CLAUDE_PROJECTS_DIR HOME="$ROOT/home27f" bash -c '. "$1"; hook_stop_launch_state_var "$2"; printf "%s" "$HOOK_LAUNCH_STATE"' _ "$LIB" "$ROOT/t27f" 2>&1)"
if [ "$got" = "launched" ]; then ok "27f default root is \$HOME/.claude/projects"; else no "27f default root is \$HOME/.claude/projects" "got [$got]"; fi
# 27g — every non-alphanumeric character encodes to '-' (dot, underscore, space), as Claude Code does.
d="$ROOT/t27g.x_y z"; encg="${d//[^A-Za-z0-9]/-}"; mkdir -p "$ROOT/hist/$encg"; : > "$ROOT/hist/$encg/a.jsonl"
assert_launch "27g dot/underscore/space in the path encode to '-' → launched" "$d" "launched"
# 27h — a session launched in a PARENT or SUBDIRECTORY records under its own name and does not count.
mkdir -p "$ROOT/hist/$ENCROOT-t27h-sub" "$ROOT/hist/$ENCROOT"
: > "$ROOT/hist/$ENCROOT-t27h-sub/s.jsonl"; : > "$ROOT/hist/$ENCROOT/s.jsonl"
assert_launch "27h sessions only in a sub/parent directory → no-sessions" "$ROOT/t27h" "no-sessions"
# 27i — '.' and '..' components collapse before encoding.
assert_launch "27i dotdot-collapsed target → launched" "$ROOT/t27a/../t27a/." "launched"
# 27j/27k — the transcript is the LAST entry of a list (first is not a transcript) → launched;
#           a non-.jsonl entry alone → no-sessions.
mkdir -p "$ROOT/hist/$ENCROOT-t27j"; : > "$ROOT/hist/$ENCROOT-t27j/a.txt"; : > "$ROOT/hist/$ENCROOT-t27j/z.jsonl"
assert_launch "27j only the last entry is a transcript → launched" "$ROOT/t27j" "launched"
mkdir -p "$ROOT/hist/$ENCROOT-t27k"; : > "$ROOT/hist/$ENCROOT-t27k/a.jsonl.bak"
assert_launch "27k a non-.jsonl entry alone → no-sessions" "$ROOT/t27k" "no-sessions"
# 27l — a non-ASCII byte in the path: the encoding is per character/code unit, not per byte → unknown.
assert_launch "27l non-ASCII path → unknown (no firm claim)" "$ROOT/t27l-ñ" "unknown"
# 27m — an encoded name over 200 characters (Claude Code truncates + hashes) → unknown.
long="$ROOT/$(printf 'x%.0s' $(seq 1 210))"
assert_launch "27m encoded name over 200 chars → unknown" "$long" "unknown"
# 27o — CLAUDE_CONFIG_DIR is honoured when no override is set (and the override wins over it).
mkdir -p "$ROOT/cfg27o/projects/$ENCROOT-t27o"; : > "$ROOT/cfg27o/projects/$ENCROOT-t27o/s.jsonl"
got="$(env -u RSDD_CLAUDE_PROJECTS_DIR CLAUDE_CONFIG_DIR="$ROOT/cfg27o" HOME="$ROOT/nohome" bash -c '. "$1"; hook_stop_launch_state_var "$2"; printf "%s" "$HOOK_LAUNCH_STATE"' _ "$LIB" "$ROOT/t27o" 2>&1)"
if [ "$got" = "launched" ]; then ok "27o CLAUDE_CONFIG_DIR/projects is the default root"; else no "27o CLAUDE_CONFIG_DIR/projects is the default root" "got [$got]"; fi
assert_launch "27o2 RSDD_CLAUDE_PROJECTS_DIR wins over CLAUDE_CONFIG_DIR" "$ROOT/t27o" "no-sessions"
# 27p — a symlinked target (leaf or ancestor component) → unknown, never no-sessions: Claude Code records the resolved path.
mkdir -p "$ROOT/real27p/sub"; ln -s "$ROOT/real27p" "$ROOT/link27p"
assert_launch "27p symlinked ancestor component → unknown" "$ROOT/link27p/sub" "unknown"
ln -s "$ROOT/real27p/sub" "$ROOT/leaf27p"
assert_launch "27p2 symlinked leaf → unknown" "$ROOT/leaf27p" "unknown"
assert_launch "27p3 real (non-symlink) path alongside → no-sessions" "$ROOT/real27p/sub" "no-sessions"
# 27n — the launch question never changes the wiring state (sweep-retros stays byte-identical).
d="$ROOT/t27n"; wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/retro-gate-stop.sh"}]}]}}'
assert_state "27n wiring state is history-blind (still wired with no history)" "$d" "wired"

# --- 28 — THE SHIM CONTRACT (kit issue #2356, U2.3a). hook_stop_wiring_state_var, hook_stop_script_state_var and
#      _hw_find_git_root ask `rsdd hook wiring-state|script-state|git-root <arg>`; the logic is pinned by the Go tests
#      (internal/hook) and the cases above run it end to end. A STUB binary pins what only the shim decides: the exact
#      call, the environment it hands over, how an answer is accepted, and what a failure reads as.
STUB="$ROOT/stub-rsdd"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
printf 'args=%s|ceiling=%s\n' "$*" "${RSDD_HOOK_WIRING_CEILING-unset}" >> "$STUB_LOG"
printf '%b' "${STUB_OUT:-}"
exit "${STUB_RC:-0}"
EOS
chmod +x "$STUB"
# shim_run LIB STUB_OUT STUB_RC CODE [ARG...] : source LIB in a fresh shell with RSDD_BIN=stub, run CODE ($2.. are ARG...)
shim_run() {
  local lib="$1" out="$2" rc="$3" code="$4"
  shift 4
  : > "$ROOT/stub.log"
  STUB_LOG="$ROOT/stub.log" STUB_OUT="$out" STUB_RC="$rc" RSDD_BIN="$STUB" "$BASH_BIN" -c '. "$1"; '"$code" _ "$lib" "$@" 2>/dev/null
}
shim_log() { cat "$ROOT/stub.log"; }
check_eq() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$2] want [$3]"; fi
}
W_CODE='hook_stop_wiring_state_var "$2"; printf %s "$HOOK_WIRING_STATE"'
S_CODE='hook_stop_script_state_var "$2"; printf %s "$HOOK_SCRIPT_STATE"'

got="$(shim_run "$LIB" 'wired\n' 0 "$W_CODE" "$ROOT/some dir")"
check_eq "28a wiring state is the stub's answer (the lib decides nothing itself)" "$got" "wired"
check_eq "28a' the call is exactly 'rsdd hook wiring-state <target>'" "$(shim_log | sed 's/|ceiling=.*//')" "args=hook wiring-state $ROOT/some dir"
got="$(shim_run "$LIB" 'present\n' 0 "$S_CODE" "$ROOT/t28")"
check_eq "28b script state is the stub's answer" "$got" "present"
check_eq "28b' the call is exactly 'rsdd hook script-state <target>'" "$(shim_log | sed 's/|ceiling=.*//')" "args=hook script-state $ROOT/t28"
got="$(shim_run "$LIB" 'unwired\n' 0 'printf "[%s]" "$(hook_stop_wiring_state "$2")"' "$ROOT/t28")"
check_eq "28c the wrapper still prints the bare state, no newline" "$got" "[unwired]"
got="$(shim_run "$LIB" 'wired\n' 1 "$W_CODE" "$ROOT/t28")"
check_eq "28d a failing rsdd (rc 1) with a valid-looking answer reads unreadable, never wired" "$got" "unreadable"
got="$(shim_run "$LIB" 'present\n' 1 "$S_CODE" "$ROOT/t28")"
check_eq "28d' a failing rsdd (rc 1) reads degraded for the script state" "$got" "degraded"
got="$(shim_run "$LIB" 'bogus\n' 0 "$W_CODE" "$ROOT/t28")"
check_eq "28e an answer outside the five wiring states reads unreadable" "$got" "unreadable"
got="$(shim_run "$LIB" 'bogus\n' 0 "$S_CODE" "$ROOT/t28")"
check_eq "28e' an answer outside the five script states reads degraded" "$got" "degraded"
got="$(shim_run "$LIB" '' 0 "$W_CODE" "$ROOT/t28")"
check_eq "28e'' an empty answer reads unreadable (not a silent state)" "$got" "unreadable"
got="$(RSDD_BIN="$ROOT/no-such-rsdd" "$BASH_BIN" -c '. "$1"; hook_stop_wiring_state_var "$2"; printf "%s|" "$HOOK_WIRING_STATE"; hook_stop_script_state_var "$2"; printf "%s" "$HOOK_SCRIPT_STATE"' _ "$LIB" "$ROOT/t28" 2>/dev/null)"
check_eq "28f rsdd unavailable: wiring reads unreadable, script reads degraded" "$got" "unreadable|degraded"
err="$(RSDD_BIN="$ROOT/no-such-rsdd" "$BASH_BIN" -c '. "$1"; hook_stop_wiring_state_var "$2"' _ "$LIB" "$ROOT/t28" 2>&1 >/dev/null)"
if [[ "$err" == *"degraded: rsdd-unavailable"* ]]; then ok "28f' rsdd unavailable is announced on stderr with the typed degraded line"; else no "28f' rsdd unavailable is announced on stderr" "stderr=[$err]"; fi
C_CODE='export -n RSDD_HOOK_WIRING_CEILING; RSDD_HOOK_WIRING_CEILING=/ceil/dir; hook_stop_wiring_state_var "$2"'
shim_run "$LIB" 'wired\n' 0 "$C_CODE" "$ROOT/t28" >/dev/null
check_eq "28g an UNEXPORTED RSDD_HOOK_WIRING_CEILING still reaches rsdd (the bash lib read it as a plain variable)" "$(shim_log | sed 's/.*|ceiling=//')" "/ceil/dir"
shim_run "$LIB" 'wired\n' 0 'unset RSDD_HOOK_WIRING_CEILING; hook_stop_wiring_state_var "$2"' "$ROOT/t28" >/dev/null
check_eq "28g' no ceiling set -> rsdd sees an empty ceiling (equivalent to unset)" "$(shim_log | sed 's/.*|ceiling=//')" ""
G_CODE='_hw_find_git_root "$2"; printf "%s|%s" "$HW_TARGET_IS_ROOT" "${HW_GIT_ROOT//$'"'"'\n'"'"'/<NL>}"'
got="$(shim_run "$LIB" '1\n/r/root\n' 0 "$G_CODE" "$ROOT/t28")"
check_eq "28h git-root '1' + a path -> HW_TARGET_IS_ROOT=1, HW_GIT_ROOT=the path" "$got" "1|/r/root"
got="$(shim_run "$LIB" '0\n/r/enclosing\n' 0 "$G_CODE" "$ROOT/t28")"
check_eq "28h' git-root '0' + a path -> flag 0, HW_GIT_ROOT=the path" "$got" "0|/r/enclosing"
got="$(shim_run "$LIB" '0\n\n' 0 "$G_CODE" "$ROOT/t28")"
check_eq "28h'' git-root '0' + empty line -> flag 0, no root" "$got" "0|"
got="$(shim_run "$LIB" '0\n/a\nb\n' 0 "$G_CODE" "$ROOT/t28")"
check_eq "28h''' a root holding a newline survives the capture" "$got" "0|/a<NL>b"
got="$(shim_run "$LIB" '0\n/a\n\n' 0 "$G_CODE" "$ROOT/t28")"
check_eq "28h'''' a root with a TRAILING newline survives the capture" "$got" "0|/a<NL>"
got="$(shim_run "$LIB" '1\n/r\n' 3 "$G_CODE" "$ROOT/t28")"
check_eq "28i a failing rsdd leaves no root and a clear flag (and the function still returns 0)" "$got" "0|"
shim_run "$LIB" '0\n\n' 0 '_hw_find_git_root "$2"' 'weird arg' >/dev/null
check_eq "28j the target reaches rsdd as ONE argument" "$(shim_log | sed 's/|ceiling=.*//')" "args=hook git-root weird arg"
# 28k - sourcing the lib costs nothing and says nothing (verify-registry-wired-exec.test.sh sources it under a PATH with no
#       external commands, to exercise the no-jq branch of the second half): rsdd-exec.sh is loaded on first USE.
mkdir -p "$ROOT/emptybin"
err="$(PATH="$ROOT/emptybin" "$BASH_BIN" -c '. "$1"; declare -F hook_stop_launch_state_var >/dev/null && declare -F hook_wired_exec_report >/dev/null && declare -F hook_stop_wiring_state_var >/dev/null' _ "$LIB" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$err" ]; then ok "28k sourcing under a PATH with no external commands is silent and defines every function"
else no "28k sourcing under an empty PATH is silent" "rc=$rc stderr=[$err]"; fi

# --- mutation teeth ("--prove-teeth") --------------------------------------------------------------
# Each mutant is a COPY of the real lib file with ONE line changed, sourced fresh in a subshell -
# never a hand-redefined function called directly (RDD finding, see header). Running the REAL function
# against the mutated COPY proves the SOURCED implementation reacts to a real code change, not that the
# test file's own inline stand-in behaves as scripted.
#
# WHAT MOVED (kit issue #2356, U2.3a): the logic of hook_stop_wiring_state_var, hook_stop_script_state_var and
# _hw_find_git_root is Go now, so the bash mutants that edited those functions (the awk Stop scan, the
# absent/unreadable assignments, the wired-off-root downgrade and its guards, the .git / ceiling / raw-target checks,
# every script-resolution rule, the degraded arm) cannot apply to this file any more. Each of them is a
# case of the Go tests in research-sdd/rsdd/internal/hook (wiring_test.go, script_test.go, pathwalk_test.go), killed
# there by a hand mutation of the Go source recorded in odd/tasks/u2.3a-hook-wiring.md, and the black-box cases
# 1-26 above still run end to end through the shim. What stays here: mutants of what this file still owns -
# _hw_abspath (shared with the launch state until U2.3b, kit issue #2357), the launch-history rules, and the shim
# itself (the call it makes, the environment it hands over, what it accepts and how a failure reads).
if [ "${1:-}" = "--prove-teeth" ]; then
  # Mutant builds go through lib/mutant.sh (kit issue #1299). Sourced only on this path. Each
  # mutant is built by mutant_chain, which refuses a dead sed stage, an empty/identical/unparseable
  # mutant and a mutant placed in the live tree; a refused build is counted ONCE here and its
  # observation never runs. The observations stay in-process (a mutated lib is sourced in a
  # subshell and its state variable read), so they are not expressible as mutant_tooth argv runs.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk() { mutant_chain_or_count fail "$@" || return 1; }
  # A mutant lib is sourced from $ROOT, so the bridge finds rsdd-exec.sh beside it.
  cp "$HERE/../lib/rsdd-exec.sh" "$ROOT/rsdd-exec.sh"

  # abs_tooth LABEL MUTANT WANT CWD ARG NOTE : _hw_abspath of the mutant must no longer answer WANT (and must answer).
  abs_tooth() {
    local label="$1" mut="$2" want="$3" cwd="$4" arg="$5" note="$6" got
    # shellcheck disable=SC1090
    got="$(cd "$cwd" && unset -f _hw_abspath && . "$mut" 2>/dev/null && _hw_abspath "$arg" 2>&1; printf '%s' "$HW_ABS_PATH")"
    if [ -z "$got" ]; then no "teeth: $label produced no answer, not a bite" "$note"
    elif [ "$got" = "$want" ]; then no "teeth: $label NOT caught (theater)" "$note still [$got]"
    else ok "teeth: $label caught (real sourced lib)" "$note read [$got] not [$want]"; fi
  }

  echo "-- teeth: stop collapsing '..' (append it as a literal component instead) --"
  mut_dotdot="$ROOT/hook-wiring.MUTANT-dotdot-nocollapse.sh"
  if mk "teeth: '..' collapse anchor in lib" "$LIB" "$mut_dotdot" 's/\.\.)   result="\${result%\/\*}" ;;/..)   result="$result\/.." ;;  # MUTANT: dotdot no longer collapsed/'; then
    abs_tooth "dotdot no-collapse" "$mut_dotdot" "/a" "$ROOT" "/a/b/.." "_hw_abspath /a/b/.."
  fi

  echo "-- teeth: truncate the split at the first control char (newline) --"
  mut_split_nl="$ROOT/hook-wiring.MUTANT-split-newline.sh"
  if mk "teeth: path-split anchor in lib" "$LIB" "$mut_split_nl" 's/local rest="\${d#\/}" last=0/local rest="${d#\/}" last=0; rest="${rest%%[[:cntrl:]]*}"  # MUTANT: truncate at newline/'; then
    abs_tooth "newline-truncating split" "$mut_split_nl" $'/a/b\nc' "$ROOT" $'/a/b\nc' "_hw_abspath with an embedded newline"
  fi

  echo "-- teeth: reintroduce a here-string on an executable line — case 20 lint must go RED --"
  mut_herestr="$ROOT/hook-wiring.MUTANT-herestring.sh"
  if mk "teeth: path-split anchor in lib (here-string)" "$LIB" "$mut_herestr" 's/local rest="\${d#\/}" last=0/local rest="${d#\/}" last=0; : <<< "$d"  # MUTANT: here-string/'; then
    if herestring_count "$mut_herestr" && [ "$HS_N" -ne 0 ]; then
      ok "teeth: here-string lint bites on a mutant carrying one (real sourced lib)" "found $HS_N"
    else
      no "teeth: here-string lint did NOT bite on a here-string mutant (theater)" "n=[${HS_N:-}]"
    fi
  fi

  echo "-- teeth: stop absolutizing a relative path (drop the \$PWD prefix) --"
  mut_absolut="$ROOT/hook-wiring.MUTANT-no-absolutize.sh"
  if mk "teeth: absolutize anchor in lib" "$LIB" "$mut_absolut" 's/\*)  d="\$PWD\/\$d" ;;/*)  : ;;  # MUTANT: relative path left relative/'; then
    abs_tooth "relative-path absolutize dropped" "$mut_absolut" "$ROOT/rel" "$ROOT" "rel" "_hw_abspath rel from \$ROOT"
  fi

  echo "-- teeth: drop the join '/' prefix of the collapsed components --"
  mut_join="$ROOT/hook-wiring.MUTANT-join-prefix.sh"
  if mk "teeth: join-prefix anchor in lib" "$LIB" "$mut_join" 's/\*)    result="\$result\/\$part" ;;/*)    result="$part" ;;  # MUTANT: join no longer prefixes "\/"/'; then
    abs_tooth "join prefix dropped" "$mut_join" "/a/b" "$ROOT" "/a/b" "_hw_abspath /a/b"
  fi

  # shim_tooth LABEL MUTANT WANT STUB_OUT STUB_RC CODE ARG NOTE [log] : the mutant lib, driven through the stub rsdd, must
  # no longer answer WANT. With the word "log" the observed value is the stub's recorded call instead of the snippet output.
  shim_tooth() {
    local label="$1" mut="$2" want="$3" out="$4" rc="$5" code="$6" arg="$7" note="$8" what="${9:-out}" got
    got="$(shim_run "$mut" "$out" "$rc" "$code" "$arg")"
    [ "$what" != log ] || got="$(shim_log)"
    if [ -z "$got" ]; then no "teeth: $label produced no observation, not a bite" "$note"
    elif [ "$got" = "$want" ]; then no "teeth: $label NOT caught (theater)" "$note still [$got]"
    else ok "teeth: $label caught (real sourced lib)" "$note read [$got] not [$want]"; fi
  }
  echo "-- teeth: the shim (kit issue #2356) - one mutant per decision the shim makes --"
  mut_s1="$ROOT/hook-wiring.MUTANT-shim-wiring-fallback.sh"
  if mk "teeth: wiring fallback anchor in lib" "$LIB" "$mut_s1" 's/\*) HOOK_WIRING_STATE="unreadable" ;;/*) HOOK_WIRING_STATE="wired" ;;  # MUTANT: a failure reads wired/'; then
    shim_tooth "wiring failure read as wired" "$mut_s1" "unreadable" 'bogus\n' 0 "$W_CODE" "$ROOT/t28" "case 28e"
  fi
  mut_s2="$ROOT/hook-wiring.MUTANT-shim-script-fallback.sh"
  if mk "teeth: script fallback anchor in lib" "$LIB" "$mut_s2" 's/\*) HOOK_SCRIPT_STATE="degraded" ;;/*) HOOK_SCRIPT_STATE="present" ;;  # MUTANT: a failure reads present/'; then
    shim_tooth "script failure read as present" "$mut_s2" "degraded" 'bogus\n' 0 "$S_CODE" "$ROOT/t28" "case 28e'"
  fi
  mut_s3="$ROOT/hook-wiring.MUTANT-shim-rc-ignored.sh"
  if mk "teeth: exit-status check anchor in lib" "$LIB" "$mut_s3" 's/case "\$_HW_RC:\$_HW_OUT" in/case "0:$_HW_OUT" in  # MUTANT: exit status ignored/'; then
    shim_tooth "rsdd exit status ignored" "$mut_s3" "unreadable" 'wired\n' 1 "$W_CODE" "$ROOT/t28" "case 28d"
  fi
  mut_s4="$ROOT/hook-wiring.MUTANT-shim-ceiling.sh"
  if mk "teeth: ceiling hand-over anchor in lib" "$LIB" "$mut_s4" 's/RSDD_HOOK_WIRING_CEILING="\${RSDD_HOOK_WIRING_CEILING:-}" rsdd_exec/rsdd_exec/'; then
    shim_tooth "ceiling not handed to rsdd" "$mut_s4" "args=hook wiring-state $ROOT/t28|ceiling=/ceil/dir" 'wired\n' 0 "$C_CODE" "$ROOT/t28" "case 28g" log
  fi
  mut_s5="$ROOT/hook-wiring.MUTANT-shim-newline.sh"
  if mk "teeth: one-newline anchor in lib" "$LIB" "$mut_s5" 's/ # HW-ONE-NEWLINE$/; _HW_OUT="${_HW_OUT%%[[:cntrl:]]*}"  # MUTANT: cut at the first control char/'; then
    shim_tooth "payload newline lost" "$mut_s5" "0|/a<NL>b" '0\n/a\nb\n' 0 "$G_CODE" "$ROOT/t28" "case 28h"
  fi
  mut_s6="$ROOT/hook-wiring.MUTANT-shim-root-flag.sh"
  if mk "teeth: root-flag anchor in lib" "$LIB" "$mut_s6" 's/HW_TARGET_IS_ROOT=1; HW_GIT_ROOT=/HW_TARGET_IS_ROOT=0; HW_GIT_ROOT=/'; then
    shim_tooth "target-is-root flag dropped" "$mut_s6" "1|/r/root" '1\n/r/root\n' 0 "$G_CODE" "$ROOT/t28" "case 28h"
  fi
  mut_s7="$ROOT/hook-wiring.MUTANT-shim-no-target.sh"
  if mk "teeth: argument hand-over anchor in lib" "$LIB" "$mut_s7" 's/rsdd_exec hook "\$1" "\$2"/rsdd_exec hook "$1" ""/'; then
    shim_tooth "target not passed to rsdd" "$mut_s7" "args=hook wiring-state $ROOT/t28|ceiling=$RSDD_HOOK_WIRING_CEILING" 'wired\n' 0 "$W_CODE" "$ROOT/t28" "case 28a" log
  fi

  echo "-- teeth (#1157 launch history): one mutant per rule of hook_stop_launch_state_var --"
  launch_tooth() { # <label> <sed-expr> <fixture-dir> <pristine-state> <case> [history-root]
    local label="$1" expr="$2" dir="$3" want="$4" cs="$5" hist="${6-$ROOT/hist}" mut got
    mut="$ROOT/hook-wiring.MUTANT-launch-${cs// /-}.sh"
    mk "teeth: $label anchor in lib" "$LIB" "$mut" "$expr" || return 0
    got="$(
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var hook_stop_script_state hook_stop_script_state_var hook_stop_launch_state hook_stop_launch_state_var _hw_find_git_root _hw_abspath
      # shellcheck disable=SC1090
      . "$mut"
      RSDD_CLAUDE_PROJECTS_DIR="$hist" hook_stop_launch_state_var "$dir" 2>&1; printf '%s' "$HOOK_LAUNCH_STATE"
    )"
    if [ "$got" = "$want" ]; then no "teeth: $label NOT caught (theater)" "$cs still [$got]"
    else ok "teeth: $label caught (real sourced lib)" "$cs read [$got] not [$want]"; fi
  }
  launch_tooth "history check always true" 's/if compgen -G "\$root\/\$enc\/\*.jsonl" >\/dev\/null 2>&1; then  # HOOK-LAUNCH-HISTORY-CHECK/if true; then  # HOOK-LAUNCH-HISTORY-CHECK/' "$ROOT/t27b" "no-sessions" "case 27b"
  launch_tooth "history check always false" 's/if compgen -G "\$root\/\$enc\/\*.jsonl" >\/dev\/null 2>&1; then  # HOOK-LAUNCH-HISTORY-CHECK/if false; then  # HOOK-LAUNCH-HISTORY-CHECK/' "$ROOT/t27a" "launched" "case 27a"
  launch_tooth "directory without transcript counted as launch" 's|compgen -G "\$root/\$enc/\*.jsonl"|compgen -G "$root/$enc"|' "$ROOT/t27c" "no-sessions" "case 27c"
  launch_tooth "any file counted as a transcript" 's|\$root/\$enc/\*.jsonl|$root/$enc/*|' "$ROOT/t27k" "no-sessions" "case 27k"
  launch_tooth "absent history root read as no-sessions" 's/if \[ ! -d "\$root" \] || \[ ! -r "\$root" \]; then/if false; then/' "$ROOT/t27d" "unknown" "case 27d" "$ROOT/no-such-root"
  launch_tooth "encoding keeps dots" 's/enc="\${d\/\/\[^A-Za-z0-9\]\/-}"/enc="${d\/\/[^A-Za-z0-9.]\/-}"/' "$ROOT/t27g.x_y z" "launched" "case 27g"
  launch_tooth "non-ASCII guard dropped" 's/case "\$d" in \*\[!\\ -~\]\*) HOOK_LAUNCH_STATE="unknown"; return 0 ;; esac   # HOOK-LAUNCH-NONASCII-GUARD/:/' "$ROOT/t27l-ñ" "unknown" "case 27l"
  launch_tooth "symlink guard dropped" 's/if \[ -L "\$_hw_c" \]; then HOOK_LAUNCH_STATE="unknown"; return 0; fi  # HOOK-LAUNCH-SYMLINK-GUARD/:/' "$ROOT/link27p/sub" "unknown" "case 27p"
  mut_cfg="$ROOT/hook-wiring.MUTANT-launch-config-dir.sh"
  if mk "teeth: CLAUDE_CONFIG_DIR branch anchor in lib" "$LIB" "$mut_cfg" 's/if \[ -n "\${CLAUDE_CONFIG_DIR:-}" \]; then root="\$CLAUDE_CONFIG_DIR\/projects"/if false; then root=""/'; then
    got="$(
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var hook_stop_script_state hook_stop_script_state_var hook_stop_launch_state hook_stop_launch_state_var _hw_find_git_root _hw_abspath
      # shellcheck disable=SC1090
      . "$mut_cfg"
      unset RSDD_CLAUDE_PROJECTS_DIR; CLAUDE_CONFIG_DIR="$ROOT/cfg27o" HOME="$ROOT/nohome" hook_stop_launch_state_var "$ROOT/t27o" 2>&1; printf '%s' "$HOOK_LAUNCH_STATE"
    )"
    if [ "$got" = "launched" ]; then no "teeth: CLAUDE_CONFIG_DIR ignored NOT caught (theater)" "still [$got]"
    else ok "teeth: CLAUDE_CONFIG_DIR ignored caught (real sourced lib)" "case 27o read [$got] not [launched]"; fi
  fi
  launch_tooth "long-name guard dropped" 's/if \[ "\${#enc}" -gt 200 \]; then HOOK_LAUNCH_STATE="unknown"; return 0; fi   # HOOK-LAUNCH-LONGNAME-GUARD/:/' "$long" "unknown" "case 27m"
fi

echo ""
printf '== %d passed · %d failed ==\n' "$pass" "$fail"

[ "$fail" -eq 0 ] && exit 0 || exit 1
